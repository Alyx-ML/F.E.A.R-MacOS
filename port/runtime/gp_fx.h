/* D3DX effect (fx_2_0) binaries, shader constant tables and preshaders.
 * Host-side data model; the ID3DXEffect COM layer (gp_fx_effect.m) sits on top. */
#ifndef GP_FX_H
#define GP_FX_H
#include <stdbool.h>
#include <stdint.h>

enum { PT_VOID, PT_BOOL, PT_INT, PT_FLOAT, PT_STRING, PT_TEXTURE, PT_TEXTURE1D, PT_TEXTURE2D, PT_TEXTURE3D,
       PT_TEXTURECUBE, PT_SAMPLER, PT_SAMPLER1D, PT_SAMPLER2D, PT_SAMPLER3D, PT_SAMPLERCUBE, PT_PIXELSHADER,
       PT_VERTEXSHADER, PT_PIXELFRAGMENT, PT_VERTEXFRAGMENT };
enum { PC_SCALAR, PC_VECTOR, PC_MATRIX_ROWS, PC_MATRIX_COLUMNS, PC_OBJECT, PC_STRUCT };
enum { RS_BOOL, RS_INT4, RS_FLOAT4, RS_SAMPLER };

static inline bool fx_is_sampler(uint32_t t) { return t >= PT_SAMPLER && t <= PT_SAMPLERCUBE; }
static inline bool fx_is_texture(uint32_t t) { return t >= PT_TEXTURE && t <= PT_TEXTURECUBE; }
static inline bool fx_is_shader(uint32_t t) { return t == PT_PIXELSHADER || t == PT_VERTEXSHADER; }

/* ------------------------------------------------------------- preshaders */
enum { TAB_IMMED, TAB_CONST, TAB_INPUT, TAB_OCONST, TAB_OBCONST, TAB_OICONST, TAB_TEMP, TAB_COUNT };
typedef struct { uint8_t table; uint32_t offset; uint8_t index_table; uint32_t index_offset; } fx_operand;
typedef struct { uint16_t op; uint8_t ncomp; bool scalar; uint8_t ninputs; fx_operand in[8], out; } fx_ins;

typedef struct fx_ctab_const {
    char *name;
    uint16_t regset, reg, count;
    uint16_t klass, type, rows, cols, elements;
    struct fx_param *param;           /* bound effect parameter (NULL if none) */
} fx_ctab_const;
typedef struct { fx_ctab_const *c; uint32_t n; } fx_ctab;

typedef struct {
    fx_ins *ins;
    uint32_t nins;
    double *immed;                    /* literal table (components) */
    uint32_t nimmed;
    fx_ctab inputs;                   /* CTAB of the preshader: effect parameters -> c registers */
    uint32_t temps, consts, outs;     /* register table sizes in components */
} fx_preshader;

/* ------------------------------------------------------------- effects */
struct fx_state;
typedef struct { struct fx_state *states; uint32_t n; } fx_sampler;

typedef struct fx_param {
    char *name, *semantic;
    uint32_t type, klass, rows, cols, elements, nmembers, flags, bytes;
    struct fx_param *members;         /* elements or struct members */
    struct fx_param *annotations;
    uint32_t nannotations;
    uint8_t *data;                    /* numeric value / object slot (points into the top-level buffer) */
    uint32_t object_id;
    fx_sampler *sampler;
    struct fx_param *top;             /* top-level parameter this belongs to */
    uint32_t handle;                  /* guest D3DXHANDLE */
    uint64_t version;                 /* bumped on every change of the top-level parameter */
} fx_param;

enum { ST_CONSTANT, ST_PARAMETER, ST_FXLC, ST_ARRAY_SELECTOR };
typedef struct fx_state {
    uint32_t op, index, kind;
    fx_param value;                   /* typed constant value */
    fx_param *ref;                    /* ST_PARAMETER / ST_ARRAY_SELECTOR target */
    fx_preshader *expr;               /* ST_FXLC / array selector index */
} fx_state;

typedef struct { char *name; fx_param *annotations; uint32_t nannotations; fx_state *states; uint32_t nstates; uint32_t handle; } fx_pass;
typedef struct { char *name; fx_param *annotations; uint32_t nannotations; fx_pass *passes; uint32_t npasses; uint32_t handle; } fx_technique;

typedef struct { uint8_t *data; uint32_t size; } fx_object;

/* compiled shader carried by an effect */
typedef struct {
    uint32_t *code; uint32_t words;
    bool pixel;
    fx_ctab ctab;
    fx_preshader *pres;               /* optional PRES block */
    uint32_t device_shader;           /* runtime object (IDirect3D*Shader9 guest pointer), set by the COM layer */
} fx_shader;

typedef struct {
    fx_param *params; uint32_t nparams;
    fx_technique *techniques; uint32_t ntechniques;
    fx_object *objects; uint32_t nobjects;
    fx_shader **shaders;              /* per object id, for shader objects */
} fx_effect;

/* state table entry class */
enum { SC_RENDERSTATE, SC_TEXTURESTAGE, SC_NPATCHMODE, SC_FVF, SC_TRANSFORM, SC_MATERIAL, SC_LIGHT, SC_LIGHTENABLE,
       SC_VERTEXSHADER, SC_PIXELSHADER, SC_SHADERCONST, SC_TEXTURE, SC_SAMPLERSTATE, SC_SETSAMPLER };
typedef struct { uint8_t klass; uint16_t code; const char *name; } fx_state_info;
extern const fx_state_info fx_state_table[];
extern const uint32_t fx_state_count;

fx_effect *fx_parse(const uint8_t *blob, uint32_t size, char *err, uint32_t errlen);
void fx_free(fx_effect *e);
fx_param *fx_find_param(fx_effect *e, const char *name);   /* "a.b[2]" style names */

bool fx_parse_ctab(const uint32_t *code, uint32_t words, fx_ctab *out);
fx_preshader *fx_parse_preshader(const uint32_t *p, uint32_t words, fx_effect *e, char *err, uint32_t errlen);
/* evaluate with inputs = the preshader's c registers (pr->consts components); outputs: float oc
   components (nf), int oi registers (64 components), bool ob registers (16) */
bool fx_run_preshader_regs(const fx_preshader *pr, const float *inputs, float *outf, uint32_t nf, int32_t *outi, uint32_t *outb);

#endif
