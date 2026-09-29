/* Direct3D 9 shader bytecode to MSL. Covers what vs_1_1/vs_2_0/ps_1_1..ps_1_4/ps_2_0 use
 * (no flow control in those models' use here: flow-control opcodes are rejected with an error). */
#include "gp_sm.h"
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------- string builder */
typedef struct { char *s; size_t n, cap; } sb;
static void put(sb *b, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void put(sb *b, const char *fmt, ...)
{
    va_list ap;
    for (;;) {
        va_start(ap, fmt);
        int k = vsnprintf(b->s ? b->s + b->n : NULL, b->s ? b->cap - b->n : 0, fmt, ap);
        va_end(ap);
        if (k < 0) return;
        if (b->s && b->n + (size_t)k < b->cap) { b->n += (size_t)k; return; }
        b->cap = (b->cap + (size_t)k + 1) * 2;
        b->s = realloc(b->s, b->cap);
    }
}

/* ------------------------------------------------------------- bytecode model */
enum { R_TEMP, R_INPUT, R_CONST, R_ADDR_TEX, R_RASTOUT, R_ATTROUT, R_TEXCRDOUT_OUTPUT, R_CONSTINT, R_COLOROUT, R_DEPTHOUT,
       R_SAMPLER, R_CONST2, R_CONST3, R_CONST4, R_CONSTBOOL, R_LOOP, R_TEMPF16, R_MISC, R_LABEL, R_PREDICATE };
typedef struct {
    uint8_t type; uint16_t num;
    uint8_t swz[4];                   /* source swizzle */
    uint8_t mask;                     /* destination write mask */
    uint8_t smod;                     /* source modifier */
    uint8_t dmod;                     /* destination modifier bits */
    int8_t shift;                     /* destination shift (ps_1_x) */
    bool rel; uint8_t rel_comp;       /* relative addressing (a0.<comp>) */
} opnd;
typedef struct {
    uint16_t op; uint8_t ctrl; bool coissue, predicated;
    opnd dst; opnd src[4]; int nsrc; bool has_dst;
    uint32_t dcl;                     /* dcl token */
    float fdef[4]; int32_t idef[4];
} ins;

enum { OP_NOP = 0, OP_MOV, OP_ADD, OP_SUB, OP_MAD, OP_MUL, OP_RCP, OP_RSQ, OP_DP3, OP_DP4, OP_MIN, OP_MAX, OP_SLT, OP_SGE,
       OP_EXP, OP_LOG, OP_LIT, OP_DST, OP_LRP, OP_FRC, OP_M4X4, OP_M4X3, OP_M3X4, OP_M3X3, OP_M3X2, OP_CALL, OP_CALLNZ,
       OP_LOOP, OP_RET, OP_ENDLOOP, OP_LABEL, OP_DCL, OP_POW, OP_CRS, OP_SGN, OP_ABS, OP_NRM, OP_SINCOS, OP_REP, OP_ENDREP,
       OP_IF, OP_IFC, OP_ELSE, OP_ENDIF, OP_BREAK, OP_BREAKC, OP_MOVA, OP_DEFB, OP_DEFI,
       OP_TEXCOORD = 64, OP_TEXKILL, OP_TEX, OP_TEXBEM, OP_TEXBEML, OP_TEXREG2AR, OP_TEXREG2GB, OP_TEXM3X2PAD, OP_TEXM3X2TEX,
       OP_TEXM3X3PAD, OP_TEXM3X3TEX, OP_RESERVED0, OP_TEXM3X3SPEC, OP_TEXM3X3VSPEC, OP_EXPP, OP_LOGP, OP_CND, OP_DEF,
       OP_TEXREG2RGB, OP_TEXDP3TEX, OP_TEXM3X2DEPTH, OP_TEXDP3, OP_TEXM3X3, OP_TEXDEPTH, OP_CMP, OP_BEM, OP_DP2ADD, OP_DSX,
       OP_DSY, OP_TEXLDD, OP_SETP, OP_TEXLDL, OP_BREAKP, OP_PHASE = 0xfffd, OP_COMMENT = 0xfffe, OP_END = 0xffff };

typedef struct {
    bool pixel; uint8_t major, minor;
    ins *ins; int n;
    char *err; uint32_t errlen; bool failed;
} prog;

static void fail(prog *p, const char *fmt, ...)
{
    if (p->failed) return;
    p->failed = true;
    va_list ap; va_start(ap, fmt); vsnprintf(p->err, p->errlen, fmt, ap); va_end(ap);
}

static uint8_t regtype(uint32_t t) { return (uint8_t)(((t >> 28) & 7) | ((t >> 8) & 0x18)); }

/* SM1 parameter counts: dst, src */
static void sm1_counts(const prog *p, uint16_t op, int *nd, int *ns)
{
    *nd = 1; *ns = 1;
    switch (op) {
    case OP_NOP: case OP_RET: case OP_ENDLOOP: case OP_ENDREP: case OP_ELSE: case OP_ENDIF: case OP_BREAK: case OP_PHASE: *nd = 0; *ns = 0; return;
    case OP_MOV: case OP_RCP: case OP_RSQ: case OP_EXP: case OP_LOG: case OP_LIT: case OP_FRC: case OP_ABS: case OP_NRM:
    case OP_MOVA: case OP_EXPP: case OP_LOGP: case OP_TEXBEM: case OP_TEXBEML: case OP_TEXREG2AR: case OP_TEXREG2GB:
    case OP_TEXM3X2PAD: case OP_TEXM3X2TEX: case OP_TEXM3X3PAD: case OP_TEXM3X3TEX: case OP_TEXM3X3VSPEC: case OP_TEXREG2RGB:
    case OP_TEXDP3TEX: case OP_TEXM3X2DEPTH: case OP_TEXDP3: case OP_TEXM3X3: case OP_DSX: case OP_DSY: return;
    case OP_ADD: case OP_SUB: case OP_MUL: case OP_DP3: case OP_DP4: case OP_MIN: case OP_MAX: case OP_SLT: case OP_SGE:
    case OP_DST: case OP_M4X4: case OP_M4X3: case OP_M3X4: case OP_M3X3: case OP_M3X2: case OP_POW: case OP_CRS:
    case OP_TEXM3X3SPEC: case OP_BEM: case OP_SETP: case OP_TEXLDL: *ns = 2; return;
    case OP_MAD: case OP_LRP: case OP_SGN: case OP_CND: case OP_CMP: case OP_DP2ADD: *ns = 3; return;
    case OP_TEXCOORD: *ns = (p->major == 1 && p->minor == 4) ? 1 : 0; return;
    case OP_TEX: *ns = p->major >= 2 ? 2 : (p->minor == 4 ? 1 : 0); return;
    case OP_TEXKILL: case OP_TEXDEPTH: *ns = 0; return;
    case OP_SINCOS: *ns = p->major >= 3 ? 1 : 3; return;
    case OP_TEXLDD: *ns = 4; return;
    }
    *nd = -1;
}

static void parse_dst(opnd *o, uint32_t t)
{
    o->type = regtype(t); o->num = t & 0x7ff;
    o->mask = (t >> 16) & 0xf; o->dmod = (t >> 20) & 0xf;
    int s = (int)((t >> 24) & 0xf);
    o->shift = (int8_t)(s >= 8 ? s - 16 : s);
    o->rel = (t >> 13) & 1;
}
static const uint32_t *parse_src(prog *p, opnd *o, const uint32_t *q)
{
    uint32_t t = *q++;
    o->type = regtype(t); o->num = t & 0x7ff;
    for (int i = 0; i < 4; i++) o->swz[i] = (t >> (16 + 2 * i)) & 3;
    o->smod = (t >> 24) & 0xf;
    o->rel = (t >> 13) & 1;
    o->rel_comp = 0;
    if (o->rel && (p->major >= 2)) {                             /* SM2+: explicit address token */
        uint32_t a = *q++;
        o->rel_comp = (a >> 16) & 3;
    }
    return q;
}

static bool parse(prog *p, const uint32_t *code, uint32_t words)
{
    uint32_t v = code[0];
    p->pixel = (v >> 16) == 0xffff;
    p->major = (v >> 8) & 0xff; p->minor = v & 0xff;
    int cap = 256;
    p->ins = calloc((size_t)cap, sizeof(ins));
    const uint32_t *q = code + 1, *end = code + words;
    while (q < end && !p->failed) {
        uint32_t t = *q;
        uint16_t op = t & 0xffff;
        if (op == OP_END) break;
        if (op == OP_COMMENT) { q += 1 + (t >> 16); continue; }
        if (p->n == cap) { cap *= 2; p->ins = realloc(p->ins, (size_t)cap * sizeof(ins)); }
        ins *in = &p->ins[p->n++];
        memset(in, 0, sizeof *in);
        in->op = op; in->ctrl = (t >> 16) & 0xff; in->coissue = (t >> 30) & 1; in->predicated = (t >> 28) & 1;
        if (in->predicated) { fail(p, "predicated instructions are not supported"); break; }
        const uint32_t *params = q + 1;
        const uint32_t *next;
        if (p->major >= 2) next = params + ((t >> 24) & 0xf);
        else if (op == OP_DEF) next = params + 5;
        else if (op == OP_DCL) next = params + 2;
        else {
            int nd, ns;
            sm1_counts(p, op, &nd, &ns);
            if (nd < 0) { fail(p, "opcode %u", op); break; }
            next = params + nd + ns;                             /* SM1 has no relative-address tokens */
        }
        if (next > end) { fail(p, "instruction past end"); break; }
        if (op == OP_DEF || op == OP_DEFI || op == OP_DEFB) {
            parse_dst(&in->dst, params[0]); in->has_dst = true;
            if (op == OP_DEF) memcpy(in->fdef, params + 1, 16);
            else if (op == OP_DEFI) memcpy(in->idef, params + 1, 16);
            else in->idef[0] = (int32_t)params[1];
        } else if (op == OP_DCL) {
            in->dcl = params[0];
            parse_dst(&in->dst, params[1]); in->has_dst = true;
        } else if (op != OP_PHASE && op != OP_NOP) {
            int nd = 1, ns = 0;
            sm1_counts(p, op, &nd, &ns);
            if (nd < 0) { fail(p, "opcode %u", op); break; }
            const uint32_t *r = params;
            if (nd) { parse_dst(&in->dst, *r++); in->has_dst = true; if (in->dst.rel) { fail(p, "relative destination"); break; } }
            for (int i = 0; i < ns && r < next; i++) r = parse_src(p, &in->src[i], r);
            in->nsrc = ns;
        }
        q = next;
    }
    return !p->failed;
}

/* ------------------------------------------------------------- scan (inputs, samplers) */
bool sm_scan(const uint32_t *code, uint32_t words, sm_info *info, char *err, uint32_t errlen)
{
    memset(info, 0, sizeof *info);
    memset(info->sampler_dcl, 255, sizeof info->sampler_dcl);
    prog p = { .err = err, .errlen = errlen };
    if (!parse(&p, code, words)) { free(p.ins); return false; }
    for (int i = 0; i < p.n; i++) {
        ins *in = &p.ins[i];
        if (in->op == OP_DCL) {
            if (!p.pixel && in->dst.type == R_INPUT && in->dst.num < 16) {
                info->input_mask |= (uint16_t)(1u << in->dst.num);
                info->usage[in->dst.num] = in->dcl & 0x1f; info->usage_index[in->dst.num] = (in->dcl >> 16) & 0xf;
            }
            if (p.pixel && in->dst.type == R_SAMPLER && in->dst.num < 16) {
                uint32_t tt = (in->dcl >> 27) & 0xf;                  /* 2: 2D, 3: cube, 4: volume */
                info->sampler_dcl[in->dst.num] = tt == 3 ? SM_TEX_CUBE : tt == 4 ? SM_TEX_3D : SM_TEX_2D;
                info->sampler_mask |= (uint16_t)(1u << in->dst.num);
            }
        }
        if (p.pixel && p.major == 1) {
            if (in->op == OP_TEX || in->op == OP_TEXM3X2TEX || in->op == OP_TEXM3X3TEX || in->op == OP_TEXBEM || in->op == OP_TEXBEML ||
                in->op == OP_TEXREG2AR || in->op == OP_TEXREG2GB || in->op == OP_TEXREG2RGB || in->op == OP_TEXDP3TEX)
                info->sampler_mask |= (uint16_t)(1u << in->dst.num);
        }
    }
    /* vs_1_1 without dcl for an input register it reads is invalid; nothing to add */
    free(p.ins);
    return true;
}

/* ------------------------------------------------------------- emission helpers */
typedef struct {
    prog *p;
    const sm_key *key;
    sm_info *info;
    sb b;
    bool cdef[256], idef_[16], bdef[16];
    float cdefv[256][4]; int32_t idefv[16][4]; int32_t bdefv[16];
    int tmp;
    float m3pad[3][4];
    int pad_src[3];                   /* texm3x2pad / texm3x3pad source registers pending */
    int pad_stage[3];
    int npad;
} gen;

static const char comp_ch[4] = { 'x', 'y', 'z', 'w' };

static void reg_name(gen *g, const opnd *o, char *out, size_t cap)
{
    prog *p = g->p;
    switch (o->type) {
    case R_TEMP: snprintf(out, cap, "r%u", o->num); return;
    case R_INPUT:
        if (!p->pixel) snprintf(out, cap, "iv%u", o->num);
        else snprintf(out, cap, "in.d%u", o->num);
        return;
    case R_CONST: case R_CONST2: case R_CONST3: case R_CONST4: {
        uint32_t n = o->num + (o->type == R_CONST2 ? 2048u : o->type == R_CONST3 ? 4096u : o->type == R_CONST4 ? 6144u : 0u);
        if (o->rel) snprintf(out, cap, "c[clamp(a0.%c + %u, 0, %u)]", comp_ch[o->rel_comp], n, p->pixel ? 223 : 255);
        else if (n < 256 && g->cdef[n]) snprintf(out, cap, "cd%u", n);
        else if (p->pixel && p->major == 1) snprintf(out, cap, "clamp(c[%u], -1.0f, 1.0f)", n);   /* ps_1_x constant range */
        else snprintf(out, cap, "c[%u]", n);
        return;
    }
    case R_ADDR_TEX:
        if (!p->pixel) snprintf(out, cap, "float4(a0)");
        else if (p->major == 1) snprintf(out, cap, "t%u", o->num);      /* texture register */
        else snprintf(out, cap, "in.t%u", o->num);                      /* ps_2: texture coordinate input */
        return;
    case R_CONSTINT: snprintf(out, cap, g->idef_[o->num] ? "float4(ci%u)" : "float4(ints->i[%u])", o->num); return;
    case R_CONSTBOOL: snprintf(out, cap, g->bdef[o->num] ? "cbd%u" : "(ints->b[%u] != 0)", o->num); return;
    case R_COLOROUT: snprintf(out, cap, "oC%u", o->num); return;
    case R_TEMPF16: snprintf(out, cap, "r%u", o->num); return;
    }
    snprintf(out, cap, "/*reg type %u*/float4(0)", o->type);
    fail(p, "source register type %u", o->type);
}

/* source operand as a float4 expression, swizzle and modifier applied */
static void src(gen *g, const opnd *o, char *out, size_t cap)
{
    char r[160], sw[8] = ".";
    reg_name(g, o, r, sizeof r);
    bool ident = o->swz[0] == 0 && o->swz[1] == 1 && o->swz[2] == 2 && o->swz[3] == 3;
    for (int i = 0; i < 4; i++) sw[1 + i] = comp_ch[o->swz[i]];
    sw[5] = 0;
    char base[200];
    if (o->type == R_CONSTBOOL) snprintf(base, sizeof base, "float4(%s ? 1.0f : 0.0f)", r);
    else snprintf(base, sizeof base, "(%s)%s", r, ident ? "" : sw);
    switch (o->smod) {
    case 0: snprintf(out, cap, "%s", base); break;
    case 1: snprintf(out, cap, "(-%s)", base); break;
    case 2: snprintf(out, cap, "(%s - 0.5f)", base); break;
    case 3: snprintf(out, cap, "(0.5f - %s)", base); break;
    case 4: snprintf(out, cap, "(2.0f * %s - 1.0f)", base); break;
    case 5: snprintf(out, cap, "(1.0f - 2.0f * %s)", base); break;
    case 6: snprintf(out, cap, "(1.0f - %s)", base); break;
    case 7: snprintf(out, cap, "(2.0f * %s)", base); break;
    case 8: snprintf(out, cap, "(-2.0f * %s)", base); break;
    case 9: snprintf(out, cap, "(%s / (%s).z)", base, base); break;   /* _dz (ps_1_4 projective) */
    case 10: snprintf(out, cap, "(%s / (%s).w)", base, base); break;  /* _dw */
    case 11: snprintf(out, cap, "abs(%s)", base); break;
    case 12: snprintf(out, cap, "(-abs(%s))", base); break;
    default: snprintf(out, cap, "%s", base); fail(g->p, "source modifier %u", o->smod);
    }
}

/* writes a float4 expression to a destination honouring mask, shift and saturate */
static void dst_write(gen *g, const opnd *d, const char *expr)
{
    prog *p = g->p;
    char name[64];
    switch (d->type) {
    case R_TEMP: case R_TEMPF16: snprintf(name, sizeof name, "r%u", d->num); break;
    case R_ADDR_TEX: snprintf(name, sizeof name, p->pixel ? "t%u" : "a0", d->num); break;
    case R_RASTOUT: snprintf(name, sizeof name, d->num == 0 ? "o.pos" : d->num == 1 ? "ofog" : "opts"); break;
    case R_ATTROUT: snprintf(name, sizeof name, "o.d%u", d->num); break;
    case R_TEXCRDOUT_OUTPUT: snprintf(name, sizeof name, "o.t%u", d->num); break;
    case R_COLOROUT: snprintf(name, sizeof name, "oC%u", d->num); break;
    case R_DEPTHOUT: snprintf(name, sizeof name, "odepth"); break;
    default: fail(p, "destination register type %u", d->type); return;
    }
    char val[1024];
    int n = snprintf(val, sizeof val, "(%s)", expr);
    if (d->shift) {
        static const char *const scale[8] = { "1.0f", "2.0f", "4.0f", "8.0f", "16.0f", "32.0f", "64.0f", "128.0f" };
        if (d->shift > 0) n = snprintf(val, sizeof val, "((%s) * %s)", expr, scale[d->shift & 7]);
        else n = snprintf(val, sizeof val, "((%s) / %s)", expr, scale[(-d->shift) & 7]);
    }
    if (d->dmod & 1) snprintf(val + n, sizeof val - (size_t)n, "%s", "");
    char full[1100];
    snprintf(full, sizeof full, (d->dmod & 1) ? "saturate(%s)" : "%s", val);
    uint8_t mask = d->mask ? d->mask : 0xf;
    if (!strcmp(name, "a0")) {
        /* vs_1_1 "mov a0.x": floor; vs_2 "mova": round to nearest */
        const char *fn = g->p->major >= 2 ? "rint" : "floor";
        for (int i = 0; i < 4; i++) if (mask & (1 << i)) put(&g->b, "    a0.%c = int((%s)(%s).%c);\n", comp_ch[i], fn, full, comp_ch[i]);
        return;
    }
    if (!strcmp(name, "ofog") || !strcmp(name, "opts") || !strcmp(name, "odepth")) {
        put(&g->b, "    %s = (%s).x;\n", name, full);
        return;
    }
    if (mask == 0xf) { put(&g->b, "    %s = %s;\n", name, full); return; }
    char m[5] = {0}; int k = 0;
    for (int i = 0; i < 4; i++) if (mask & (1 << i)) m[k++] = comp_ch[i];
    put(&g->b, "    %s.%s = (%s).%s;\n", name, m, full, m);
}

/* ------------------------------------------------------------- texture sampling */
static uint8_t sampler_type(gen *g, int s)
{
    if (g->info->sampler_dcl[s] != 255) return g->info->sampler_dcl[s];
    return g->key->sampler_type[s];
}
static void sample(gen *g, int s, const char *coord, char *out, size_t cap, const char *extra)
{
    const char *e = extra ? extra : "";
    switch (sampler_type(g, s)) {
    case SM_TEX_CUBE: snprintf(out, cap, "tex%d.sample(smp%d, (%s).xyz%s)", s, s, coord, e); break;
    case SM_TEX_3D: snprintf(out, cap, "tex%d.sample(smp%d, (%s).xyz%s)", s, s, coord, e); break;
    case SM_TEX_SHADOW2D:
        /* depth texture: comparison against z (hardware shadow map behaviour) */
        snprintf(out, cap, "float4(tex%d.sample_compare(smpc%d, (%s).xy, (%s).z))", s, s, coord, coord); break;
    default: snprintf(out, cap, "tex%d.sample(smp%d, (%s).xy%s)", s, s, coord, e);
    }
    g->info->sampler_mask |= (uint16_t)(1u << s);
}

/* ------------------------------------------------------------- instructions */
static void emit(gen *g, ins *in, ins *next)
{
    prog *p = g->p;
    char a[1024] = "", b[1024] = "", c[1024] = "", e[4096];
    if (in->nsrc > 0) src(g, &in->src[0], a, sizeof a);
    if (in->nsrc > 1 && in->src[1].type != R_SAMPLER) src(g, &in->src[1], b, sizeof b);
    if (in->nsrc > 2) src(g, &in->src[2], c, sizeof c);
    (void)next;
    switch (in->op) {
    case OP_NOP: case OP_PHASE: case OP_DCL: case OP_DEF: case OP_DEFI: case OP_DEFB: return;
    case OP_MOV: case OP_MOVA: dst_write(g, &in->dst, a); return;
    case OP_ADD: snprintf(e, sizeof e, "%s + %s", a, b); break;
    case OP_SUB: snprintf(e, sizeof e, "%s - %s", a, b); break;
    case OP_MUL: snprintf(e, sizeof e, "%s * %s", a, b); break;
    case OP_MAD: snprintf(e, sizeof e, "%s * %s + %s", a, b, c); break;
    case OP_LRP: snprintf(e, sizeof e, "mix(%s, %s, %s)", c, b, a); break;
    case OP_MIN: snprintf(e, sizeof e, "min(%s, %s)", a, b); break;
    case OP_MAX: snprintf(e, sizeof e, "max(%s, %s)", a, b); break;
    case OP_SLT: snprintf(e, sizeof e, "select(float4(0.0f), float4(1.0f), %s < %s)", a, b); break;
    case OP_SGE: snprintf(e, sizeof e, "select(float4(0.0f), float4(1.0f), %s >= %s)", a, b); break;
    case OP_RCP: snprintf(e, sizeof e, "float4(1.0f / (%s).x)", a); break;
    case OP_RSQ: snprintf(e, sizeof e, "float4(rsqrt(abs((%s).x)))", a); break;
    case OP_EXP: case OP_EXPP:
        if (in->op == OP_EXPP && p->major < 2) snprintf(e, sizeof e, "sm_expp((%s).x)", a);
        else snprintf(e, sizeof e, "float4(exp2((%s).x))", a);
        break;
    case OP_LOG: case OP_LOGP:
        if (in->op == OP_LOGP && p->major < 2) snprintf(e, sizeof e, "sm_logp((%s).x)", a);
        else snprintf(e, sizeof e, "float4(sm_log((%s).x))", a);
        break;
    case OP_FRC: snprintf(e, sizeof e, "fract(%s)", a); break;
    case OP_ABS: snprintf(e, sizeof e, "abs(%s)", a); break;
    case OP_DP3: snprintf(e, sizeof e, "float4(dot((%s).xyz, (%s).xyz))", a, b); break;
    case OP_DP4: snprintf(e, sizeof e, "float4(dot(%s, %s))", a, b); break;
    case OP_DP2ADD: snprintf(e, sizeof e, "float4(dot((%s).xy, (%s).xy) + (%s).x)", a, b, c); break;
    case OP_LIT: snprintf(e, sizeof e, "sm_lit(%s)", a); break;
    case OP_DST: snprintf(e, sizeof e, "float4(1.0f, (%s).y * (%s).y, (%s).z, (%s).w)", a, b, a, b); break;
    case OP_POW: snprintf(e, sizeof e, "float4(pow(abs((%s).x), (%s).x))", a, b); break;
    case OP_CRS: snprintf(e, sizeof e, "float4(cross((%s).xyz, (%s).xyz), 0.0f)", a, b); break;
    case OP_NRM: snprintf(e, sizeof e, "((%s) * rsqrt(max(dot((%s).xyz, (%s).xyz), 1e-30f)))", a, a, a); break;
    case OP_SINCOS: snprintf(e, sizeof e, "float4(cos((%s).x), sin((%s).x), 0.0f, 0.0f)", a, a); break;
    case OP_CMP: snprintf(e, sizeof e, "select(%s, %s, %s >= 0.0f)", c, b, a); break;
    case OP_CND:
        if (p->major == 1 && p->minor < 4) snprintf(e, sizeof e, "(((%s).w > 0.5f) ? %s : %s)", a, b, c);
        else snprintf(e, sizeof e, "select(%s, %s, %s > 0.5f)", c, b, a);
        break;
    case OP_M4X4: case OP_M4X3: case OP_M3X4: case OP_M3X3: case OP_M3X2: {
        int rows = in->op == OP_M4X4 || in->op == OP_M3X4 ? 4 : in->op == OP_M3X2 ? 2 : 3;
        bool three = in->op == OP_M3X4 || in->op == OP_M3X3 || in->op == OP_M3X2;
        int k = snprintf(e, sizeof e, "float4(");
        for (int r = 0; r < 4; r++) {
            if (r < rows) {
                opnd row = in->src[1];
                row.num = (uint16_t)(row.num + r);
                char rs[256];
                src(g, &row, rs, sizeof rs);
                k += snprintf(e + k, sizeof e - (size_t)k, three ? "dot((%s).xyz, (%s).xyz)" : "dot(%s, %s)", a, rs);
            } else k += snprintf(e + k, sizeof e - (size_t)k, "0.0f");
            k += snprintf(e + k, sizeof e - (size_t)k, r < 3 ? ", " : ")");
        }
        break;
    }
    /* ---- pixel shader texture instructions ---- */
    case OP_TEXCOORD:
        if (p->major == 1 && p->minor == 4) {                  /* texcrd rN, tM (modifiers _dz/_dw via src) */
            char t[256];
            opnd s = in->src[0];
            if (s.type == R_ADDR_TEX) { snprintf(t, sizeof t, "in.t%u", s.num); if (s.smod == 9) snprintf(e, sizeof e, "(%s / %s.z)", t, t); else if (s.smod == 10) snprintf(e, sizeof e, "(%s / %s.w)", t, t); else snprintf(e, sizeof e, "%s", t); }
            else snprintf(e, sizeof e, "%s", a);
        } else snprintf(e, sizeof e, "float4(saturate(in.t%u.xyz), 1.0f)", in->dst.num);
        break;
    case OP_TEXKILL:
        if (p->major == 1 && in->dst.type == R_ADDR_TEX && p->minor < 4) put(&g->b, "    if (any(in.t%u.xyz < 0.0f)) discard_fragment();\n", in->dst.num);
        else if (p->major == 1) put(&g->b, "    if (any(%s%u.xyz < 0.0f)) discard_fragment();\n", in->dst.type == R_TEMP ? "r" : "in.t", in->dst.num);
        else put(&g->b, "    if (any(%s%u < 0.0f)) discard_fragment();\n", in->dst.type == R_TEMP ? "r" : "in.t", in->dst.num);
        return;
    case OP_TEX:
        if (p->major >= 2) {                                   /* texld dst, coord, sN */
            int s = in->src[1].num;
            char coord[1100];
            if (in->ctrl == 1) snprintf(coord, sizeof coord, "((%s) / (%s).w)", a, a);         /* texldp */
            else snprintf(coord, sizeof coord, "%s", a);
            char extra[256] = "";
            if (in->ctrl == 2) snprintf(extra, sizeof extra, ", bias((%s).w)", a);             /* texldb */
            else snprintf(extra, sizeof extra, ", bias(m->lod_bias[%d])", s);
            sample(g, s, coord, e, sizeof e, extra);
        } else if (p->minor == 4) {                            /* texld rN, tM/rM */
            int s = in->dst.num;
            char coord[1100];
            opnd so = in->src[0];
            if (so.type == R_ADDR_TEX) {
                if (so.smod == 9) snprintf(coord, sizeof coord, "(in.t%u / in.t%u.z)", so.num, so.num);
                else if (so.smod == 10) snprintf(coord, sizeof coord, "(in.t%u / in.t%u.w)", so.num, so.num);
                else snprintf(coord, sizeof coord, "in.t%u", so.num);
            } else snprintf(coord, sizeof coord, "%s", a);
            char extra[64]; snprintf(extra, sizeof extra, ", bias(m->lod_bias[%d])", s);
            sample(g, s, coord, e, sizeof e, extra);
        } else {                                               /* tex tN */
            int s = in->dst.num;
            char coord[128];
            uint8_t div = g->key->ps_texcoord_projected[s] ? 1 : 0;
            if (div) snprintf(coord, sizeof coord, "(in.t%d / in.t%d.w)", s, s);
            else snprintf(coord, sizeof coord, "in.t%d", s);
            char extra[64]; snprintf(extra, sizeof extra, ", bias(m->lod_bias[%d])", s);
            sample(g, s, coord, e, sizeof e, extra);
        }
        break;
    case OP_TEXM3X2PAD: case OP_TEXM3X3PAD:
        /* first rows of a texm3x2/texm3x3: u = dot(texcoord(dst).xyz, src.xyz) */
        put(&g->b, "    float pad%u = dot(in.t%u.xyz, (%s).xyz);\n", in->dst.num, in->dst.num, a);
        return;
    case OP_TEXM3X2TEX: {
        int s = in->dst.num;
        char coord[512];
        snprintf(coord, sizeof coord, "float4(pad%d, dot(in.t%d.xyz, (%s).xyz), 0.0f, 1.0f)", s - 1, s, a);
        char extra[64]; snprintf(extra, sizeof extra, ", bias(m->lod_bias[%d])", s);
        sample(g, s, coord, e, sizeof e, extra);
        break;
    }
    case OP_TEXM3X3TEX: {
        int s = in->dst.num;
        char coord[512];
        snprintf(coord, sizeof coord, "float4(pad%d, pad%d, dot(in.t%d.xyz, (%s).xyz), 1.0f)", s - 2, s - 1, s, a);
        char extra[64]; snprintf(extra, sizeof extra, ", bias(m->lod_bias[%d])", s);
        sample(g, s, coord, e, sizeof e, extra);
        break;
    }
    case OP_TEXBEM: case OP_TEXBEML: {
        /* dst tex coords perturbed by the bump matrix of stage dst applied to src.xy */
        int s = in->dst.num;
        char coord[768];
        snprintf(coord, sizeof coord, "float4(in.t%d.x + m->bumpenv[%d].x * (%s).x + m->bumpenv[%d].z * (%s).y, "
                 "in.t%d.y + m->bumpenv[%d].y * (%s).x + m->bumpenv[%d].w * (%s).y, 0.0f, 1.0f)", s, s, a, s, a, s, s, a, s, a);
        char extra[64]; snprintf(extra, sizeof extra, ", bias(m->lod_bias[%d])", s);
        sample(g, s, coord, e, sizeof e, extra);
        break;
    }
    default:
        fail(p, "instruction %u (%s shader %u.%u) is not translated", in->op, p->pixel ? "pixel" : "vertex", p->major, p->minor);
        return;
    }
    dst_write(g, &in->dst, e);
}

/* ------------------------------------------------------------- program */
static const char *prelude =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct sm_vs_misc { float4 pos_fixup; float4 clip[6]; };\n"
    "struct sm_ps_misc { float alpha_ref; uint alpha_func; uint fog_mode; float fog_start, fog_end, fog_density;"
    " float2 pad; float4 fog_color; float lod_bias[16]; float4 bumpenv[8]; };\n"
    "struct sm_ints { int4 i[16]; uint b[16]; };\n"
    "static inline float sm_log(float x) { float a = abs(x); return a == 0.0f ? -3.402823466e38f : log2(a); }\n"
    "static inline float4 sm_expp(float x) { float f = floor(x); return float4(exp2(f), x - f, exp2(x), 1.0f); }\n"
    "static inline float4 sm_logp(float x) { float a = abs(x); if (a == 0.0f) return float4(-3.402823466e38f, 1.0f, -3.402823466e38f, 1.0f);"
    " float e = floor(log2(a)); return float4(e, a / exp2(e), log2(a), 1.0f); }\n"
    "static inline float4 sm_lit(float4 s) { float4 r = float4(1.0f, 0.0f, 0.0f, 1.0f);"
    " if (s.x > 0.0f) { r.y = s.x; if (s.y > 0.0f) r.z = pow(s.y, clamp(s.w, -127.9961f, 127.9961f)); } return r; }\n"
    "static inline bool sm_alpha_ok(float a, float ref, uint f) {\n"
    "  switch (f) { case 1: return false; case 2: return a < ref; case 3: return a == ref; case 4: return a <= ref;\n"
    "  case 5: return a > ref; case 6: return a != ref; case 7: return a >= ref; default: return true; } }\n"
    "struct sm_varyings { float4 pos [[position]]; float4 d0 [[user(d0)]]; float4 d1 [[user(d1)]];"
    " float4 t0 [[user(t0)]]; float4 t1 [[user(t1)]]; float4 t2 [[user(t2)]]; float4 t3 [[user(t3)]];"
    " float4 t4 [[user(t4)]]; float4 t5 [[user(t5)]]; float4 t6 [[user(t6)]]; float4 t7 [[user(t7)]];"
    " float fog [[user(fog)]]; };\n";

char *sm_translate(const uint32_t *code, uint32_t words, const sm_key *key, sm_info *info, char *err, uint32_t errlen)
{
    prog p = { .err = err, .errlen = errlen };
    if (!sm_scan(code, words, info, err, errlen)) return NULL;
    if (!parse(&p, code, words)) { free(p.ins); return NULL; }
    gen g = { .p = &p, .key = key, .info = info };
    sb *b = &g.b;
    put(b, "%s", prelude);
    /* defs are shader-local constants overriding the API ones */
    for (int i = 0; i < p.n; i++) {
        ins *in = &p.ins[i];
        if (in->op == OP_DEF && in->dst.num < 256) { g.cdef[in->dst.num] = true; memcpy(g.cdefv[in->dst.num], in->fdef, 16); }
        if (in->op == OP_DEFI && in->dst.num < 16) { g.idef_[in->dst.num] = true; memcpy(g.idefv[in->dst.num], in->idef, 16); }
        if (in->op == OP_DEFB && in->dst.num < 16) { g.bdef[in->dst.num] = true; g.bdefv[in->dst.num] = in->idef[0]; }
    }
    int maxr = 0;
    for (int i = 0; i < p.n; i++) {
        ins *in = &p.ins[i];
        if (in->has_dst && (in->dst.type == R_TEMP || in->dst.type == R_TEMPF16) && in->dst.num + 1 > maxr) maxr = in->dst.num + 1;
        for (int k = 0; k < in->nsrc; k++) if ((in->src[k].type == R_TEMP || in->src[k].type == R_TEMPF16) && in->src[k].num + 1 > maxr) maxr = in->src[k].num + 1;
    }
    if (p.pixel && p.major == 1 && maxr < 1) maxr = 1;         /* r0 is the ps_1_x output */

    if (!p.pixel) {
        bool any = false;
        for (int r = 0; r < 16; r++) if ((info->input_mask & (1u << r)) && key->input_class[r]) any = true;
        if (any) {
            put(b, "struct vin {\n");
            for (int r = 0; r < 16; r++) {
                if (!(info->input_mask & (1u << r)) || !key->input_class[r]) continue;
                static const char *const ty[4] = { "", "float4", "uint4", "int4" };
                put(b, "  %s v%d [[attribute(%d)]];\n", ty[key->input_class[r]], r, r);
            }
            put(b, "};\n");
        }
        put(b, "struct vout { float4 pos [[position]]; float4 d0 [[user(d0)]]; float4 d1 [[user(d1)]];"
               " float4 t0 [[user(t0)]]; float4 t1 [[user(t1)]]; float4 t2 [[user(t2)]]; float4 t3 [[user(t3)]];"
               " float4 t4 [[user(t4)]]; float4 t5 [[user(t5)]]; float4 t6 [[user(t6)]]; float4 t7 [[user(t7)]];"
               " float fog [[user(fog)]]; float psize [[point_size]]; float clip [[clip_distance]] [%d]; };\n",
               key->clip_planes ? 6 : 1);
        put(b, "vertex vout gp_main(%sconstant float4 *c [[buffer(16)]], constant sm_vs_misc *m [[buffer(17)]],"
               " constant sm_ints *ints [[buffer(18)]]) {\n", any ? "vin vi [[stage_in]], " : "");
        put(b, "    vout o = {};\n    o.d0 = float4(0.0f); o.d1 = float4(0.0f);\n    float ofog = 1.0f; float opts = 1.0f;\n    int4 a0 = int4(0);\n");
        for (int r = 0; r < 16; r++) {
            if (!(info->input_mask & (1u << r))) continue;
            if (!key->input_class[r]) put(b, "    float4 iv%d = float4(0.0f, 0.0f, 0.0f, 1.0f);\n", r);
            else put(b, "    float4 iv%d = float4(vi.v%d);\n", r, r);
        }
        /* vs_1_1 shaders may read inputs without dcl only when invalid; nothing else to declare */
    } else {
        put(b, "struct pout {");
        uint8_t outs = 0;
        for (int i = 0; i < p.n; i++) if (p.ins[i].has_dst && p.ins[i].dst.type == R_COLOROUT) outs |= (uint8_t)(1u << p.ins[i].dst.num);
        if (p.major == 1) outs = 1;
        info->color_outputs = outs;
        for (int k = 0; k < 4; k++) if (outs & (1u << k)) put(b, " float4 c%d [[color(%d)]];", k, k);
        bool depth = false;
        for (int i = 0; i < p.n; i++) if (p.ins[i].has_dst && p.ins[i].dst.type == R_DEPTHOUT) depth = true;
        info->writes_depth = depth;
        if (depth) put(b, " float depth [[depth(any)]];");
        put(b, " };\n");
        put(b, "fragment pout gp_main(sm_varyings in [[stage_in]], constant float4 *c [[buffer(0)]], constant sm_ps_misc *m [[buffer(1)]],"
               " constant sm_ints *ints [[buffer(2)]]");
        for (int s = 0; s < 16; s++) {
            if (!(info->sampler_mask & (1u << s))) continue;
            uint8_t ty = sampler_type(&g, s);
            const char *tt = ty == SM_TEX_CUBE ? "texturecube<float>" : ty == SM_TEX_3D ? "texture3d<float>" : ty == SM_TEX_SHADOW2D ? "depth2d<float>" : "texture2d<float>";
            /* a shadow map is only sampled with comparison, so its comparison sampler takes the slot */
            put(b, ", %s tex%d [[texture(%d)]], sampler %s%d [[sampler(%d)]]", tt, s, s, ty == SM_TEX_SHADOW2D ? "smpc" : "smp", s, s);
        }
        put(b, ") {\n    pout o;\n");
        for (int k = 0; k < 4; k++) if (outs & (1u << k)) put(b, "    float4 oC%d = float4(0.0f);\n", k);
        if (depth) put(b, "    float odepth = in.pos.z;\n");
        if (p.major == 1) {
            for (int t = 0; t < 8; t++) put(b, "    float4 t%d = float4(0.0f);\n", t);
            /* ps_1_x colour inputs are clamped to [0,1] */
            put(b, "    in.d0 = saturate(in.d0); in.d1 = saturate(in.d1);\n");
        }
    }
    for (int r = 0; r < maxr; r++) put(b, "    float4 r%d = float4(0.0f);\n", r);
    for (int k = 0; k < 256; k++) {
        if (!g.cdef[k]) continue;
        uint32_t u[4];
        memcpy(u, g.cdefv[k], 16);                              /* bit-exact literals */
        put(b, "    const float4 cd%d = float4(as_type<float>(0x%08xu), as_type<float>(0x%08xu), as_type<float>(0x%08xu), as_type<float>(0x%08xu));\n",
            k, u[0], u[1], u[2], u[3]);
    }
    for (int k = 0; k < 16; k++) {
        if (g.idef_[k]) put(b, "    const int4 ci%d = int4(%d, %d, %d, %d);\n", k, g.idefv[k][0], g.idefv[k][1], g.idefv[k][2], g.idefv[k][3]);
        if (g.bdef[k]) put(b, "    const bool cbd%d = %s;\n", k, g.bdefv[k] ? "true" : "false");
    }

    /* instructions; a co-issued pair reads all sources before either writes */
    for (int i = 0; i < p.n && !p.failed; i++) {
        ins *in = &p.ins[i];
        if (in->op == OP_CALL || in->op == OP_CALLNZ || in->op == OP_LOOP || in->op == OP_REP || in->op == OP_IF ||
            in->op == OP_IFC || in->op == OP_BREAK || in->op == OP_BREAKC || in->op == OP_LABEL) {
            fail(&p, "flow control (opcode %u) in shader model %u.%u", in->op, p.major, p.minor);
            break;
        }
        bool pair = i + 1 < p.n && p.ins[i + 1].coissue;
        if (pair) {
            /* evaluate the first into a copy of its destination, then the second, then commit */
            put(b, "    {\n");
            char nm[16];
            opnd d = in->dst;
            snprintf(nm, sizeof nm, "%s%u", d.type == R_TEMP ? "r" : "t", d.num);
            put(b, "    float4 _co = %s;\n", nm);
            ins copy = *in;
            copy.dst.type = R_TEMP; copy.dst.num = 250;                /* scratch register r250 */
            put(b, "    float4 r250 = _co;\n");
            emit(&g, &copy, NULL);
            emit(&g, &p.ins[i + 1], NULL);
            char m[5] = {0}; int k = 0;
            uint8_t mask = d.mask ? d.mask : 0xf;
            for (int j = 0; j < 4; j++) if (mask & (1 << j)) m[k++] = comp_ch[j];
            put(b, "    %s.%s = r250.%s;\n    }\n", nm, m, m);
            i++;
            continue;
        }
        emit(&g, in, NULL);
    }
    if (p.failed) { free(p.ins); free(b->s); return NULL; }

    if (!p.pixel) {
        put(b, "    o.pos.xy += m->pos_fixup.xy * o.pos.w;\n");
        put(b, "    o.d0 = saturate(o.d0); o.d1 = saturate(o.d1);\n");
        put(b, "    o.fog = saturate(ofog);\n    o.psize = opts;\n");
        if (key->clip_planes) {
            for (int k = 0; k < 6; k++) {
                if (key->clip_planes & (1 << k)) put(b, "    o.clip[%d] = dot(o.pos, m->clip[%d]);\n", k, k);
                else put(b, "    o.clip[%d] = 1.0f;\n", k);
            }
        } else put(b, "    o.clip[0] = 1.0f;\n");
        put(b, "    return o;\n}\n");
    } else {
        if (p.major == 1) put(b, "    oC0 = r0;\n");
        put(b, "    if (!sm_alpha_ok(oC0.w, m->alpha_ref, m->alpha_func)) discard_fragment();\n");
        put(b, "    if (m->fog_mode != 0) {\n"
               "        float f;\n"
               "        float z = in.pos.z / in.pos.w;\n"      /* table fog uses depth */
               "        if (m->fog_mode == 4) f = in.fog;\n"
               "        else if (m->fog_mode == 3) f = saturate((m->fog_end - z) / (m->fog_end - m->fog_start));\n"
               "        else if (m->fog_mode == 1) f = exp(-m->fog_density * z);\n"
               "        else f = exp(-(m->fog_density * z) * (m->fog_density * z));\n"
               "        oC0.xyz = mix(m->fog_color.xyz, oC0.xyz, saturate(f));\n"
               "    }\n");
        for (int k = 0; k < 4; k++) if (info->color_outputs & (1u << k)) put(b, "    o.c%d = oC%d;\n", k, k);
        if (info->writes_depth) put(b, "    o.depth = odepth;\n");
        put(b, "    return o;\n}\n");
    }
    free(p.ins);
    return b->s;
}

#ifdef GP_SM_SELF_CHECK
/* translates every shader file given (raw bytecode) for a default key */
int main(int argc, char **argv)
{
    int bad = 0;
    for (int i = 1; i < argc; i++) {
        FILE *f = fopen(argv[i], "rb");
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        uint32_t *w = malloc((size_t)n);
        if (fread(w, 1, (size_t)n, f) != (size_t)n) return 2;
        fclose(f);
        sm_key k = {0};
        for (int r = 0; r < 16; r++) k.input_class[r] = 1;
        sm_info info;
        char err[256];
        char *s = sm_translate(w, (uint32_t)(n / 4), &k, &info, err, sizeof err);
        if (!s) { printf("FAIL %s: %s\n", argv[i], err); bad++; }
        else if (getenv("SM_OUT")) { char p[600]; snprintf(p, sizeof p, "%s/%s.metal", getenv("SM_OUT"), strrchr(argv[i], '/') + 1); FILE *o = fopen(p, "w"); fputs(s, o); fclose(o); }
        free(s); free(w);
    }
    printf("%d shaders, %d failed\n", argc - 1, bad);
    return bad != 0;
}
#endif
