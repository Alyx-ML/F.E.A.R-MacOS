/* Helpers called from SRW/llasm-translated code for instructions that the
 * translator lowers to calls (flags-heavy shifts, string compares, FS access,
 * CPU identification, x87 extras). The x87 register file follows
 * llasm_float.c: 8 doubles, ST(i) = st[(top + i) & 7]. */
#include "gp.h"
#include <math.h>
#include <string.h>
#include <time.h>

#define X87_C0 0x0100
#define X87_C1 0x0200
#define X87_C2 0x0400
#define X87_C3 0x4000
#define ST(c, i) ((c)->_st[((c)->_st_top + (i)) & 7])

static uint32_t *reg(_cpu *c, int index)
{
    switch (index) {
    case 0: return &c->_eax; case 1: return &c->_ecx; case 2: return &c->_edx; case 3: return &c->_ebx;
    case 4: return &c->_esp; case 5: return &c->_ebp; case 6: return &c->_esi; case 7: return &c->_edi;
    }
    gp_fatal("translated code named register index %d", index);
}

static uint32_t parity(uint32_t v) { return (__builtin_popcount(v & 0xff) & 1) ? 0 : PF; }

static void set_szp(_cpu *c, uint32_t result, int width)
{
    uint32_t mask = width == 32 ? 0xffffffffu : (1u << width) - 1;
    result &= mask;
    c->_eflags &= ~(SF | ZF | PF | AF);
    if (!result) c->_eflags |= ZF;
    if (result & (1u << (width - 1))) c->_eflags |= SF;
    c->_eflags |= parity(result);
}

/* op: 0 shl, 1 shr, 2 sar. Count already in a register (x86 masks to 5 bits). */
static uint32_t shift(_cpu *c, uint32_t v, uint32_t count, unsigned op, int width)
{
    count &= 31;
    if (!count) return v;               /* flags unchanged */
    uint32_t mask = width == 32 ? 0xffffffffu : (1u << width) - 1;
    uint32_t sign = 1u << (width - 1);
    v &= mask;
    uint32_t r, cf;
    if (op == 0) {
        cf = count <= (uint32_t)width ? (uint32_t)(((uint64_t)v << count) >> width) & 1 : 0;
        r = count < (uint32_t)width ? (v << count) & mask : 0;
    } else if (op == 1) {
        cf = count <= (uint32_t)width ? (v >> (count - 1)) & 1 : 0;
        r = count < (uint32_t)width ? v >> count : 0;
    } else {
        int32_t sv = (int32_t)(v << (32 - width)) >> (32 - width);
        uint32_t k = count < (uint32_t)width ? count : (uint32_t)width - 1;
        cf = count < (uint32_t)width ? ((uint32_t)sv >> (count - 1)) & 1 : (uint32_t)(sv < 0);
        r = (uint32_t)(sv >> k) & mask;
        if (count >= (uint32_t)width) r = sv < 0 ? mask : 0;
    }
    c->_eflags &= ~(CF | OF);
    if (cf) c->_eflags |= CF;
    if (count == 1) {
        uint32_t of = op == 0 ? (((r & sign) != 0) ^ cf) : op == 1 ? ((v & sign) != 0) : 0;
        if (of) c->_eflags |= OF;
    }
    set_szp(c, r, width);
    return r;
}

void tc_shift32(_cpu *c, uint32_t index, uint32_t value, uint32_t count, uint32_t op)
{
    *reg(c, (int)index) = shift(c, value, count, op, 32);
}

void tc_shift_part(_cpu *c, uint32_t index, uint32_t value, uint32_t count, uint32_t op, uint32_t width, uint32_t offset)
{
    uint32_t mask = ((1u << width) - 1) << offset;
    uint32_t part = shift(c, (value & mask) >> offset, count, op, (int)width);
    *reg(c, (int)index) = (value & ~mask) | (part << offset);
}

void tc_double_shift32(_cpu *c, uint32_t index, uint32_t dst, uint32_t src, uint32_t count, uint32_t right)
{
    count &= 31;
    if (!count) { *reg(c, (int)index) = dst; return; }
    uint32_t r, cf;
    if (right) {
        r = (dst >> count) | (src << (32 - count));
        cf = (dst >> (count - 1)) & 1;
    } else {
        r = (dst << count) | (src >> (32 - count));
        cf = (dst >> (32 - count)) & 1;
    }
    c->_eflags &= ~(CF | OF);
    if (cf) c->_eflags |= CF;
    if (count == 1 && ((r ^ dst) & 0x80000000u)) c->_eflags |= OF;
    set_szp(c, r, 32);
    *reg(c, (int)index) = r;
}

static void cmp_flags(_cpu *c, uint32_t a, uint32_t b, int width)
{
    uint32_t mask = width == 32 ? 0xffffffffu : (1u << width) - 1, sign = 1u << (width - 1);
    uint32_t r = (a - b) & mask;
    c->_eflags &= ~(CF | OF | AF);
    if ((a & mask) < (b & mask)) c->_eflags |= CF;
    if (((a ^ b) & (a ^ r)) & sign) c->_eflags |= OF;
    if ((a ^ b ^ r) & 0x10) c->_eflags |= AF;
    set_szp(c, r, width);
}

/* mode: 0 = single, 1 = repe, 2 = repne */
static void cmps(_cpu *c, uint32_t mode, int size)
{
    int step = (c->_eflags & DF) ? -size : size;
    if (mode && !c->_ecx) return;
    for (;;) {
        uint32_t a = size == 4 ? rd32(c->_esi) : rd16(c->_esi);
        uint32_t b = size == 4 ? rd32(c->_edi) : rd16(c->_edi);
        cmp_flags(c, a, b, size * 8);
        c->_esi += (uint32_t)step;
        c->_edi += (uint32_t)step;
        if (!mode) return;
        if (--c->_ecx == 0) return;
        bool zf = (c->_eflags & ZF) != 0;
        if ((mode == 1 && !zf) || (mode == 2 && zf)) return;
    }
}
void tc_cmps32(_cpu *c, uint32_t mode) { cmps(c, mode, 4); }
void tc_cmps16(_cpu *c, uint32_t mode) { cmps(c, mode, 2); }

uint32_t tc_read_fs(_cpu *c, uint32_t off) { return rd32(T(c)->teb + off); }
void tc_write_fs(_cpu *c, uint32_t off, uint32_t v) { wr32(T(c)->teb + off, v); }

/* Guest CPU model: Pentium Pro class with FPU, TSC, CX8, CMOV and no
 * MMX/SSE. The translator has no MMX/SSE state; code that checks CPUID keeps to
 * its x87 paths, and any SSE instruction reached anyway traps with its address. */
void tc_cpuid(_cpu *c)
{
    uint32_t leaf = c->_eax;
    if (leaf == 0) {
        c->_eax = 1;
        memcpy(&c->_ebx, "Genu", 4); memcpy(&c->_edx, "ineI", 4); memcpy(&c->_ecx, "ntel", 4);
    } else if (leaf == 1) {
        c->_eax = 0x0000068a;          /* family 6 */
        c->_ebx = 0;
        c->_ecx = 0;
        c->_edx = (1u << 0) | (1u << 4) | (1u << 8) | (1u << 15);
    } else {
        c->_eax = c->_ebx = c->_ecx = c->_edx = 0;
    }
}

void tc_rdtsc(_cpu *c)
{
    uint64_t ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);   /* 1 GHz time-stamp counter */
    c->_eax = (uint32_t)ns;
    c->_edx = (uint32_t)(ns >> 32);
}

void tc_unsupported_instruction(_cpu *c, uint32_t address)
{
    (void)c;
    gp_fatal("guest instruction at 0x%08x has no translation (outside the guest CPU model)", address);
}

/* ---------------------------------------------------------------- x87 */
static void push(_cpu *c, double v) { c->_st_top = (c->_st_top + 7) & 7; ST(c, 0) = v; c->_st_sw_cond &= ~X87_C1; }
static double pop(_cpu *c) { double v = ST(c, 0); c->_st_top = (c->_st_top + 1) & 7; return v; }

void tc_x87_load80(_cpu *c, uint32_t a)
{
    uint64_t mant; uint16_t se;
    memcpy(&mant, G(a), 8); memcpy(&se, G(a + 8), 2);
    int e = se & 0x7fff; bool neg = se >> 15;
    double v;
    if (e == 0 && mant == 0) v = 0.0;
    else if (e == 0x7fff) v = (mant << 1) ? NAN : INFINITY;
    else v = ldexp((double)mant, e - 16383 - 63);
    push(c, neg ? -v : v);
}

void tc_x87_store80(_cpu *c, uint32_t a)
{
    double v = pop(c);
    uint64_t mant = 0; uint16_t se = signbit(v) ? 0x8000 : 0;
    if (isnan(v)) { se |= 0x7fff; mant = 0xc000000000000000ull; }
    else if (isinf(v)) { se |= 0x7fff; mant = 0x8000000000000000ull; }
    else if (v != 0.0) {
        int e; double m = frexp(fabs(v), &e);          /* m in [0.5, 1) */
        mant = (uint64_t)ldexp(m, 64);                  /* exact: double has 53 bits */
        se |= (uint16_t)(e - 1 + 16383);
    }
    memcpy(G(a), &mant, 8); memcpy(G(a + 8), &se, 2);
}

void tc_x87_atan(_cpu *c) { double x = pop(c); ST(c, 0) = atan2(ST(c, 0), x); c->_st_sw_cond &= ~X87_C1; }
void tc_x87_clear(_cpu *c) { c->_st_sw_cond &= X87_C0 | X87_C1 | X87_C2 | X87_C3; }
void tc_x87_exp2m1(_cpu *c) { ST(c, 0) = exp2(ST(c, 0)) - 1.0; }
void tc_x87_pi(_cpu *c) { push(c, M_PI); }
void tc_x87_scale(_cpu *c) { ST(c, 0) = ldexp(ST(c, 0), (int)trunc(ST(c, 1))); }

static double round_cw(_cpu *c, double v)
{
    switch ((c->_st_cw >> 10) & 3) {
    case 0: return nearbyint(v);        /* host default mode is round-to-nearest-even */
    case 1: return floor(v);
    case 2: return ceil(v);
    default: return trunc(v);
    }
}
void tc_x87_round(_cpu *c) { ST(c, 0) = round_cw(c, ST(c, 0)); }

/* op order fixed by the translator: ffree fincstp fdecstp fldl2e fldl2t fxam ftst fprem fprem1 fyl2xp1 */
void tc_x87_misc(_cpu *c, uint32_t op, uint32_t r)
{
    double x;
    switch (op) {
    case 0: break;                                           /* ffree: tag word not modelled */
    case 1: c->_st_top = (c->_st_top + 1) & 7; break;
    case 2: c->_st_top = (c->_st_top + 7) & 7; break;
    case 3: push(c, M_LOG2E); break;
    case 4: push(c, log2(10.0)); break;
    case 5:                                                  /* fxam */
        x = ST(c, 0);
        c->_st_sw_cond = signbit(x) ? X87_C1 : 0;
        if (isnan(x)) c->_st_sw_cond |= X87_C0;
        else if (isinf(x)) c->_st_sw_cond |= X87_C0 | X87_C2;
        else if (x == 0.0) c->_st_sw_cond |= X87_C3;
        else if (fpclassify(x) == FP_SUBNORMAL) c->_st_sw_cond |= X87_C2 | X87_C3;
        else c->_st_sw_cond |= X87_C2;
        break;
    case 6:                                                  /* ftst */
        x = ST(c, 0);
        c->_st_sw_cond = isnan(x) ? (X87_C0 | X87_C2 | X87_C3) : x < 0 ? X87_C0 : x == 0 ? X87_C3 : 0;
        break;
    case 7: case 8: {                                        /* fprem / fprem1: complete in one step */
        double y = ST(c, 1), q;
        x = ST(c, 0);
        double rem = op == 7 ? fmod(x, y) : remainder(x, y);
        q = op == 7 ? trunc(x / y) : nearbyint(x / y);
        uint64_t qi = (uint64_t)fabs(q);
        ST(c, 0) = rem;
        c->_st_sw_cond = ((qi & 1) ? X87_C1 : 0) | ((qi & 2) ? X87_C3 : 0) | ((qi & 4) ? X87_C0 : 0);
        break;
    }
    case 9: x = pop(c); ST(c, 0) = ST(c, 0) * log2(1.0 + x); break;
    default: gp_fatal("x87 helper op %u (reg %u)", op, r);
    }
}

void tc_x87_sincos(_cpu *c) { double x = ST(c, 0); ST(c, 0) = sin(x); push(c, cos(x)); c->_st_sw_cond &= ~X87_C2; }


/* SR llasm-support hooks */
void X86_InterruptProcedure(const uint8_t n, void *regs)
{
    (void)regs;
    gp_fatal("guest executed INT %u (int 3 = DebugBreak/assertion)", n);
}

uint32_t X86_InPortProcedure(const uint16_t port, const uint32_t size)
{
    gp_fatal("guest executed IN (%u bytes) from I/O port 0x%x", size, port);
}

void X86_OutPortProcedure(const uint16_t port, const uint32_t size, const uint32_t value)
{
    gp_fatal("guest executed OUT (%u bytes) 0x%x to I/O port 0x%x", size, value, port);
}

/* guest IF flag as tracked by SR llasm_pushx.c (popfd); user-mode code cannot change it */
uint32_t X86_InterruptFlag = 1;

/* ------------------------------------------------------------------ MMX
   Registers are gp_thread.mm[]. Operation codes match mmx_ops in SR_full_llasm_instr.c. */
static inline uint64_t *mmr(_cpu *c, uint32_t i) { return &((gp_thread *)c)->mm[i & 7]; }

void tc_mmx_emms(_cpu *c) { (void)c; }                    /* x87 and MMX state are kept separately */

void tc_mmx_move(_cpu *c, uint32_t mm, uint32_t x, uint32_t mode)
{
    uint64_t *r = mmr(c, mm);
    uint32_t *gpr[8] = { &c->_eax, &c->_ecx, &c->_edx, &c->_ebx, &c->_esp, &c->_ebp, &c->_esi, &c->_edi };
    switch (mode) {
    case 0: *r = *mmr(c, x); break;                                           /* movq mm, mm */
    case 1: memcpy(r, G(x), 8); break;                                        /* movq mm, m64 */
    case 2: memcpy(G(x), r, 8); break;                                        /* movq m64, mm */
    case 3: *r = *gpr[x & 7]; break;                                          /* movd mm, r32 (zero-extended) */
    case 4: { uint32_t v; memcpy(&v, G(x), 4); *r = v; break; }               /* movd mm, m32 */
    case 5: *gpr[x & 7] = (uint32_t)*r; break;                                /* movd r32, mm */
    case 6: { uint32_t v = (uint32_t)*r; memcpy(G(x), &v, 4); break; }        /* movd m32, mm */
    default: gp_fatal("tc_mmx_move: mode %u", mode);
    }
}

static inline int16_t sat16(int32_t v) { return v > 32767 ? 32767 : v < -32768 ? -32768 : (int16_t)v; }
static inline int8_t sat8(int32_t v) { return v > 127 ? 127 : v < -128 ? -128 : (int8_t)v; }
static inline uint8_t usat8(int32_t v) { return v > 255 ? 255 : v < 0 ? 0 : (uint8_t)v; }
static inline uint8_t bat(uint64_t v, int i) { return (uint8_t)(v >> (8 * i)); }
static inline uint16_t wat(uint64_t v, int i) { return (uint16_t)(v >> (16 * i)); }
static inline uint32_t dat(uint64_t v, int i) { return (uint32_t)(v >> (32 * i)); }

void tc_mmx_op(_cpu *c, uint32_t dst, uint32_t src, uint32_t mode, uint32_t op)
{
    uint64_t *d = mmr(c, dst), a = *d, b = 0;
    uint32_t count = 0;
    bool shift = op >= 36;
    if (mode == 2) count = src;                                              /* immediate shift count */
    else if (mode == 0) b = *mmr(c, src);
    else if (op == 27 || op == 28 || op == 29) { uint32_t v; memcpy(&v, G(src), 4); b = v; }   /* punpckl*: m32 */
    else memcpy(&b, G(src), 8);
    if (shift && mode != 2) count = b > 255 ? 255 : (uint32_t)b;             /* count from the low quadword */
    uint64_t r = 0;
    switch (op) {
    case 0: r = a ^ b; break;
    case 1: r = a | b; break;
    case 2: r = a & b; break;
    case 3: r = ~a & b; break;
    case 4: case 7: case 9: case 11: case 14: case 16:                       /* byte add/sub, wrap, signed sat, unsigned sat */
        for (int i = 0; i < 8; i++) {
            int32_t x = op == 7 || op == 14 ? (int8_t)bat(a, i) : bat(a, i), y = op == 7 || op == 14 ? (int8_t)bat(b, i) : bat(b, i);
            int32_t v = op <= 9 ? x + y : x - y;
            uint8_t o = op == 4 || op == 11 ? (uint8_t)v : op == 7 || op == 14 ? (uint8_t)sat8(v) : usat8(v);
            r |= (uint64_t)o << (8 * i);
        }
        break;
    case 5: case 8: case 10: case 12: case 15: case 17:                      /* word add/sub */
        for (int i = 0; i < 4; i++) {
            bool sgn = op == 8 || op == 15;
            int32_t x = sgn ? (int16_t)wat(a, i) : wat(a, i), y = sgn ? (int16_t)wat(b, i) : wat(b, i);
            int32_t v = op <= 10 ? x + y : x - y;
            uint16_t o = op == 5 || op == 12 ? (uint16_t)v : sgn ? (uint16_t)sat16(v) : (uint16_t)(v > 65535 ? 65535 : v < 0 ? 0 : v);
            r |= (uint64_t)o << (16 * i);
        }
        break;
    case 6: r = (uint64_t)(dat(a, 0) + dat(b, 0)) | (uint64_t)(dat(a, 1) + dat(b, 1)) << 32; break;
    case 13: r = (uint64_t)(dat(a, 0) - dat(b, 0)) | (uint64_t)(dat(a, 1) - dat(b, 1)) << 32; break;
    case 18: case 19:
        for (int i = 0; i < 4; i++) {
            int32_t p = (int32_t)(int16_t)wat(a, i) * (int16_t)wat(b, i);
            r |= (uint64_t)(uint16_t)(op == 18 ? p : p >> 16) << (16 * i);
        }
        break;
    case 20:
        for (int i = 0; i < 2; i++) {
            int64_t p = (int64_t)(int16_t)wat(a, 2 * i) * (int16_t)wat(b, 2 * i) + (int64_t)(int16_t)wat(a, 2 * i + 1) * (int16_t)wat(b, 2 * i + 1);
            r |= (uint64_t)(uint32_t)p << (32 * i);
        }
        break;
    case 21: for (int i = 0; i < 8; i++) if (bat(a, i) == bat(b, i)) r |= 0xffull << (8 * i); break;
    case 22: for (int i = 0; i < 4; i++) if (wat(a, i) == wat(b, i)) r |= 0xffffull << (16 * i); break;
    case 23: for (int i = 0; i < 2; i++) if (dat(a, i) == dat(b, i)) r |= 0xffffffffull << (32 * i); break;
    case 24: for (int i = 0; i < 8; i++) if ((int8_t)bat(a, i) > (int8_t)bat(b, i)) r |= 0xffull << (8 * i); break;
    case 25: for (int i = 0; i < 4; i++) if ((int16_t)wat(a, i) > (int16_t)wat(b, i)) r |= 0xffffull << (16 * i); break;
    case 26: for (int i = 0; i < 2; i++) if ((int32_t)dat(a, i) > (int32_t)dat(b, i)) r |= 0xffffffffull << (32 * i); break;
    case 27: for (int i = 0; i < 4; i++) r |= (uint64_t)bat(a, i) << (16 * i) | (uint64_t)bat(b, i) << (16 * i + 8); break;
    case 28: for (int i = 0; i < 2; i++) r |= (uint64_t)wat(a, i) << (32 * i) | (uint64_t)wat(b, i) << (32 * i + 16); break;
    case 29: r = (uint64_t)dat(a, 0) | (uint64_t)dat(b, 0) << 32; break;
    case 30: for (int i = 0; i < 4; i++) r |= (uint64_t)bat(a, 4 + i) << (16 * i) | (uint64_t)bat(b, 4 + i) << (16 * i + 8); break;
    case 31: for (int i = 0; i < 2; i++) r |= (uint64_t)wat(a, 2 + i) << (32 * i) | (uint64_t)wat(b, 2 + i) << (32 * i + 16); break;
    case 32: r = (uint64_t)dat(a, 1) | (uint64_t)dat(b, 1) << 32; break;
    case 33: for (int i = 0; i < 4; i++) r |= (uint64_t)(uint8_t)sat8((int16_t)wat(a, i)) << (8 * i) | (uint64_t)(uint8_t)sat8((int16_t)wat(b, i)) << (8 * i + 32); break;
    case 34: for (int i = 0; i < 2; i++) r |= (uint64_t)(uint16_t)sat16((int32_t)dat(a, i)) << (16 * i) | (uint64_t)(uint16_t)sat16((int32_t)dat(b, i)) << (16 * i + 32); break;
    case 35: for (int i = 0; i < 4; i++) r |= (uint64_t)usat8((int16_t)wat(a, i)) << (8 * i) | (uint64_t)usat8((int16_t)wat(b, i)) << (8 * i + 32); break;
    case 36: if (count < 16) for (int i = 0; i < 4; i++) r |= (uint64_t)(uint16_t)(wat(a, i) << count) << (16 * i); break;
    case 37: if (count < 32) for (int i = 0; i < 2; i++) r |= (uint64_t)(uint32_t)(dat(a, i) << count) << (32 * i); break;
    case 38: r = count < 64 ? a << count : 0; break;
    case 39: if (count < 16) for (int i = 0; i < 4; i++) r |= (uint64_t)(uint16_t)(wat(a, i) >> count) << (16 * i); break;
    case 40: if (count < 32) for (int i = 0; i < 2; i++) r |= (uint64_t)(dat(a, i) >> count) << (32 * i); break;
    case 41: r = count < 64 ? a >> count : 0; break;
    case 42: { uint32_t n = count > 15 ? 15 : count; for (int i = 0; i < 4; i++) r |= (uint64_t)(uint16_t)((int16_t)wat(a, i) >> n) << (16 * i); break; }
    case 43: { uint32_t n = count > 31 ? 31 : count; for (int i = 0; i < 2; i++) r |= (uint64_t)(uint32_t)((int32_t)dat(a, i) >> n) << (32 * i); break; }
    default: gp_fatal("tc_mmx_op: operation %u", op);
    }
    *d = r;
}

/* ------------------------------------------------------------ controller hooks (tools/hooks.py inserts the calls)
   Both return non-zero when they supplied the result; otherwise the game's own code runs. */
#include "gp_gamepad.h"
uint32_t tc_hook_is_command_on(_cpu *c, uint32_t command) { (void)c; return gp_pad_hook_command_on(command); }
uint32_t tc_hook_extremal_value(_cpu *c, uint32_t command)
{
    double v;
    if (!gp_pad_hook_axis(command, &v)) return 0;
    push(c, v);                                       /* the game reads the result from ST0 */
    return 1;
}
void tc_hook_note_cursor(_cpu *c, uint32_t show) { (void)c; gp_pad_note_cursor(show != 0); }
