/* fx_2_0 effect binaries, CTAB constant tables and preshader programs.
 * Written for this port from the binary format; Wine's d3dx9 was used as a
 * format reference (state table order, section layout), not as code. */
#include "gp_fx.h"
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* --------------------------------------------------------------- state table
   Order is fixed by the binary format: a state's operation is an index here. */
#define RS(x) { SC_RENDERSTATE, x, #x }
#define TSS(x) { SC_TEXTURESTAGE, x, #x }
#define SS(x) { SC_SAMPLERSTATE, x, #x }
const fx_state_info fx_state_table[] = {
    {0,7,"ZENABLE"},{0,8,"FILLMODE"},{0,9,"SHADEMODE"},{0,14,"ZWRITEENABLE"},{0,15,"ALPHATESTENABLE"},{0,16,"LASTPIXEL"},
    {0,19,"SRCBLEND"},{0,20,"DESTBLEND"},{0,22,"CULLMODE"},{0,23,"ZFUNC"},{0,24,"ALPHAREF"},{0,25,"ALPHAFUNC"},
    {0,26,"DITHERENABLE"},{0,27,"ALPHABLENDENABLE"},{0,28,"FOGENABLE"},{0,29,"SPECULARENABLE"},{0,34,"FOGCOLOR"},
    {0,35,"FOGTABLEMODE"},{0,36,"FOGSTART"},{0,37,"FOGEND"},{0,38,"FOGDENSITY"},{0,48,"RANGEFOGENABLE"},
    {0,52,"STENCILENABLE"},{0,53,"STENCILFAIL"},{0,54,"STENCILZFAIL"},{0,55,"STENCILPASS"},{0,56,"STENCILFUNC"},
    {0,57,"STENCILREF"},{0,58,"STENCILMASK"},{0,59,"STENCILWRITEMASK"},{0,60,"TEXTUREFACTOR"},
    {0,128,"WRAP0"},{0,129,"WRAP1"},{0,130,"WRAP2"},{0,131,"WRAP3"},{0,132,"WRAP4"},{0,133,"WRAP5"},{0,134,"WRAP6"},
    {0,135,"WRAP7"},{0,198,"WRAP8"},{0,199,"WRAP9"},{0,200,"WRAP10"},{0,201,"WRAP11"},{0,202,"WRAP12"},{0,203,"WRAP13"},
    {0,204,"WRAP14"},{0,205,"WRAP15"},{0,136,"CLIPPING"},{0,137,"LIGHTING"},{0,139,"AMBIENT"},{0,140,"FOGVERTEXMODE"},
    {0,141,"COLORVERTEX"},{0,142,"LOCALVIEWER"},{0,143,"NORMALIZENORMALS"},{0,145,"DIFFUSEMATERIALSOURCE"},
    {0,146,"SPECULARMATERIALSOURCE"},{0,147,"AMBIENTMATERIALSOURCE"},{0,148,"EMISSIVEMATERIALSOURCE"},
    {0,151,"VERTEXBLEND"},{0,152,"CLIPPLANEENABLE"},{0,154,"POINTSIZE"},{0,155,"POINTSIZE_MIN"},{0,166,"POINTSIZE_MAX"},
    {0,156,"POINTSPRITEENABLE"},{0,157,"POINTSCALEENABLE"},{0,158,"POINTSCALE_A"},{0,159,"POINTSCALE_B"},
    {0,160,"POINTSCALE_C"},{0,161,"MULTISAMPLEANTIALIAS"},{0,162,"MULTISAMPLEMASK"},{0,163,"PATCHEDGESTYLE"},
    {0,165,"DEBUGMONITORTOKEN"},{0,167,"INDEXEDVERTEXBLENDENABLE"},{0,168,"COLORWRITEENABLE"},{0,170,"TWEENFACTOR"},
    {0,171,"BLENDOP"},{0,172,"POSITIONDEGREE"},{0,173,"NORMALDEGREE"},{0,174,"SCISSORTESTENABLE"},
    {0,175,"SLOPESCALEDEPTHBIAS"},{0,176,"ANTIALIASEDLINEENABLE"},{0,178,"MINTESSELLATIONLEVEL"},
    {0,179,"MAXTESSELLATIONLEVEL"},{0,180,"ADAPTIVETESS_X"},{0,181,"ADAPTIVETESS_Y"},{0,182,"ADAPTIVETESS_Z"},
    {0,183,"ADAPTIVETESS_W"},{0,184,"ENABLEADAPTIVETESSELLATION"},{0,185,"TWOSIDEDSTENCILMODE"},
    {0,186,"CCW_STENCILFAIL"},{0,187,"CCW_STENCILZFAIL"},{0,188,"CCW_STENCILPASS"},{0,189,"CCW_STENCILFUNC"},
    {0,190,"COLORWRITEENABLE1"},{0,191,"COLORWRITEENABLE2"},{0,192,"COLORWRITEENABLE3"},{0,193,"BLENDFACTOR"},
    {0,194,"SRGBWRITEENABLE"},{0,195,"DEPTHBIAS"},{0,206,"SEPARATEALPHABLENDENABLE"},{0,207,"SRCBLENDALPHA"},
    {0,208,"DESTBLENDALPHA"},{0,209,"BLENDOPALPHA"},
    {1,1,"COLOROP"},{1,26,"COLORARG0"},{1,2,"COLORARG1"},{1,3,"COLORARG2"},{1,4,"ALPHAOP"},{1,27,"ALPHAARG0"},
    {1,5,"ALPHAARG1"},{1,6,"ALPHAARG2"},{1,28,"RESULTARG"},{1,7,"BUMPENVMAT00"},{1,8,"BUMPENVMAT01"},{1,9,"BUMPENVMAT10"},
    {1,10,"BUMPENVMAT11"},{1,11,"TEXCOORDINDEX"},{1,22,"BUMPENVLSCALE"},{1,23,"BUMPENVLOFFSET"},
    {1,24,"TEXTURETRANSFORMFLAGS"},{1,32,"CONSTANT"},
    {SC_NPATCHMODE,0,"NPatchMode"},{SC_FVF,0,"FVF"},
    {SC_TRANSFORM,3,"PROJECTION"},{SC_TRANSFORM,2,"VIEW"},{SC_TRANSFORM,256,"WORLD"},{SC_TRANSFORM,16,"TEXTURE0"},
    {SC_MATERIAL,0,"MaterialDiffuse"},{SC_MATERIAL,1,"MaterialAmbient"},{SC_MATERIAL,2,"MaterialSpecular"},
    {SC_MATERIAL,3,"MaterialEmissive"},{SC_MATERIAL,4,"MaterialPower"},
    {SC_LIGHT,0,"LightType"},{SC_LIGHT,1,"LightDiffuse"},{SC_LIGHT,2,"LightSpecular"},{SC_LIGHT,3,"LightAmbient"},
    {SC_LIGHT,4,"LightPosition"},{SC_LIGHT,5,"LightDirection"},{SC_LIGHT,6,"LightRange"},{SC_LIGHT,7,"LightFallOff"},
    {SC_LIGHT,8,"LightAttenuation0"},{SC_LIGHT,9,"LightAttenuation1"},{SC_LIGHT,10,"LightAttenuation2"},
    {SC_LIGHT,11,"LightTheta"},{SC_LIGHT,12,"LightPhi"},
    {SC_LIGHTENABLE,0,"LightEnable"},{SC_VERTEXSHADER,0,"VertexShader"},{SC_PIXELSHADER,0,"PixelShader"},
    /* shader constants: code 0 VS float, 1 VS bool, 2 VS int, 3 PS float, 4 PS bool, 5 PS int */
    {SC_SHADERCONST,0,"VertexShaderConstantF"},{SC_SHADERCONST,1,"VertexShaderConstantB"},{SC_SHADERCONST,2,"VertexShaderConstantI"},
    {SC_SHADERCONST,0,"VertexShaderConstant"},{SC_SHADERCONST,0,"VertexShaderConstant1"},{SC_SHADERCONST,0,"VertexShaderConstant2"},
    {SC_SHADERCONST,0,"VertexShaderConstant3"},{SC_SHADERCONST,0,"VertexShaderConstant4"},
    {SC_SHADERCONST,3,"PixelShaderConstantF"},{SC_SHADERCONST,4,"PixelShaderConstantB"},{SC_SHADERCONST,5,"PixelShaderConstantI"},
    {SC_SHADERCONST,3,"PixelShaderConstant"},{SC_SHADERCONST,3,"PixelShaderConstant1"},{SC_SHADERCONST,3,"PixelShaderConstant2"},
    {SC_SHADERCONST,3,"PixelShaderConstant3"},{SC_SHADERCONST,3,"PixelShaderConstant4"},
    {SC_TEXTURE,0,"Texture"},
    {SC_SAMPLERSTATE,1,"AddressU"},{SC_SAMPLERSTATE,2,"AddressV"},{SC_SAMPLERSTATE,3,"AddressW"},{SC_SAMPLERSTATE,4,"BorderColor"},
    {SC_SAMPLERSTATE,5,"MagFilter"},{SC_SAMPLERSTATE,6,"MinFilter"},{SC_SAMPLERSTATE,7,"MipFilter"},
    {SC_SAMPLERSTATE,8,"MipMapLodBias"},{SC_SAMPLERSTATE,9,"MaxMipLevel"},{SC_SAMPLERSTATE,10,"MaxAnisotropy"},
    {SC_SAMPLERSTATE,11,"SRGBTexture"},{SC_SAMPLERSTATE,12,"ElementIndex"},{SC_SAMPLERSTATE,13,"DMAPOffset"},
    {SC_SETSAMPLER,0,"Sampler"},
};
const uint32_t fx_state_count = sizeof fx_state_table / sizeof *fx_state_table;

/* --------------------------------------------------------------- reader */
typedef struct {
    const uint8_t *base;              /* offsets are relative to this */
    uint32_t size;
    char *err; uint32_t errlen;
    bool failed;
} rd;

static void fail(rd *r, const char *fmt, ...)
{
    if (r->failed) return;
    r->failed = true;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(r->err, r->errlen, fmt, ap);
    va_end(ap);
}
static uint32_t u32at(rd *r, uint32_t off)
{
    if ((uint64_t)off + 4 > r->size) { fail(r, "read past end at 0x%x", off); return 0; }
    uint32_t v; memcpy(&v, r->base + off, 4); return v;
}
static uint32_t next(rd *r, uint32_t *pos) { uint32_t v = u32at(r, *pos); *pos += 4; return v; }

static char *name_at(rd *r, uint32_t off)
{
    uint32_t n = u32at(r, off);
    if (r->failed || !n) return NULL;
    if ((uint64_t)off + 4 + n > r->size) { fail(r, "name past end"); return NULL; }
    char *s = malloc(n + 1);
    memcpy(s, r->base + off + 4, n);
    s[n] = 0;
    return s;
}

/* --------------------------------------------------------------- parse */
typedef struct { rd r; fx_effect *e; } ctx;

static void parse_typedef(ctx *c, fx_param *p, uint32_t *pos, const fx_param *parent, uint32_t flags)
{
    rd *r = &c->r;
    p->flags = flags;
    if (!parent) {
        p->type = next(r, pos); p->klass = next(r, pos);
        p->name = name_at(r, next(r, pos));
        p->semantic = name_at(r, next(r, pos));
        p->elements = next(r, pos);
        switch (p->klass) {
        case PC_VECTOR: p->cols = next(r, pos); p->rows = next(r, pos); p->bytes = 4 * p->rows * p->cols; break;
        case PC_SCALAR: case PC_MATRIX_ROWS: case PC_MATRIX_COLUMNS:
            p->rows = next(r, pos); p->cols = next(r, pos); p->bytes = 4 * p->rows * p->cols; break;
        case PC_STRUCT: p->nmembers = next(r, pos); break;
        case PC_OBJECT:
            if (fx_is_sampler(p->type)) p->bytes = 0;
            else if (p->type == PT_STRING || fx_is_texture(p->type) || fx_is_shader(p->type)) p->bytes = 4;
            else fail(r, "object parameter of type %u", p->type);
            break;
        default: fail(r, "parameter class %u", p->klass);
        }
    } else {
        p->type = parent->type; p->klass = parent->klass;
        p->name = parent->name ? strdup(parent->name) : NULL;
        p->semantic = parent->semantic ? strdup(parent->semantic) : NULL;
        p->elements = 0; p->nmembers = parent->nmembers; p->bytes = parent->bytes;
        p->rows = parent->rows; p->cols = parent->cols;
    }
    if (r->failed) return;
    if (p->elements) {
        if (p->elements > 65536) { fail(r, "element count %u", p->elements); return; }
        p->members = calloc(p->elements, sizeof *p->members);
        uint32_t save = *pos, total = 0;
        for (uint32_t i = 0; i < p->elements && !r->failed; i++) {
            *pos = save;
            parse_typedef(c, &p->members[i], pos, p, flags);
            total += p->members[i].bytes;
        }
        p->bytes = total;
    } else if (p->nmembers) {
        if (p->nmembers > 4096) { fail(r, "member count %u", p->nmembers); return; }
        p->members = calloc(p->nmembers, sizeof *p->members);
        for (uint32_t i = 0; i < p->nmembers && !r->failed; i++) {
            parse_typedef(c, &p->members[i], pos, NULL, flags);
            p->bytes += p->members[i].bytes;
        }
    }
}

static void parse_state(ctx *c, fx_state *s, uint32_t *pos);

/* assign value storage and read object ids / samplers; value bytes already copied into buf */
static void parse_value(ctx *c, fx_param *p, uint8_t *buf, uint32_t *pos)
{
    rd *r = &c->r;
    p->data = buf;
    uint32_t n = p->elements ? p->elements : (p->klass == PC_STRUCT ? p->nmembers : 0);
    if (n) {
        uint32_t off = 0;
        for (uint32_t i = 0; i < n && !r->failed; i++) {
            parse_value(c, &p->members[i], buf ? buf + off : NULL, pos);
            off += p->members[i].bytes;
        }
        return;
    }
    if (p->klass != PC_OBJECT) return;
    if (fx_is_sampler(p->type)) {
        p->sampler = calloc(1, sizeof *p->sampler);
        p->sampler->n = next(r, pos);
        if (p->sampler->n > 256) { fail(r, "sampler state count %u", p->sampler->n); return; }
        p->sampler->states = calloc(p->sampler->n ? p->sampler->n : 1, sizeof(fx_state));
        for (uint32_t i = 0; i < p->sampler->n && !r->failed; i++) parse_state(c, &p->sampler->states[i], pos);
    } else {
        p->object_id = next(r, pos);
        if (p->object_id >= c->e->nobjects) fail(r, "object id %u out of %u", p->object_id, c->e->nobjects);
    }
}

static void parse_init_value(ctx *c, fx_param *p, uint32_t off)
{
    uint8_t *buf = p->bytes ? calloc(1, p->bytes) : NULL;
    if (buf && p->klass != PC_OBJECT) {
        if ((uint64_t)off + p->bytes > c->r.size) { fail(&c->r, "value past end"); free(buf); return; }
        memcpy(buf, c->r.base + off, p->bytes);
    }
    uint32_t pos = off;
    parse_value(c, p, buf, &pos);
}

static void parse_annotations(ctx *c, fx_param **out, uint32_t n, uint32_t *pos)
{
    if (!n) return;
    if (n > 4096) { fail(&c->r, "annotation count %u", n); return; }
    *out = calloc(n, sizeof **out);
    for (uint32_t i = 0; i < n && !c->r.failed; i++) {
        uint32_t tpos = next(&c->r, pos);
        parse_typedef(c, &(*out)[i], &tpos, NULL, 0);
        parse_init_value(c, &(*out)[i], next(&c->r, pos));
    }
}

static void parse_state(ctx *c, fx_state *s, uint32_t *pos)
{
    rd *r = &c->r;
    s->kind = ST_CONSTANT;
    s->op = next(r, pos);
    if (s->op >= fx_state_count) { fail(r, "state operation %u", s->op); return; }
    s->index = next(r, pos);
    uint32_t tpos = next(r, pos);
    parse_typedef(c, &s->value, &tpos, NULL, 0);
    parse_init_value(c, &s->value, next(r, pos));
    uint8_t k = fx_state_table[s->op].klass;
    if ((k == SC_VERTEXSHADER || k == SC_PIXELSHADER || k == SC_TEXTURE) && s->value.bytes < 4) {
        /* "VertexShader = NULL" is stored as an int 0 */
        free(s->value.data);
        s->value.data = calloc(1, 4);
        s->value.bytes = 4;
    }
}

static const uint32_t *find_comment(const uint32_t *p, uint32_t words, uint32_t fourcc, uint32_t *size)
{
    while (words > 2 && (p[0] & 0xffff) == 0xfffe) {
        uint32_t n = p[0] >> 16;
        if (!n || n + 1 > words) break;
        if (p[1] == fourcc) { *size = n - 1; return p + 2; }
        words -= n + 1;
        p += n + 1;
    }
    return NULL;
}

/* --------------------------------------------------------------- CTAB */
bool fx_parse_ctab(const uint32_t *code, uint32_t words, fx_ctab *out)
{
    memset(out, 0, sizeof *out);
    uint32_t size;
    const uint32_t *t = find_comment(code + 1, words - 1, 0x42415443 /* 'CTAB' */, &size);
    if (!t) return true;                       /* no table is valid */
    const uint8_t *b = (const uint8_t *)t;
    uint32_t bytes = size * 4;
#define CU32(o) ((o) + 4 <= bytes ? *(const uint32_t *)(b + (o)) : 0)
#define CU16(o) ((o) + 2 <= bytes ? *(const uint16_t *)(b + (o)) : 0)
    if (bytes < 28 || CU32(0) != 28) return false;
    uint32_t n = CU32(12), info = CU32(16);
    if (n > 4096 || info + 20 * n > bytes) return false;
    out->c = calloc(n ? n : 1, sizeof *out->c);
    out->n = n;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t o = info + 20 * i;
        fx_ctab_const *k = &out->c[i];
        uint32_t name = CU32(o);
        if (name >= bytes) return false;
        k->name = strndup((const char *)b + name, bytes - name);
        k->regset = CU16(o + 4); k->reg = CU16(o + 6); k->count = CU16(o + 8);
        uint32_t ti = CU32(o + 12);
        if (ti + 16 > bytes) return false;
        k->klass = CU16(ti); k->type = CU16(ti + 2); k->rows = CU16(ti + 4); k->cols = CU16(ti + 6); k->elements = CU16(ti + 8);
    }
#undef CU32
#undef CU16
    return true;
}

/* --------------------------------------------------------------- preshader */
static const struct { uint16_t code; uint8_t ninputs; } ops[] = {
    {0x000,0},{0x100,1},{0x101,1},{0x103,1},{0x104,1},{0x105,1},{0x106,1},{0x107,1},{0x108,1},{0x109,1},{0x10a,1},
    {0x10b,1},{0x10c,1},{0x200,2},{0x201,2},{0x202,2},{0x203,2},{0x204,2},{0x205,2},{0x206,2},{0x208,2},{0x300,3},
    {0x500,2},{0x70e,6},{0x70e,8},
};
enum { OP_NOP, OP_MOV, OP_NEG, OP_RCP, OP_FRC, OP_EXP, OP_LOG, OP_RSQ, OP_SIN, OP_COS, OP_ASIN, OP_ACOS, OP_ATAN,
       OP_MIN, OP_MAX, OP_LT, OP_GE, OP_ADD, OP_MUL, OP_ATAN2, OP_DIV, OP_CMP, OP_DOT, OP_DOTSWIZ6, OP_DOTSWIZ8 };

static bool parse_reg(const uint32_t **p, const uint32_t *end, uint8_t *table, uint32_t *offset)
{
    static const uint8_t map[8] = { TAB_COUNT, TAB_IMMED, TAB_CONST, TAB_INPUT, TAB_OCONST, TAB_OBCONST, TAB_OICONST, TAB_TEMP };
    if (*p + 2 > end || (*p)[0] >= 8 || map[(*p)[0]] == TAB_COUNT) return false;
    *table = map[(*p)[0]]; *offset = (*p)[1];
    *p += 2;
    return true;
}
static bool parse_operand(const uint32_t **p, const uint32_t *end, fx_operand *o)
{
    if (*p >= end) return false;
    uint32_t indexed = *(*p)++;
    o->index_table = TAB_COUNT;
    if (indexed) {
        if (indexed != 1 || !parse_reg(p, end, &o->index_table, &o->index_offset)) return false;
    }
    if (!parse_reg(p, end, &o->table, &o->offset)) return false;
    if (o->table == TAB_OBCONST) o->offset /= 4;
    return true;
}

static uint32_t comps(uint8_t table) { return table == TAB_OBCONST ? 1 : 4; }

fx_preshader *fx_parse_preshader(const uint32_t *p, uint32_t words, fx_effect *e, char *err, uint32_t errlen)
{
    (void)e;
    fx_preshader *pr = calloc(1, sizeof *pr);
    if (words < 2) return pr;                                    /* magic only: no instructions */
    uint32_t size;
    const uint32_t *lit = find_comment(p + 1, words - 1, 0x54494c43 /* CLIT */, &size);
    if (lit) {
        uint32_t n = lit[0];
        if (n > (size - 1) / 2) { snprintf(err, errlen, "literal table too large"); free(pr); return NULL; }
        pr->immed = malloc(sizeof(double) * (n ? n : 1));
        memcpy(pr->immed, lit + 1, sizeof(double) * n);
        pr->nimmed = n;
    }
    const uint32_t *code = find_comment(p + 1, words - 1, 0x434c5846 /* FXLC */, &size);
    if (code) {
        const uint32_t *end = code + size, *q = code + 1;
        pr->nins = code[0];
        if (pr->nins > 65536) { snprintf(err, errlen, "too many preshader instructions"); free(pr); return NULL; }
        pr->ins = calloc(pr->nins ? pr->nins : 1, sizeof *pr->ins);
        for (uint32_t i = 0; i < pr->nins; i++) {
            fx_ins *in = &pr->ins[i];
            if (q + 2 > end) { snprintf(err, errlen, "truncated instruction %u", i); free(pr); return NULL; }
            uint32_t raw = *q++, ninputs = *q++;
            uint32_t code_op = (raw & 0x7ff00000) >> 20;
            in->ncomp = (uint8_t)(raw & 0xffff);
            in->scalar = (raw & 0x80000000u) != 0;
            if (in->ncomp < 1 || in->ncomp > 4) { snprintf(err, errlen, "bad component count %u", in->ncomp); free(pr); return NULL; }
            uint32_t k = 0;
            while (k < sizeof ops / sizeof *ops && !(ops[k].code == code_op && ops[k].ninputs == ninputs)) k++;
            if (k == sizeof ops / sizeof *ops || ninputs > 8) {
                snprintf(err, errlen, "unknown preshader opcode 0x%x/%u", code_op, ninputs); free(pr); return NULL;
            }
            in->op = (uint16_t)k; in->ninputs = (uint8_t)ninputs;
            for (uint32_t j = 0; j < ninputs; j++)
                if (!parse_operand(&q, end, &in->in[j])) { snprintf(err, errlen, "bad operand"); free(pr); return NULL; }
            if (!parse_operand(&q, end, &in->out) || in->out.index_table != TAB_COUNT) { snprintf(err, errlen, "bad output"); free(pr); return NULL; }
            uint32_t *sz = in->out.table == TAB_TEMP ? &pr->temps : &pr->outs;
            uint32_t last = in->out.offset + (in->op == OP_DOT ? 1 : in->ncomp);
            if (in->out.table == TAB_OBCONST) last = in->out.offset + 1;
            if (in->out.table == TAB_TEMP || in->out.table == TAB_OCONST) { if (last > *sz) *sz = last; }
        }
    }
    /* the preshader's own constant table: comments after the first word, as in a shader */
    uint32_t *copy = malloc(4 * words);
    memcpy(copy, p, 4 * words);
    copy[0] = 0xfffe0000u;
    fx_parse_ctab(copy, words, &pr->inputs);
    free(copy);
    for (uint32_t i = 0; i < pr->inputs.n; i++) {
        uint32_t end_c = 4u * ((uint32_t)pr->inputs.c[i].reg + pr->inputs.c[i].count);
        if (pr->inputs.c[i].regset == RS_FLOAT4 && end_c > pr->consts) pr->consts = end_c;
    }
    pr->temps = (pr->temps + 3) & ~3u;
    return pr;
}

/* register file for one evaluation; inputs (TAB_CONST) filled by the caller */
typedef struct { double *immed; float *consts; float *temps; float *outf; int32_t *outi; uint32_t *outb;
                 uint32_t n[TAB_COUNT]; } regs;

static double get(const regs *R, uint8_t table, uint32_t off)
{
    if (off >= R->n[table]) {
        if (!R->n[table]) return 0.0;
        uint32_t reg = off / comps(table), nreg = R->n[table] / comps(table), wrap = 1;
        if (table == TAB_CONST) { while (wrap < nreg) wrap <<= 1; } else wrap = nreg;
        reg %= wrap;
        if (reg >= nreg) return 0.0;
        off = reg * comps(table) + off % comps(table);
    }
    switch (table) {
    case TAB_IMMED: return R->immed[off];
    case TAB_CONST: return R->consts[off];
    case TAB_TEMP: return R->temps[off];
    case TAB_OCONST: return R->outf[off];
    case TAB_OICONST: return R->outi[off];
    case TAB_OBCONST: return R->outb[off];
    }
    return 0.0;
}
static void set(regs *R, uint8_t table, uint32_t off, double v)
{
    if (off >= R->n[table]) return;
    switch (table) {
    case TAB_TEMP: R->temps[off] = (float)v; break;
    case TAB_OCONST: R->outf[off] = (float)v; break;
    case TAB_OICONST: R->outi[off] = (int32_t)lrint(v); break;
    case TAB_OBCONST: R->outb[off] = v != 0.0; break;
    }
}
static double arg(const regs *R, const fx_operand *o, uint32_t comp)
{
    uint32_t base = 0;
    if (o->index_table != TAB_COUNT) base = (uint32_t)lrint(get(R, o->index_table, o->index_offset)) * comps(o->table);
    return get(R, o->table, base + o->offset + comp);
}

bool fx_run_preshader_regs(const fx_preshader *pr, const float *inputs, float *outf, uint32_t nf, int32_t *outi, uint32_t *outb)
{
    float temps[1024] = {0};
    if (pr->temps > 1024) return false;
    regs R = { pr->immed, (float *)inputs, temps, outf, outi, outb, {0} };
    R.n[TAB_IMMED] = pr->nimmed; R.n[TAB_CONST] = pr->consts; R.n[TAB_TEMP] = pr->temps;
    R.n[TAB_OCONST] = nf; R.n[TAB_OICONST] = outi ? 64 : 0; R.n[TAB_OBCONST] = outb ? 16 : 0;
    for (uint32_t i = 0; i < pr->nins; i++) {
        const fx_ins *in = &pr->ins[i];
        double a[8], r = 0;
        if (in->op == OP_DOT) {
            double s = 0;
            for (uint32_t c = 0; c < in->ncomp; c++)
                s += arg(&R, &in->in[0], in->scalar ? 0 : c) * arg(&R, &in->in[1], c);
            set(&R, in->out.table, in->out.offset, s);
            continue;
        }
        for (uint32_t c = 0; c < in->ncomp; c++) {
            for (uint32_t k = 0; k < in->ninputs; k++) a[k] = arg(&R, &in->in[k], in->scalar && k == 0 ? 0 : c);
            switch (in->op) {
            case OP_NOP: continue;
            case OP_MOV: r = a[0]; break;
            case OP_NEG: r = -a[0]; break;
            case OP_RCP: r = 1.0 / a[0]; break;
            case OP_FRC: r = a[0] - floor(a[0]); break;
            case OP_EXP: r = exp2(a[0]); break;
            case OP_LOG: r = fabs(a[0]) == 0.0 ? 0.0 : log2(fabs(a[0])); break;   /* matches native: log(0) = 0 */
            case OP_RSQ: r = fabs(a[0]) == 0.0 ? INFINITY : 1.0 / sqrt(fabs(a[0])); break;
            case OP_SIN: r = sin(a[0]); break;
            case OP_COS: r = cos(a[0]); break;
            case OP_ASIN: r = asin(a[0]); break;
            case OP_ACOS: r = acos(a[0]); break;
            case OP_ATAN: r = atan(a[0]); break;
            case OP_MIN: r = fmin(a[0], a[1]); break;
            case OP_MAX: r = fmax(a[0], a[1]); break;
            case OP_LT: r = a[0] < a[1] ? 1.0 : 0.0; break;
            case OP_GE: r = a[0] >= a[1] ? 1.0 : 0.0; break;
            case OP_ADD: r = a[0] + a[1]; break;
            case OP_MUL: r = a[0] * a[1]; break;
            case OP_ATAN2: r = atan2(a[0], a[1]); break;
            case OP_DIV: r = a[0] / a[1]; break;
            case OP_CMP: r = a[0] >= 0.0 ? a[1] : a[2]; break;
            case OP_DOTSWIZ6: r = a[0] * a[3] + a[1] * a[4] + a[2] * a[5]; break;
            case OP_DOTSWIZ8: r = a[0] * a[4] + a[1] * a[5] + a[2] * a[6] + a[3] * a[7]; break;
            }
            set(&R, in->out.table, in->out.offset + c, r);
        }
    }
    return true;
}

/* --------------------------------------------------------------- effect */
static void collect_objects(ctx *c, uint32_t *pos, uint32_t count)
{
    rd *r = &c->r;
    for (uint32_t i = 0; i < count && !r->failed; i++) {
        uint32_t id = next(r, pos);
        uint32_t size = next(r, pos);
        if (id >= c->e->nobjects || (uint64_t)*pos + size > r->size) { fail(r, "object %u of %u bytes out of range", id, size); return; }
        fx_object *o = &c->e->objects[id];
        free(o->data);
        o->data = malloc(size ? size : 1);
        memcpy(o->data, r->base + *pos, size);
        o->size = size;
        *pos += (size + 3) & ~3u;
    }
}

static void parse_resource(ctx *c, uint32_t *pos)
{
    rd *r = &c->r;
    uint32_t tech = next(r, pos), index = next(r, pos), element = next(r, pos), state_index = next(r, pos), usage = next(r, pos);
    fx_state *s = NULL;
    if (r->failed) return;
    if (tech == 0xffffffffu) {
        if (index >= c->e->nparams) { fail(r, "resource parameter %u", index); return; }
        fx_param *p = &c->e->params[index];
        if (element != 0xffffffffu && p->elements) {
            if (element >= p->elements) { fail(r, "resource element %u", element); return; }
            p = &p->members[element];
        }
        if (!p->sampler || state_index >= p->sampler->n) { fail(r, "resource sampler state %u", state_index); return; }
        s = &p->sampler->states[state_index];
    } else {
        if (tech >= c->e->ntechniques || index >= c->e->techniques[tech].npasses) { fail(r, "resource pass %u/%u", tech, index); return; }
        fx_pass *ps = &c->e->techniques[tech].passes[index];
        if (state_index >= ps->nstates) { fail(r, "resource state %u", state_index); return; }
        s = &ps->states[state_index];
    }
    /* the resource carries the object data for the state's value */
    uint32_t id = s->value.object_id;
    uint32_t size = next(r, pos);
    if (id >= c->e->nobjects || (uint64_t)*pos + size > r->size) { fail(r, "resource object %u", id); return; }
    fx_object *o = &c->e->objects[id];
    free(o->data);
    o->data = malloc(size ? size : 1);
    memcpy(o->data, r->base + *pos, size);
    o->size = size;
    *pos += (size + 3) & ~3u;
    switch (usage) {
    case 0:
        if (fx_is_shader(s->value.type)) s->kind = ST_CONSTANT;       /* inline compiled shader */
        else if (s->value.type == PT_BOOL || s->value.type == PT_INT || s->value.type == PT_FLOAT || s->value.type == PT_STRING) {
            if (o->size < 4) break;                              /* no expression: the constant value stands */
            s->kind = ST_FXLC;
            s->expr = fx_parse_preshader((const uint32_t *)o->data, o->size / 4, c->e, r->err, r->errlen);
            if (!s->expr) r->failed = true;
        } else fail(r, "resource usage 0 for type %u", s->value.type);
        break;
    case 1:                                                      /* reference to a named parameter */
        s->kind = ST_PARAMETER;
        s->ref = fx_find_param(c->e, (const char *)o->data);
        if (!s->ref) fail(r, "state references unknown parameter %s", (const char *)o->data);
        break;
    case 2: {                                                    /* array selector: name + index expression */
        uint32_t n; memcpy(&n, o->data, 4);
        s->kind = ST_ARRAY_SELECTOR;
        s->ref = fx_find_param(c->e, (const char *)o->data + 4);
        if (!s->ref) { fail(r, "array selector references unknown parameter"); break; }
        s->expr = fx_parse_preshader((const uint32_t *)(o->data + n) + 1, (o->size - n - 4) / 4, c->e, r->err, r->errlen);
        if (!s->expr) r->failed = true;
        break;
    }
    default: fail(r, "resource usage %u", usage);
    }
}

static void set_top(fx_param *p, fx_param *top)
{
    p->top = top;
    uint32_t n = p->elements ? p->elements : p->nmembers;
    for (uint32_t i = 0; i < n; i++) set_top(&p->members[i], top);
}

fx_effect *fx_parse(const uint8_t *blob, uint32_t size, char *err, uint32_t errlen)
{
    if (size < 8) { snprintf(err, errlen, "effect too small"); return NULL; }
    uint32_t tag, start;
    memcpy(&tag, blob, 4); memcpy(&start, blob + 4, 4);
    if (tag != 0xfeff0901u) { snprintf(err, errlen, "not an fx_2_0 effect (tag 0x%08x)", tag); return NULL; }
    ctx c = { { blob + 8, size - 8, err, errlen, false }, calloc(1, sizeof(fx_effect)) };
    rd *r = &c.r;
    uint32_t pos = start;
    fx_effect *e = c.e;
    e->nparams = next(r, &pos);
    e->ntechniques = next(r, &pos);
    next(r, &pos);                                               /* shader slot count */
    e->nobjects = next(r, &pos);
    if (e->nparams > 65536 || e->ntechniques > 4096 || e->nobjects > 65536) fail(r, "implausible counts");
    if (r->failed) { fx_free(e); return NULL; }
    e->objects = calloc(e->nobjects ? e->nobjects : 1, sizeof *e->objects);
    e->params = calloc(e->nparams ? e->nparams : 1, sizeof *e->params);
    for (uint32_t i = 0; i < e->nparams && !r->failed; i++) {
        fx_param *p = &e->params[i];
        uint32_t tpos = next(r, &pos), voff = next(r, &pos);
        uint32_t flags = next(r, &pos), nann = next(r, &pos);
        parse_typedef(&c, p, &tpos, NULL, flags);
        parse_init_value(&c, p, voff);
        parse_annotations(&c, &p->annotations, nann, &pos);
        p->nannotations = nann;
        set_top(p, p);
    }
    e->techniques = calloc(e->ntechniques ? e->ntechniques : 1, sizeof *e->techniques);
    for (uint32_t i = 0; i < e->ntechniques && !r->failed; i++) {
        fx_technique *t = &e->techniques[i];
        t->name = name_at(r, next(r, &pos));
        t->nannotations = next(r, &pos);
        t->npasses = next(r, &pos);
        if (t->npasses > 256) { fail(r, "pass count %u", t->npasses); break; }
        parse_annotations(&c, &t->annotations, t->nannotations, &pos);
        t->passes = calloc(t->npasses ? t->npasses : 1, sizeof *t->passes);
        for (uint32_t k = 0; k < t->npasses && !r->failed; k++) {
            fx_pass *ps = &t->passes[k];
            ps->name = name_at(r, next(r, &pos));
            ps->nannotations = next(r, &pos);
            ps->nstates = next(r, &pos);
            if (ps->nstates > 4096) { fail(r, "state count %u", ps->nstates); break; }
            parse_annotations(&c, &ps->annotations, ps->nannotations, &pos);
            ps->states = calloc(ps->nstates ? ps->nstates : 1, sizeof *ps->states);
            for (uint32_t s = 0; s < ps->nstates && !r->failed; s++) parse_state(&c, &ps->states[s], &pos);
        }
    }
    uint32_t nstrings = next(r, &pos), nresources = next(r, &pos);
    collect_objects(&c, &pos, nstrings);
    for (uint32_t i = 0; i < nresources && !r->failed; i++) parse_resource(&c, &pos);
    if (r->failed) { fx_free(e); return NULL; }
    /* shader objects: constant table and optional preshader */
    e->shaders = calloc(e->nobjects ? e->nobjects : 1, sizeof *e->shaders);
    for (uint32_t i = 0; i < e->nobjects; i++) {
        fx_object *o = &e->objects[i];
        if (!o->data || o->size < 8) continue;
        uint32_t first; memcpy(&first, o->data, 4);
        if ((first & 0xfffe0000u) != 0xfffe0000u) continue;        /* vs_x_x 0xFFFE0xxx, ps_x_x 0xFFFF0xxx */
        fx_shader *sh = calloc(1, sizeof *sh);
        sh->code = (uint32_t *)o->data; sh->words = o->size / 4;
        sh->pixel = (first & 0xffff0000u) == 0xffff0000u;
        if (!fx_parse_ctab(sh->code, sh->words, &sh->ctab)) { snprintf(err, errlen, "bad CTAB in shader object %u", i); fx_free(e); return NULL; }
        uint32_t psize;
        const uint32_t *pres = find_comment(sh->code + 1, sh->words - 1, 0x53455250 /* PRES */, &psize);
        if (pres) {
            sh->pres = fx_parse_preshader(pres, psize, e, err, errlen);
            if (!sh->pres) { fx_free(e); return NULL; }
        }
        e->shaders[i] = sh;
    }
    return e;
}

static void free_param(fx_param *p, bool owns_data)
{
    uint32_t n = p->elements ? p->elements : p->nmembers;
    for (uint32_t i = 0; i < n; i++) free_param(&p->members[i], false);
    free(p->members);
    for (uint32_t i = 0; i < p->nannotations; i++) free_param(&p->annotations[i], true);
    free(p->annotations);
    if (p->sampler) {
        for (uint32_t i = 0; i < p->sampler->n; i++) free_param(&p->sampler->states[i].value, true);
        free(p->sampler->states);
        free(p->sampler);
    }
    free(p->name); free(p->semantic);
    if (owns_data) free(p->data);
}
void fx_free(fx_effect *e)
{
    if (!e) return;
    for (uint32_t i = 0; i < e->nparams; i++) free_param(&e->params[i], true);
    for (uint32_t t = 0; t < e->ntechniques; t++) {
        fx_technique *tq = &e->techniques[t];
        for (uint32_t k = 0; k < tq->npasses; k++) {
            for (uint32_t s = 0; s < tq->passes[k].nstates; s++) free_param(&tq->passes[k].states[s].value, true);
            free(tq->passes[k].states); free(tq->passes[k].name);
            for (uint32_t a = 0; a < tq->passes[k].nannotations; a++) free_param(&tq->passes[k].annotations[a], true);
            free(tq->passes[k].annotations);
        }
        free(tq->passes); free(tq->name);
        for (uint32_t a = 0; a < tq->nannotations; a++) free_param(&tq->annotations[a], true);
        free(tq->annotations);
    }
    free(e->techniques); free(e->params);
    for (uint32_t i = 0; i < e->nobjects; i++) { free(e->objects[i].data); free(e->shaders ? e->shaders[i] : NULL); }
    free(e->objects); free(e->shaders); free(e);
}

/* "name", "struct.member", "array[3]", combinations */
static fx_param *find_in(fx_param *list, uint32_t n, const char *name)
{
    size_t len = strcspn(name, ".[");
    for (uint32_t i = 0; i < n; i++) {
        fx_param *p = &list[i];
        if (!p->name || strlen(p->name) != len || strncmp(p->name, name, len)) continue;
        const char *rest = name + len;
        while (*rest == '[') {
            char *end;
            unsigned long k = strtoul(rest + 1, &end, 10);
            if (*end != ']' || !p->elements || k >= p->elements) return NULL;
            p = &p->members[k];
            rest = end + 1;
        }
        if (!*rest) return p;
        if (*rest == '.' && p->klass == PC_STRUCT && !p->elements) return find_in(p->members, p->nmembers, rest + 1);
        return NULL;
    }
    return NULL;
}
fx_param *fx_find_param(fx_effect *e, const char *name) { return name ? find_in(e->params, e->nparams, name) : NULL; }

#ifdef GP_FX_SELF_CHECK
/* Parses every effect file given on the command line and runs every preshader once. */
int main(int argc, char **argv)
{
    int bad = 0;
    uint32_t ntech = 0, npass = 0, nshader = 0, npres = 0, nfxlc = 0;
    for (int i = 1; i < argc; i++) {
        FILE *f = fopen(argv[i], "rb");
        if (!f) { perror(argv[i]); return 2; }
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        uint8_t *b = malloc((size_t)n);
        if (fread(b, 1, (size_t)n, f) != (size_t)n) return 2;
        fclose(f);
        char err[256] = "";
        fx_effect *e = fx_parse(b, (uint32_t)n, err, sizeof err);
        if (!e) { printf("FAIL %s: %s\n", argv[i], err); bad++; free(b); continue; }
        ntech += e->ntechniques;
        for (uint32_t t = 0; t < e->ntechniques; t++) {
            npass += e->techniques[t].npasses;
            for (uint32_t k = 0; k < e->techniques[t].npasses; k++)
                for (uint32_t s = 0; s < e->techniques[t].passes[k].nstates; s++) {
                    fx_state *st = &e->techniques[t].passes[k].states[s];
                    if (st->expr) {
                        float in[4096] = {0}, out[16] = {0};
                        if (st->expr->consts > 4096 || !fx_run_preshader_regs(st->expr, in, out, 16, NULL, NULL)) { printf("FAIL %s: expression run\n", argv[i]); bad++; }
                        nfxlc++;
                    }
                }
        }
        for (uint32_t o = 0; o < e->nobjects; o++) if (e->shaders[o]) {
            nshader++;
            if (getenv("FX_DUMP")) {
                char path[512]; snprintf(path, sizeof path, "%s/%05u.bin", getenv("FX_DUMP"), nshader);
                FILE *df = fopen(path, "wb"); fwrite(e->shaders[o]->code, 4, e->shaders[o]->words, df); fclose(df);
            }
            fx_shader *sh = e->shaders[o];
            for (uint32_t k = 0; k < sh->ctab.n; k++)
                if (!fx_find_param(e, sh->ctab.c[k].name)) { printf("FAIL %s: shader constant %s has no parameter\n", argv[i], sh->ctab.c[k].name); bad++; }
            if (sh->pres) {
                npres++;
                float in[4096] = {0}, out[1024] = {0};
                if (sh->pres->consts > 4096 || !fx_run_preshader_regs(sh->pres, in, out, 1024, NULL, NULL)) { printf("FAIL %s: preshader run\n", argv[i]); bad++; }
            }
        }
        fx_free(e);
        free(b);
    }
    printf("%d files, %d failed; %u techniques, %u passes, %u shaders, %u preshaders, %u state expressions\n",
           argc - 1, bad, ntech, npass, nshader, npres, nfxlc);
    return bad != 0;
}
#endif
