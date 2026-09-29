/* d3dx9_27.dll effect framework: D3DXCreateEffect(Pool), ID3DXEffect, ID3DXEffectPool.
 * Parameters live host-side (gp_fx.c); the device is driven through gp_dev_* directly. */
#import <Metal/Metal.h>
#include "gp_d3d9_state.h"
#include "gp_fx.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define D3DXERR_INVALIDDATA 0x88760b59u
#define E_OUTOFMEMORY 0x8007000eu
#define E_FAIL 0x80004005u
#define SHARED_FLAG 1

void gp_fx_pack(const fx_param *p, const fx_ctab_const *c, float *regs);

/* ------------------------------------------------------------- pools */
typedef struct { char *name; uint32_t bytes; uint8_t *data; } shared_value;
typedef struct { shared_value *v; uint32_t n; } fx_pool;
#define MAX_POOLS 64
static fx_pool pools[MAX_POOLS];
static uint32_t npools;

/* ------------------------------------------------------------- instances */
typedef struct { uint8_t kind; uint32_t a, b, v; } saved_state;   /* 0 rs, 1 tss, 2 ss, 3 tex, 4 vs, 5 ps */
typedef struct {
    fx_effect *fx;
    gaddr obj, device;
    int pool;                         /* -1: none */
    fx_technique *tech;
    fx_pass *pass;
    bool begun;
    uint32_t begin_flags;
    saved_state *saved; uint32_t nsaved, capsaved;
    fx_shader *cur_vs, *cur_ps;
    gaddr *shader_objs;               /* per object id: device shader object */
    char **gstrings;                  /* guest copies of string objects */
    gaddr *gcode;                     /* guest copies of shader bytecode (GetPassDesc) */
    gaddr pool_obj;
} fx_inst;
#define MAX_EFFECTS 1024
static fx_inst *effects[MAX_EFFECTS];

/* ------------------------------------------------------------- handles
   D3DXHANDLEs are addresses in a reserved guest range that no guest data uses;
   anything else passed as a handle is a parameter name string. */
enum { H_PARAM = 1, H_TECH, H_PASS, H_FUNC };
typedef struct { uint8_t kind; fx_inst *e; void *p; } hentry;
static hentry *htab;
static uint32_t nh, caph;
static gaddr hbase;
#define HSPAN 0x01000000u

static uint32_t new_handle(uint8_t kind, fx_inst *e, void *p)
{
    if (!hbase) { hbase = gp_vm_reserve(0, HSPAN); if (!hbase) gp_fatal("no guest range for D3DX handles"); }
    if (nh == caph) { caph = caph ? caph * 2 : 4096; htab = realloc(htab, caph * sizeof *htab); }
    if ((uint64_t)nh * 4 >= HSPAN) gp_fatal("D3DX handle space exhausted");
    htab[nh] = (hentry){ kind, e, p };
    return hbase + 4 * nh++;
}
static hentry *handle(uint32_t h)
{
    if (!hbase || h < hbase || h >= hbase + HSPAN || (h - hbase) % 4 || (h - hbase) / 4 >= nh) return NULL;
    return &htab[(h - hbase) / 4];
}

static void assign_param_handles(fx_inst *e, fx_param *p)
{
    p->handle = new_handle(H_PARAM, e, p);
    uint32_t n = p->elements ? p->elements : p->nmembers;
    for (uint32_t i = 0; i < n; i++) assign_param_handles(e, &p->members[i]);
    for (uint32_t i = 0; i < p->nannotations; i++) assign_param_handles(e, &p->annotations[i]);
}

static fx_param *param_of(fx_inst *e, uint32_t h)
{
    if (!h) return NULL;
    hentry *x = handle(h);
    if (x) return x->kind == H_PARAM ? x->p : NULL;
    return fx_find_param(e->fx, gstr(h));
}
static fx_technique *tech_of(fx_inst *e, uint32_t h)
{
    hentry *x = handle(h);
    if (x) return x->kind == H_TECH ? x->p : NULL;
    if (!h) return NULL;
    for (uint32_t i = 0; i < e->fx->ntechniques; i++)
        if (e->fx->techniques[i].name && !strcmp(e->fx->techniques[i].name, gstr(h))) return &e->fx->techniques[i];
    return NULL;
}
static fx_pass *pass_of(fx_inst *e, uint32_t h)
{
    hentry *x = handle(h);
    return x && x->kind == H_PASS && x->e == e ? x->p : NULL;
}

static fx_inst *inst(gaddr obj) { uint32_t i = rd32(obj + 8); if (i >= MAX_EFFECTS || !effects[i]) gp_fatal("invalid ID3DXEffect 0x%08x", obj); return effects[i]; }
#define E inst(A(0))

/* ------------------------------------------------------------- values */
static void touch(fx_param *p) { if (p->top) p->top->version++; }

static float getf(const fx_param *p, uint32_t i)
{
    const uint8_t *d = p->data + 4 * i;
    if (p->type == PT_FLOAT) { float f; memcpy(&f, d, 4); return f; }
    int32_t v; memcpy(&v, d, 4);
    return p->type == PT_BOOL ? (v != 0) : (float)v;
}
static void setf(fx_param *p, uint32_t i, float f)
{
    uint8_t *d = p->data + 4 * i;
    if (p->type == PT_FLOAT) memcpy(d, &f, 4);
    else { int32_t v = p->type == PT_BOOL ? (f != 0.0f) : (int32_t)lrintf(f); memcpy(d, &v, 4); }
}
static void seti(fx_param *p, uint32_t i, int32_t v)
{
    uint8_t *d = p->data + 4 * i;
    if (p->type == PT_FLOAT) { float f = (float)v; memcpy(d, &f, 4); }
    else { int32_t w = p->type == PT_BOOL ? (v != 0) : v; memcpy(d, &w, 4); }
}
static int32_t geti(const fx_param *p, uint32_t i)
{
    const uint8_t *d = p->data + 4 * i;
    if (p->type == PT_FLOAT) { float f; memcpy(&f, d, 4); return (int32_t)f; }
    int32_t v; memcpy(&v, d, 4);
    return p->type == PT_BOOL ? (v != 0) : v;
}
static bool numeric(const fx_param *p) { return p->klass <= PC_MATRIX_COLUMNS; }
static uint32_t ncomp(const fx_param *p) { return p->rows * p->cols; }

/* matrix element (r,c) index in a parameter's storage */
static uint32_t mindex(const fx_param *p, uint32_t r, uint32_t c) { return p->klass == PC_MATRIX_COLUMNS ? c * p->rows + r : r * p->cols + c; }

/* ------------------------------------------------------------- creation */
static const char *const effect_methods[] = { "QueryInterface", "AddRef", "Release", "GetDesc", "GetParameterDesc",
    "GetTechniqueDesc", "GetPassDesc", "GetFunctionDesc", "GetParameter", "GetParameterByName", "GetParameterBySemantic",
    "GetParameterElement", "GetTechnique", "GetTechniqueByName", "GetPass", "GetPassByName", "GetFunction",
    "GetFunctionByName", "GetAnnotation", "GetAnnotationByName", "SetValue", "GetValue", "SetBool", "GetBool",
    "SetBoolArray", "GetBoolArray", "SetInt", "GetInt", "SetIntArray", "GetIntArray", "SetFloat", "GetFloat",
    "SetFloatArray", "GetFloatArray", "SetVector", "GetVector", "SetVectorArray", "GetVectorArray", "SetMatrix",
    "GetMatrix", "SetMatrixArray", "GetMatrixArray", "SetMatrixPointerArray", "GetMatrixPointerArray",
    "SetMatrixTranspose", "GetMatrixTranspose", "SetMatrixTransposeArray", "GetMatrixTransposeArray",
    "SetMatrixTransposePointerArray", "GetMatrixTransposePointerArray", "SetString", "GetString", "SetTexture",
    "GetTexture", "GetPixelShader", "GetVertexShader", "SetArrayRange", "GetPool", "SetTechnique",
    "GetCurrentTechnique", "ValidateTechnique", "FindNextValidTechnique", "IsParameterUsed", "Begin", "BeginPass",
    "CommitChanges", "EndPass", "End", "GetDevice", "OnLostDevice", "OnResetDevice", "SetStateManager",
    "GetStateManager", "BeginParameterBlock", "EndParameterBlock", "ApplyParameterBlock", "DeleteParameterBlock",
    "CloneEffect", "SetRawValue" };
static const char *const pool_methods[] = { "QueryInterface", "AddRef", "Release" };
static gaddr effect_vt, pool_vt;

static uint32_t D3DXCreateEffectPool_(gp_thread *t)
{
    if (!pool_vt) pool_vt = gp_com_vtable("ID3DXEffectPool", pool_methods, 3);
    if (npools == MAX_POOLS) gp_fatal("too many effect pools");
    gaddr o = gp_com_new(pool_vt, 4);
    wr32(o + 8, npools++);
    wr32(A(0), o);
    return D3D_OK;
}

/* rebase a parameter tree's data pointers onto new storage */
static void rebase(fx_param *p, uint8_t *old, uint8_t *new)
{
    if (p->data) p->data = new + (p->data - old);
    uint32_t n = p->elements ? p->elements : p->nmembers;
    for (uint32_t i = 0; i < n; i++) rebase(&p->members[i], old, new);
}

static void attach_shared(fx_inst *e)
{
    fx_pool *pl = &pools[e->pool];
    for (uint32_t i = 0; i < e->fx->nparams; i++) {
        fx_param *p = &e->fx->params[i];
        if (!(p->flags & SHARED_FLAG) || !p->bytes) continue;
        shared_value *sv = NULL;
        for (uint32_t k = 0; k < pl->n; k++) if (!strcmp(pl->v[k].name, p->name)) sv = &pl->v[k];
        if (!sv) {
            /* the pool owns the shared storage (effects come and go); the first effect's value seeds it */
            shared_value *grown = realloc(pl->v, sizeof *pl->v * (pl->n + 1));
            uint8_t *store = malloc(p->bytes);
            char *name = strdup(p->name);
            if (!grown || !store || !name) gp_fatal("out of memory for shared effect parameters");
            pl->v = grown;
            memcpy(store, p->data, p->bytes);
            sv = &pl->v[pl->n++];
            *sv = (shared_value){ name, p->bytes, store };
        }
        if (sv->bytes != p->bytes) gp_fatal("shared effect parameter %s has two sizes", p->name);
        uint8_t *old = p->data;
        rebase(p, old, sv->data);
        free(old);                                                       /* initial value comes from the pool */
    }
}

static uint32_t create_effect(gp_thread *t, gaddr device, const uint8_t *data, uint32_t len, gaddr pool_obj, gaddr out, gaddr errors)
{
    char err[512] = "";
    fx_effect *fx = fx_parse(data, len, err, sizeof err);
    if (errors) wr32(errors, 0);
    if (!fx) { gp_log("D3DXCreateEffect: %s", err); return D3DXERR_INVALIDDATA; }
    if (getenv("GP_TRACE_FX")) {
        gp_log("effect: %u parameters, %u techniques", fx->nparams, fx->ntechniques);
        for (uint32_t i = 0; i < fx->ntechniques; i++) {
            fx_technique *tq = &fx->techniques[i];
            for (uint32_t j = 0; j < tq->npasses; j++)
                for (uint32_t k = 0; k < tq->passes[j].nstates; k++) {
                    fx_state *st = &tq->passes[j].states[k];
                    gp_log("  %s/%u: %s[%u] kind %u ref %s", tq->name ? tq->name : "", j, fx_state_table[st->op].name, st->index, st->kind,
                           st->ref ? st->ref->name : "-");
                }
        }
        for (uint32_t i = 0; i < fx->nparams; i++) {
            fx_param *p = &fx->params[i];
            gp_log("  param %s type %u", p->name, p->type);
            if (p->sampler)
                for (uint32_t k = 0; k < p->sampler->n; k++)
                    gp_log("    sampler state %s kind %u ref %s", fx_state_table[p->sampler->states[k].op].name, p->sampler->states[k].kind,
                           p->sampler->states[k].ref ? p->sampler->states[k].ref->name : "-");
        }
    }
    uint32_t idx = 0;
    while (idx < MAX_EFFECTS && effects[idx]) idx++;
    if (idx == MAX_EFFECTS) gp_fatal("too many effects");
    fx_inst *e = calloc(1, sizeof *e);
    e->fx = fx;
    e->device = device;
    e->pool = pool_obj ? (int)rd32(pool_obj + 8) : -1;
    e->shader_objs = calloc(fx->nobjects ? fx->nobjects : 1, sizeof *e->shader_objs);
    e->gstrings = calloc(fx->nobjects ? fx->nobjects : 1, sizeof *e->gstrings);
    e->gcode = calloc(fx->nobjects ? fx->nobjects : 1, sizeof *e->gcode);
    e->pool_obj = pool_obj;
    if (pool_obj) wr32(pool_obj + 4, rd32(pool_obj + 4) + 1);
    effects[idx] = e;
    if (e->pool >= 0) attach_shared(e);
    for (uint32_t i = 0; i < fx->nparams; i++) assign_param_handles(e, &fx->params[i]);
    for (uint32_t i = 0; i < fx->ntechniques; i++) {
        fx_technique *tq = &fx->techniques[i];
        tq->handle = new_handle(H_TECH, e, tq);
        for (uint32_t a = 0; a < tq->nannotations; a++) assign_param_handles(e, &tq->annotations[a]);
        for (uint32_t k = 0; k < tq->npasses; k++) {
            tq->passes[k].handle = new_handle(H_PASS, e, &tq->passes[k]);
            for (uint32_t a = 0; a < tq->passes[k].nannotations; a++) assign_param_handles(e, &tq->passes[k].annotations[a]);
        }
    }
    /* device shaders for every shader object; bind CTAB constants to parameters */
    for (uint32_t i = 0; i < fx->nobjects; i++) {
        fx_shader *sh = fx->shaders[i];
        if (!sh) continue;
        e->shader_objs[i] = gp_dev_create_shader(sh->pixel, sh->code, sh->words);
        if (!e->shader_objs[i]) gp_fatal("effect shader object %u was rejected", i);
        for (uint32_t k = 0; k < sh->ctab.n; k++) sh->ctab.c[k].param = fx_find_param(fx, sh->ctab.c[k].name);
        if (sh->pres) for (uint32_t k = 0; k < sh->pres->inputs.n; k++) sh->pres->inputs.c[k].param = fx_find_param(fx, sh->pres->inputs.c[k].name);
    }
    e->tech = fx->ntechniques ? &fx->techniques[0] : NULL;
    if (!effect_vt) effect_vt = gp_com_vtable("ID3DXEffect", effect_methods, sizeof effect_methods / sizeof *effect_methods);
    e->obj = gp_com_new(effect_vt, 4);
    wr32(e->obj + 8, idx);
    gp_d3d9_addref(device);
    wr32(out, e->obj);
    (void)t;
    return D3D_OK;
}

static uint32_t D3DXCreateEffect_(gp_thread *t)
{
    /* (device, pSrcData, SrcDataLen, pDefines, pInclude, Flags, pPool, ppEffect, ppCompilationErrors) */
    if (!A(0) || !A(1) || !A(7)) return D3DERR_INVALIDCALL;
    return create_effect(t, A(0), G(A(1)), A(2), A(6), A(7), A(8));
}

/* ------------------------------------------------------------- descriptions */
static gaddr gname(const char *s)
{
    /* guest copies of names, interned by content (host name storage is freed and reused with the effects) */
    static struct { char *host; gaddr g; } *cache;
    static uint32_t n, cap;
    if (!s) return 0;
    for (uint32_t i = 0; i < n; i++) if (!strcmp(cache[i].host, s)) return cache[i].g;
    if (n == cap) {
        void *grown = realloc(cache, (cap ? cap * 2 : 1024) * sizeof *cache);
        if (!grown) gp_fatal("out of memory for effect names");
        cache = grown; cap = cap ? cap * 2 : 1024;
    }
    char *copy = strdup(s);
    if (!copy) gp_fatal("out of memory for effect names");
    cache[n].host = copy; cache[n].g = gp_strdup_guest(s);
    return cache[n++].g;
}

static uint32_t GetDesc_(gp_thread *t)
{
    fx_inst *e = E;
    gaddr d = A(1);
    uint32_t nfunc = 0;
    wr32(d, gname("FEAR effect")); wr32(d + 4, e->fx->nparams); wr32(d + 8, e->fx->ntechniques); wr32(d + 12, nfunc);
    return D3D_OK;
}
static uint32_t GetParameterDesc_(gp_thread *t)
{
    fx_param *p = param_of(E, A(1));
    if (!p || !A(2)) return D3DERR_INVALIDCALL;
    gaddr d = A(2);
    wr32(d, gname(p->name)); wr32(d + 4, gname(p->semantic)); wr32(d + 8, p->klass); wr32(d + 12, p->type);
    wr32(d + 16, p->rows); wr32(d + 20, p->cols); wr32(d + 24, p->elements); wr32(d + 28, p->nannotations);
    wr32(d + 32, p->elements ? 0 : p->nmembers); wr32(d + 36, p->flags); wr32(d + 40, p->bytes);
    return D3D_OK;
}
static uint32_t GetTechniqueDesc_(gp_thread *t)
{
    fx_technique *tq = tech_of(E, A(1));
    if (!tq || !A(2)) return D3DERR_INVALIDCALL;
    wr32(A(2), gname(tq->name)); wr32(A(2) + 4, tq->npasses); wr32(A(2) + 8, tq->nannotations);
    return D3D_OK;
}
static uint32_t GetPassDesc_(gp_thread *t)
{
    fx_pass *ps = pass_of(E, A(1));
    if (!ps || !A(2)) return D3DERR_INVALIDCALL;
    gaddr d = A(2);
    wr32(d, gname(ps->name)); wr32(d + 4, ps->nannotations);
    uint32_t vs = 0, psh = 0;
    fx_inst *e = E;
    for (uint32_t i = 0; i < ps->nstates; i++) {
        fx_state *s = &ps->states[i];
        uint8_t k = fx_state_table[s->op].klass;
        if ((k == SC_VERTEXSHADER || k == SC_PIXELSHADER) && s->kind == ST_CONSTANT) {
            uint32_t id = s->value.object_id;
            fx_shader *sh = e->fx->shaders[id];
            if (sh) {
                if (!e->gcode[id]) { e->gcode[id] = gp_heap_alloc(4 * sh->words, false); memcpy(G(e->gcode[id]), sh->code, 4 * sh->words); }
                if (k == SC_VERTEXSHADER) vs = e->gcode[id]; else psh = e->gcode[id];
            }
        }
    }
    wr32(d + 8, vs); wr32(d + 12, psh);
    return D3D_OK;
}

static uint32_t GetParameter__impl(gp_thread *t);
static uint32_t GetParameter_(gp_thread *t)
{
    uint32_t h = GetParameter__impl(t);
    static int tr = -1;
    if (tr < 0) tr = getenv("GP_TRACE_FXH") != NULL;
    if (tr) { fx_param *p = param_of(E, h); gp_log("fxh GetParameter(0x%08x, 0x%08x) on effect %u -> 0x%08x %s from 0x%08x", A(1), A(2), rd32(A(0) + 8), h, p && p->name ? p->name : "-", rd32(t->cpu._esp)); }
    return h;
}
static uint32_t GetParameter__impl(gp_thread *t)
{
    fx_inst *e = E;
    uint32_t parent = A(1), i = A(2);
    if (!parent) return i < e->fx->nparams ? e->fx->params[i].handle : 0;
    fx_param *p = param_of(e, parent);
    if (!p) return 0;
    uint32_t n = p->elements ? 0 : p->nmembers;                  /* elements are reached by GetParameterElement */
    return i < n ? p->members[i].handle : 0;
}
static uint32_t GetParameterByName__impl(gp_thread *t);
static uint32_t GetParameterByName_(gp_thread *t)
{
    uint32_t h = GetParameterByName__impl(t);
    static int tr = -1;
    if (tr < 0) tr = getenv("GP_TRACE_FXH") != NULL;
    if (tr) { fx_param *p = param_of(E, h); gp_log("fxh GetParameterByName(0x%08x, 0x%08x) on effect %u -> 0x%08x %s from 0x%08x", A(1), A(2), rd32(A(0) + 8), h, p && p->name ? p->name : "-", rd32(t->cpu._esp)); }
    return h;
}
static uint32_t GetParameterByName__impl(gp_thread *t)
{
    fx_inst *e = E;
    const char *name = gstr(A(2));
    if (!name) return 0;
    fx_param *p;
    if (!A(1)) p = fx_find_param(e->fx, name);
    else {
        fx_param *parent = param_of(e, A(1));
        if (!parent || parent->klass != PC_STRUCT) return 0;
        char full[512];
        snprintf(full, sizeof full, "%s.%s", parent->name, name);
        p = NULL;
        for (uint32_t k = 0; k < parent->nmembers; k++) if (parent->members[k].name && !strcmp(parent->members[k].name, name)) p = &parent->members[k];
    }
    return p ? p->handle : 0;
}
static uint32_t GetParameterBySemantic__impl(gp_thread *t);
static uint32_t GetParameterBySemantic_(gp_thread *t)
{
    uint32_t h = GetParameterBySemantic__impl(t);
    static int tr = -1;
    if (tr < 0) tr = getenv("GP_TRACE_FXH") != NULL;
    if (tr) { fx_param *p = param_of(E, h); gp_log("fxh GetParameterBySemantic(0x%08x, 0x%08x) on effect %u -> 0x%08x %s from 0x%08x", A(1), A(2), rd32(A(0) + 8), h, p && p->name ? p->name : "-", rd32(t->cpu._esp)); }
    return h;
}
static uint32_t GetParameterBySemantic__impl(gp_thread *t)
{
    fx_inst *e = E;
    const char *sem = gstr(A(2));
    if (!sem) return 0;
    fx_param *list = e->fx->params; uint32_t n = e->fx->nparams;
    if (A(1)) { fx_param *parent = param_of(e, A(1)); if (!parent) return 0; list = parent->members; n = parent->elements ? 0 : parent->nmembers; }
    for (uint32_t i = 0; i < n; i++) if (list[i].semantic && !strcasecmp(list[i].semantic, sem)) return list[i].handle;
    return 0;
}
static uint32_t GetParameterElement__impl(gp_thread *t);
static uint32_t GetParameterElement_(gp_thread *t)
{
    uint32_t h = GetParameterElement__impl(t);
    static int tr = -1;
    if (tr < 0) tr = getenv("GP_TRACE_FXH") != NULL;
    if (tr) { fx_param *p = param_of(E, h); gp_log("fxh GetParameterElement(0x%08x, 0x%08x) on effect %u -> 0x%08x %s from 0x%08x", A(1), A(2), rd32(A(0) + 8), h, p && p->name ? p->name : "-", rd32(t->cpu._esp)); }
    return h;
}
static uint32_t GetParameterElement__impl(gp_thread *t)
{
    fx_param *p = param_of(E, A(1));
    return p && A(2) < p->elements ? p->members[A(2)].handle : 0;
}
static uint32_t GetTechnique_(gp_thread *t) { fx_inst *e = E; return A(1) < e->fx->ntechniques ? e->fx->techniques[A(1)].handle : 0; }
static uint32_t GetTechniqueByName_(gp_thread *t) { fx_technique *tq = tech_of(E, A(1)); return tq ? tq->handle : 0; }
static uint32_t GetPass_(gp_thread *t) { fx_technique *tq = tech_of(E, A(1)); return tq && A(2) < tq->npasses ? tq->passes[A(2)].handle : 0; }
static uint32_t GetPassByName_(gp_thread *t)
{
    fx_technique *tq = tech_of(E, A(1));
    if (!tq || !A(2)) return 0;
    for (uint32_t i = 0; i < tq->npasses; i++) if (tq->passes[i].name && !strcmp(tq->passes[i].name, gstr(A(2)))) return tq->passes[i].handle;
    return 0;
}
static bool annotations_of(fx_inst *e, uint32_t h, fx_param **list, uint32_t *n)
{
    hentry *x = handle(h);
    if (!x) { fx_param *p = param_of(e, h); if (!p) return false; *list = p->annotations; *n = p->nannotations; return true; }
    if (x->kind == H_PARAM) { fx_param *p = x->p; *list = p->annotations; *n = p->nannotations; return true; }
    if (x->kind == H_TECH) { fx_technique *q = x->p; *list = q->annotations; *n = q->nannotations; return true; }
    if (x->kind == H_PASS) { fx_pass *q = x->p; *list = q->annotations; *n = q->nannotations; return true; }
    return false;
}
static uint32_t GetAnnotation_(gp_thread *t)
{
    fx_param *l; uint32_t n;
    if (!annotations_of(E, A(1), &l, &n) || A(2) >= n) return 0;
    return l[A(2)].handle;
}
static uint32_t GetAnnotationByName_(gp_thread *t)
{
    fx_param *l; uint32_t n;
    if (!A(2) || !annotations_of(E, A(1), &l, &n)) return 0;
    for (uint32_t i = 0; i < n; i++) if (l[i].name && !strcmp(l[i].name, gstr(A(2)))) return l[i].handle;
    return 0;
}

/* ------------------------------------------------------------- set/get */
static void set_object(fx_param *p, uint32_t value)
{
    uint32_t old; memcpy(&old, p->data, 4);
    if (fx_is_texture(p->type) && value && (value < 0x10000 || !gp_res_at(rd32(value + 8)) || gp_res_at(rd32(value + 8))->obj != value))
        gp_fatal("effect parameter %s: 0x%08x is not a texture (caller 0x%08x)", p->name, value, rd32(gp_current()->cpu._esp));
    if (fx_is_texture(p->type)) { if (value) gp_d3d9_addref(value); if (old) gp_d3d9_release(old); }
    memcpy(p->data, &value, 4);
    touch(p);
}

static uint32_t SetValue_(gp_thread *t)
{
    fx_param *p = param_of(E, A(1));
    if (!p || !A(2)) return D3DERR_INVALIDCALL;
    uint32_t n = A(3);
    extern volatile bool gp_trace_frame_active;
    if (gp_trace_frame_active || getenv("GP_TRACE_FXH")) gp_log("  SetValue e%u %s klass %u type %u bytes %u(param %u) first 0x%08x from 0x%08x", rd32(A(0) + 8), p->name, p->klass, p->type, n, p->bytes, n >= 4 ? rd32(A(2)) : 0, rd32(t->cpu._esp));
    if (p->klass == PC_OBJECT) {
        if (p->elements) gp_fatal("SetValue on an object array parameter %s", p->name);
        if (fx_is_texture(p->type) && n >= 4) {
            uint32_t v = rd32(A(2));
            if (v && (v < 0x10000 || !gp_res_at(rd32(v + 8)) || gp_res_at(rd32(v + 8))->obj != v))
                gp_fatal("SetValue(handle 0x%08x -> %s, pData 0x%08x -> 0x%08x, %u) from 0x%08x: not a texture; words at pData: %08x %08x %08x %08x %08x %08x",
                         A(1), p->name, A(2), v, n, rd32(t->cpu._esp), rd32(A(2) - 8), rd32(A(2) - 4), rd32(A(2)), rd32(A(2) + 4), rd32(A(2) + 8), rd32(A(2) + 12));
            set_object(p, v);
            return D3D_OK;
        }
        return D3DERR_INVALIDCALL;
    }
    if (n > p->bytes) n = p->bytes;
    memcpy(p->data, G(A(2)), n);
    touch(p);
    return D3D_OK;
}
static uint32_t GetValue_(gp_thread *t)
{
    fx_param *p = param_of(E, A(1));
    if (!p || !A(2)) return D3DERR_INVALIDCALL;
    uint32_t n = A(3) < p->bytes ? A(3) : p->bytes;
    if (p->klass == PC_OBJECT && fx_is_texture(p->type)) { uint32_t v; memcpy(&v, p->data, 4); if (v) gp_d3d9_addref(v); }
    if (p->bytes) memcpy(G(A(2)), p->data, n);
    return D3D_OK;
}
static uint32_t SetBool_(gp_thread *t) { fx_param *p = param_of(E, A(1)); if (!p || !numeric(p) || p->elements) return D3DERR_INVALIDCALL; seti(p, 0, A(2) != 0); touch(p); return D3D_OK; }
static uint32_t GetBool_(gp_thread *t) { fx_param *p = param_of(E, A(1)); if (!p || !numeric(p)) return D3DERR_INVALIDCALL; wr32(A(2), geti(p, 0) != 0); return D3D_OK; }
static uint32_t SetInt_(gp_thread *t) { fx_param *p = param_of(E, A(1)); if (!p || !numeric(p) || p->elements) return D3DERR_INVALIDCALL; seti(p, 0, (int32_t)A(2)); touch(p); return D3D_OK; }
static uint32_t GetInt_(gp_thread *t) { fx_param *p = param_of(E, A(1)); if (!p || !numeric(p)) return D3DERR_INVALIDCALL; wr32(A(2), (uint32_t)geti(p, 0)); return D3D_OK; }
static uint32_t SetFloat_(gp_thread *t)
{
    fx_param *p = param_of(E, A(1));
    if (!p || !numeric(p) || p->elements) return D3DERR_INVALIDCALL;
    float f; uint32_t b = A(2); memcpy(&f, &b, 4);
    setf(p, 0, f); touch(p);
    return D3D_OK;
}
static uint32_t GetFloat_(gp_thread *t) { fx_param *p = param_of(E, A(1)); if (!p || !numeric(p)) return D3DERR_INVALIDCALL; float f = getf(p, 0); memcpy(G(A(2)), &f, 4); return D3D_OK; }

/* flat arrays across elements of a numeric parameter */
static fx_param *leaf(fx_param *p, uint32_t *i, uint32_t *comp)
{
    if (!p->elements) return p;
    uint32_t per = ncomp(&p->members[0]);
    uint32_t e = *i / per;
    if (e >= p->elements) return NULL;
    *comp = *i % per;
    return &p->members[e];
}
static uint32_t set_array(gp_thread *t, int kind)
{
    fx_param *p = param_of(E, A(1));
    if (!p || (!numeric(p) && !(p->elements && numeric(&p->members[0])))) return D3DERR_INVALIDCALL;
    for (uint32_t i = 0; i < A(3); i++) {
        uint32_t c = i;
        fx_param *l = leaf(p, &i, &c);
        uint32_t idx = p->elements ? c : i;
        if (!l || idx >= ncomp(l)) break;
        uint32_t v = rd32(A(2) + 4 * i);
        if (kind == 2) { float f; memcpy(&f, &v, 4); setf(l, idx, f); } else seti(l, idx, kind == 0 ? (v != 0) : (int32_t)v);
    }
    touch(p);
    return D3D_OK;
}
static uint32_t get_array(gp_thread *t, int kind)
{
    fx_param *p = param_of(E, A(1));
    if (!p || (!numeric(p) && !(p->elements && numeric(&p->members[0])))) return D3DERR_INVALIDCALL;
    for (uint32_t i = 0; i < A(3); i++) {
        uint32_t c = i;
        fx_param *l = leaf(p, &i, &c);
        uint32_t idx = p->elements ? c : i;
        if (!l || idx >= ncomp(l)) break;
        if (kind == 2) { float f = getf(l, idx); memcpy(G(A(2) + 4 * i), &f, 4); }
        else wr32(A(2) + 4 * i, (uint32_t)(kind == 0 ? geti(l, idx) != 0 : geti(l, idx)));
    }
    return D3D_OK;
}
static uint32_t SetBoolArray_(gp_thread *t) { return set_array(t, 0); }
static uint32_t GetBoolArray_(gp_thread *t) { return get_array(t, 0); }
static uint32_t SetIntArray_(gp_thread *t) { return set_array(t, 1); }
static uint32_t GetIntArray_(gp_thread *t) { return get_array(t, 1); }
static uint32_t SetFloatArray_(gp_thread *t) { return set_array(t, 2); }
static uint32_t GetFloatArray_(gp_thread *t) { return get_array(t, 2); }

/* vectors: up to 4 components of the parameter's first row */
static void set_vector(fx_param *p, const float *v)
{
    uint32_t n = p->klass == PC_SCALAR ? 1 : p->cols;
    for (uint32_t i = 0; i < n && i < 4; i++) setf(p, i, v[i]);
}
static uint32_t SetVector_(gp_thread *t)
{
    fx_param *p = param_of(E, A(1));
    if (!p || (p->klass != PC_VECTOR && p->klass != PC_SCALAR) || p->elements) return D3DERR_INVALIDCALL;
    set_vector(p, G(A(2))); touch(p);
    return D3D_OK;
}
static uint32_t GetVector_(gp_thread *t)
{
    fx_param *p = param_of(E, A(1));
    if (!p || (p->klass != PC_VECTOR && p->klass != PC_SCALAR)) return D3DERR_INVALIDCALL;
    float v[4] = {0};
    uint32_t n = p->klass == PC_SCALAR ? 1 : p->cols;
    for (uint32_t i = 0; i < n && i < 4; i++) v[i] = getf(p, i);
    memcpy(G(A(2)), v, 16);
    return D3D_OK;
}
static uint32_t SetVectorArray_(gp_thread *t)
{
    fx_param *p = param_of(E, A(1));
    if (!p || !p->elements || p->members[0].klass != PC_VECTOR) return D3DERR_INVALIDCALL;
    for (uint32_t i = 0; i < A(3) && i < p->elements; i++) set_vector(&p->members[i], G(A(2) + 16 * i));
    touch(p);
    return D3D_OK;
}
static uint32_t GetVectorArray_(gp_thread *t)
{
    fx_param *p = param_of(E, A(1));
    if (!p || !p->elements || p->members[0].klass != PC_VECTOR) return D3DERR_INVALIDCALL;
    for (uint32_t i = 0; i < A(3) && i < p->elements; i++) {
        float v[4] = {0};
        for (uint32_t c = 0; c < p->members[i].cols && c < 4; c++) v[c] = getf(&p->members[i], c);
        memcpy(G(A(2) + 16 * i), v, 16);
    }
    return D3D_OK;
}

static void set_matrix(fx_param *p, const float *m, bool transpose)
{
    for (uint32_t r = 0; r < p->rows && r < 4; r++)
        for (uint32_t c = 0; c < p->cols && c < 4; c++)
            setf(p, mindex(p, r, c), transpose ? m[c * 4 + r] : m[r * 4 + c]);
}
static void get_matrix(fx_param *p, float *m, bool transpose)
{
    memset(m, 0, 64);
    for (uint32_t r = 0; r < p->rows && r < 4; r++)
        for (uint32_t c = 0; c < p->cols && c < 4; c++)
            m[transpose ? c * 4 + r : r * 4 + c] = getf(p, mindex(p, r, c));
}
static bool is_matrix(fx_param *p) { return p && (p->klass == PC_MATRIX_ROWS || p->klass == PC_MATRIX_COLUMNS); }

static uint32_t matrix_set(gp_thread *t, bool transpose, bool array, bool pointers)
{
    fx_param *p = param_of(E, A(1));
    if (!p) return D3DERR_INVALIDCALL;
    uint32_t n = array ? A(3) : 1;
    for (uint32_t i = 0; i < n; i++) {
        fx_param *l = array ? (i < p->elements ? &p->members[i] : NULL) : p;
        if (!is_matrix(l)) return array && i ? D3D_OK : D3DERR_INVALIDCALL;
        gaddr src = pointers ? rd32(A(2) + 4 * i) : A(2) + 64 * i;
        set_matrix(l, G(src), transpose);
    }
    touch(p);
    return D3D_OK;
}
static uint32_t matrix_get(gp_thread *t, bool transpose, bool array, bool pointers)
{
    fx_param *p = param_of(E, A(1));
    if (!p) return D3DERR_INVALIDCALL;
    uint32_t n = array ? A(3) : 1;
    for (uint32_t i = 0; i < n; i++) {
        fx_param *l = array ? (i < p->elements ? &p->members[i] : NULL) : p;
        if (!is_matrix(l)) return D3DERR_INVALIDCALL;
        gaddr dst = pointers ? rd32(A(2) + 4 * i) : A(2) + 64 * i;
        get_matrix(l, G(dst), transpose);
    }
    return D3D_OK;
}
static uint32_t SetMatrix_(gp_thread *t) { return matrix_set(t, false, false, false); }
static uint32_t GetMatrix_(gp_thread *t) { return matrix_get(t, false, false, false); }
static uint32_t SetMatrixArray_(gp_thread *t) { return matrix_set(t, false, true, false); }
static uint32_t GetMatrixArray_(gp_thread *t) { return matrix_get(t, false, true, false); }
static uint32_t SetMatrixPointerArray_(gp_thread *t) { return matrix_set(t, false, true, true); }
static uint32_t GetMatrixPointerArray_(gp_thread *t) { return matrix_get(t, false, true, true); }
static uint32_t SetMatrixTranspose_(gp_thread *t) { return matrix_set(t, true, false, false); }
static uint32_t GetMatrixTranspose_(gp_thread *t) { return matrix_get(t, true, false, false); }
static uint32_t SetMatrixTransposeArray_(gp_thread *t) { return matrix_set(t, true, true, false); }
static uint32_t GetMatrixTransposeArray_(gp_thread *t) { return matrix_get(t, true, true, false); }
static uint32_t SetMatrixTransposePointerArray_(gp_thread *t) { return matrix_set(t, true, true, true); }
static uint32_t GetMatrixTransposePointerArray_(gp_thread *t) { return matrix_get(t, true, true, true); }

static uint32_t GetString_(gp_thread *t)
{
    fx_inst *e = E;
    fx_param *p = param_of(e, A(1));
    if (!p || p->type != PT_STRING || !A(2)) return D3DERR_INVALIDCALL;
    uint32_t id = p->object_id;
    if (!e->gstrings[id]) {
        fx_object *o = &e->fx->objects[id];
        char *s = calloc(1, o->size + 1);
        if (o->data) memcpy(s, o->data, o->size);
        e->gstrings[id] = s;
    }
    wr32(A(2), gname(e->gstrings[id]));
    return D3D_OK;
}
static uint32_t SetTexture_(gp_thread *t)
{
    fx_param *p = param_of(E, A(1));
    if (!p || !fx_is_texture(p->type) || p->elements) return D3DERR_INVALIDCALL;
    set_object(p, A(2));
    return D3D_OK;
}
static uint32_t GetTexture_(gp_thread *t)
{
    fx_param *p = param_of(E, A(1));
    if (!p || !fx_is_texture(p->type)) return D3DERR_INVALIDCALL;
    uint32_t v; memcpy(&v, p->data, 4);
    if (v) gp_d3d9_addref(v);
    wr32(A(2), v);
    return D3D_OK;
}
static uint32_t SetRawValue_(gp_thread *t)
{
    fx_param *p = param_of(E, A(1));
    if (!p || !A(2) || A(3) + A(4) > p->bytes || p->klass == PC_OBJECT) return D3DERR_INVALIDCALL;
    memcpy(p->data + A(3), G(A(2)), A(4));
    touch(p);
    return D3D_OK;
}

/* ------------------------------------------------------------- techniques */
const char *gp_fx_last_technique = "";
static uint32_t SetTechnique_(gp_thread *t)
{
    fx_inst *e = E;
    fx_technique *tq = tech_of(e, A(1));
    if (!tq) return D3DERR_INVALIDCALL;
    e->tech = tq;
    gp_fx_last_technique = tq->name ? tq->name : "";
    extern volatile bool gp_trace_frame_active;
    if (gp_trace_frame_active) {
        gp_log("effect technique \"%s\"", tq->name ? tq->name : "");
        for (uint32_t i = 0; i < e->fx->nparams; i++) {
            fx_param *p = &e->fx->params[i];
            if (p->type >= 5 && p->type <= 9) gp_log("  param %s (texture) = 0x%08x", p->name, p->data ? *(uint32_t *)p->data : 0);
            else if (p->type == 3 && p->bytes >= 4) {
                const float *f = (const float *)p->data;
                gp_log("  param %s = %g %g %g %g", p->name, f[0], p->bytes > 4 ? f[1] : 0, p->bytes > 8 ? f[2] : 0, p->bytes > 12 ? f[3] : 0);
            }
        }
    }
    return D3D_OK;
}
static uint32_t GetCurrentTechnique_(gp_thread *t) { fx_inst *e = E; return e->tech ? e->tech->handle : 0; }
static uint32_t ValidateTechnique_(gp_thread *t) { return tech_of(E, A(1)) ? D3D_OK : D3DERR_INVALIDCALL; }
static uint32_t FindNextValidTechnique_(gp_thread *t)
{
    fx_inst *e = E;
    uint32_t start = 0;
    if (A(1)) {
        fx_technique *tq = tech_of(e, A(1));
        if (!tq) return D3DERR_INVALIDCALL;
        start = (uint32_t)(tq - e->fx->techniques) + 1;
    }
    wr32(A(2), start < e->fx->ntechniques ? e->fx->techniques[start].handle : 0);
    return start < e->fx->ntechniques ? D3D_OK : 1;               /* S_FALSE when none is left */
}
/* a parameter is used through a sampler when it is the sampler or one of the sampler's states refers to it */
static bool sampler_uses(const fx_param *sp, const fx_param *top)
{
    if (!sp) return false;
    if (sp->top == top) return true;
    if (!sp->sampler) return false;
    for (uint32_t i = 0; i < sp->sampler->n; i++) {
        const fx_state *st = &sp->sampler->states[i];
        if (st->ref && st->ref->top == top) return true;
    }
    return false;
}
static bool ctab_uses(const fx_ctab *ct, const fx_param *top)
{
    for (uint32_t c = 0; c < ct->n; c++) {
        const fx_ctab_const *k = &ct->c[c];
        if (!k->param) continue;
        if (k->param->top == top) return true;
        if (k->regset == RS_SAMPLER) {
            if (k->param->elements) { for (uint32_t i = 0; i < k->param->elements; i++) if (sampler_uses(&k->param->members[i], top)) return true; }
            else if (sampler_uses(k->param, top)) return true;
        }
    }
    return false;
}
static uint32_t IsParameterUsed_(gp_thread *t)
{
    fx_inst *e = E;
    fx_param *p = param_of(e, A(1));
    fx_technique *tq = tech_of(e, A(2));
    if (!p || !tq) return 0;
    fx_param *top = p->top;
    for (uint32_t k = 0; k < tq->npasses; k++)
        for (uint32_t s = 0; s < tq->passes[k].nstates; s++) {
            fx_state *st = &tq->passes[k].states[s];
            if (st->ref && st->ref->top == top) return 1;
            uint8_t cls = fx_state_table[st->op].klass;
            if (cls == SC_SETSAMPLER && st->ref && sampler_uses(st->ref, top)) return 1;
            if (cls == SC_VERTEXSHADER || cls == SC_PIXELSHADER) {
                const fx_param *v = st->kind == ST_CONSTANT ? &st->value : st->ref;
                if (!v || !fx_is_shader(v->type) || v->object_id >= e->fx->nobjects) continue;
                fx_shader *sh = e->fx->shaders[v->object_id];
                if (!sh) continue;
                if (ctab_uses(&sh->ctab, top)) return 1;
                if (sh->pres && ctab_uses(&sh->pres->inputs, top)) return 1;
            }
        }
    return 0;
}

/* ------------------------------------------------------------- applying passes */
static void save(fx_inst *e, uint8_t kind, uint32_t a, uint32_t b, uint32_t v)
{
    if (!e->begun || (e->begin_flags & 1)) return;                   /* D3DXFX_DONOTSAVESTATE */
    if ((kind == 4 || kind == 5) && (e->begin_flags & 2)) return;    /* DONOTSAVESHADERSTATE */
    if (kind == 2 && (e->begin_flags & 4)) return;                   /* DONOTSAVESAMPLERSTATE */
    for (uint32_t i = 0; i < e->nsaved; i++) if (e->saved[i].kind == kind && e->saved[i].a == a && e->saved[i].b == b) return;
    if (e->nsaved == e->capsaved) { e->capsaved = e->capsaved ? e->capsaved * 2 : 64; e->saved = realloc(e->saved, e->capsaved * sizeof *e->saved); }
    if (kind == 3 || kind == 4 || kind == 5) {                        /* objects: hold a reference while saved */
        if (v) gp_d3d9_addref(v);
    }
    e->saved[e->nsaved++] = (saved_state){ kind, a, b, v };
}

static uint32_t cur_texture_obj(uint32_t sampler)
{
    int slot = sampler < 16 ? (int)sampler : sampler == 256 ? 16 : (int)(sampler - 257 + 17);
    gp_res *r = gp_res_at(D.textures[slot]);
    return r ? r->obj : 0;
}
static uint32_t cur_shader_obj(bool pixel) { gp_res *r = gp_res_at(pixel ? D.ps : D.vs); return r ? r->obj : 0; }

static void set_rs(fx_inst *e, uint32_t s, uint32_t v) { save(e, 0, s, 0, D.rs[s]); gp_dev_set_rs(s, v); }
static void set_tss(fx_inst *e, uint32_t st, uint32_t ty, uint32_t v) { if (st < 8 && ty < 33) save(e, 1, st, ty, D.tss[st][ty]); gp_dev_set_tss(st, ty, v); }
static void set_ss(fx_inst *e, uint32_t sm, uint32_t ty, uint32_t v) { save(e, 2, sm, ty, gp_dev_get_ss(sm, ty)); gp_dev_set_ss(sm, ty, v); }
static void set_tex(fx_inst *e, uint32_t sm, uint32_t obj) { save(e, 3, sm, 0, cur_texture_obj(sm)); gp_dev_set_texture(sm, obj); }
static void set_shader(fx_inst *e, bool pixel, uint32_t obj) { save(e, pixel ? 5 : 4, 0, 0, cur_shader_obj(pixel)); gp_dev_set_shader(pixel, obj); }

/* evaluates a preshader whose inputs are effect parameters; outputs go to outf */
static void run_expr(const fx_preshader *pr, float *outf, uint32_t nf, int32_t *outi, uint32_t *outb)
{
    float *in = calloc(pr->consts ? pr->consts : 4, sizeof(float));
    for (uint32_t k = 0; k < pr->inputs.n; k++) {
        fx_ctab_const *c = &pr->inputs.c[k];
        if (!c->param || c->regset != RS_FLOAT4) continue;
        gp_fx_pack(c->param, c, in + 4 * c->reg);
    }
    if (!fx_run_preshader_regs(pr, in, outf, nf, outi, outb)) gp_fatal("preshader evaluation failed");
    free(in);
}

static uint32_t state_dword(fx_param *v)
{
    uint32_t d = 0;
    if (v->data && v->bytes >= 4) memcpy(&d, v->data, 4);
    return d;
}

/* the parameter holding a state's value after resolving references/expressions */
static fx_param *state_value(fx_inst *e, fx_state *s, fx_param *scratch, uint8_t *buf)
{
    switch (s->kind) {
    case ST_CONSTANT: return &s->value;
    case ST_PARAMETER: return s->ref;
    case ST_FXLC: {
        float out[16] = {0};
        run_expr(s->expr, out, 16, NULL, NULL);
        *scratch = s->value;
        scratch->data = buf;
        for (uint32_t i = 0; i < ncomp(&s->value) && i < 16; i++) setf(scratch, i, out[i]);
        return scratch;
    }
    case ST_ARRAY_SELECTOR: {
        float out[4] = {0};
        run_expr(s->expr, out, 4, NULL, NULL);
        uint32_t i = (uint32_t)lrintf(out[0]);
        if (!s->ref->elements || i >= s->ref->elements) gp_fatal("effect array selector index %u out of %u", i, s->ref->elements);
        return &s->ref->members[i];
    }
    }
    (void)e;
    return &s->value;
}

static void apply_sampler(fx_inst *e, fx_param *sp, uint32_t sampler)
{
    if (!sp || !sp->sampler) return;
    for (uint32_t i = 0; i < sp->sampler->n; i++) {
        fx_state *s = &sp->sampler->states[i];
        uint8_t buf[64]; fx_param scratch;
        fx_param *v = state_value(e, s, &scratch, buf);
        const fx_state_info *si = &fx_state_table[s->op];
        if (si->klass == SC_SAMPLERSTATE) set_ss(e, sampler, si->code, state_dword(v));
        else if (si->klass == SC_TEXTURE) {
            uint32_t obj = state_dword(v);
            if (obj && (obj < 0x10000 || !gp_res_at(rd32(obj + 8)) || gp_res_at(rd32(obj + 8))->obj != obj))
                gp_fatal("effect sampler %s: Texture state (%s) holds 0x%08x, which is not a texture",
                         sp->name, s->ref ? s->ref->name : "constant", obj);
            set_tex(e, sampler, obj);
        }
        else gp_fatal("sampler state class %u (%s)", si->klass, si->name);
    }
}

/* ---- shader constants from parameters (CTAB rules) ---- */
static float comp_of(const fx_param *p, bool cols_major_const, uint32_t reg, uint32_t c)
{
    uint32_t prows = p->klass == PC_VECTOR || p->klass == PC_SCALAR ? 1 : p->rows;
    uint32_t pcols = p->klass == PC_SCALAR ? 1 : p->cols;
    uint32_t row = cols_major_const ? c : reg, col = cols_major_const ? reg : c;
    if (row >= prows || col >= pcols) return 0.0f;
    uint32_t idx = (p->klass == PC_MATRIX_COLUMNS) ? col * p->rows + row : row * pcols + col;
    return getf(p, idx);
}

void gp_fx_pack(const fx_param *p, const fx_ctab_const *c, float *regs)
{
    uint32_t elems = p->elements ? p->elements : 1;
    uint32_t per = c->elements > 1 ? (c->count + c->elements - 1) / c->elements : c->count;
    uint32_t done = 0;
    bool cm = c->klass == PC_MATRIX_COLUMNS;
    for (uint32_t e = 0; e < elems && done < c->count; e++) {
        const fx_param *l = p->elements ? &p->members[e] : p;
        if (l->klass == PC_STRUCT) gp_fatal("struct shader constant %s", c->name);
        for (uint32_t r = 0; r < per && done < c->count; r++, done++)
            for (uint32_t k = 0; k < 4; k++) regs[4 * done + k] = comp_of(l, cm, r, k);
    }
}

static void upload_shader_inputs(fx_inst *e, fx_shader *sh)
{
    if (!sh) return;
    bool px = sh->pixel;
    for (uint32_t k = 0; k < sh->ctab.n; k++) {
        fx_ctab_const *c = &sh->ctab.c[k];
        if (!c->param) continue;
        switch (c->regset) {
        case RS_FLOAT4: {
            float regs[4 * 256];
            if (c->count > 256) gp_fatal("constant %s spans %u registers", c->name, c->count);
            gp_fx_pack(c->param, c, regs);
            gp_dev_set_const(px, 0, c->reg, regs, c->count);
            break;
        }
        case RS_INT4: {
            float regs[4 * 16]; int32_t iv[4 * 16];
            if (c->count > 16) gp_fatal("int constant %s spans %u registers", c->name, c->count);
            gp_fx_pack(c->param, c, regs);
            for (uint32_t i = 0; i < 4 * c->count; i++) iv[i] = (int32_t)lrintf(regs[i]);
            gp_dev_set_const(px, 1, c->reg, iv, c->count);
            break;
        }
        case RS_BOOL: {
            uint32_t bv[16];
            if (c->count > 16) gp_fatal("bool constant %s spans %u registers", c->name, c->count);
            for (uint32_t i = 0; i < c->count; i++) {
                const fx_param *l = c->param->elements ? &c->param->members[i < c->param->elements ? i : 0] : c->param;
                bv[i] = getf(l, c->param->elements ? 0 : i) != 0.0f;
            }
            gp_dev_set_const(px, 2, c->reg, bv, c->count);
            break;
        }
        case RS_SAMPLER:
            for (uint32_t i = 0; i < c->count; i++) {
                fx_param *sp = c->param->elements ? &c->param->members[i] : c->param;
                uint32_t sampler = px ? c->reg + i : 257 + c->reg + i;   /* vertex samplers are D3DVERTEXTEXTURESAMPLERn */
                apply_sampler(e, sp, sampler);
            }
            break;
        }
    }
    if (sh->pres) {
        float outf[4 * 256] = {0}; int32_t outi[64] = {0}; uint32_t outb[16] = {0};
        /* keep registers the preshader does not write: seed from the device */
        memcpy(outf, px ? (void *)D.ps_const : (void *)D.vs_const, 4 * 4 * (px ? 224 : 256));
        run_expr(sh->pres, outf, px ? 4 * 224 : 4 * 256, outi, outb);
        for (uint32_t i = 0; i < sh->pres->nins; i++) {
            const fx_ins *in = &sh->pres->ins[i];
            if (in->out.table == TAB_OCONST) gp_dev_set_const(px, 0, in->out.offset / 4, &outf[in->out.offset & ~3u], 1);
            else if (in->out.table == TAB_OICONST) gp_dev_set_const(px, 1, in->out.offset / 4, &outi[in->out.offset & ~3u], 1);
            else if (in->out.table == TAB_OBCONST) gp_dev_set_const(px, 2, in->out.offset, &outb[in->out.offset], 1);
        }
    }
}

static fx_shader *shader_of_value(fx_inst *e, fx_param *v, gaddr *obj)
{
    if (!v || !fx_is_shader(v->type)) { *obj = 0; return NULL; }
    fx_shader *sh = v->object_id < e->fx->nobjects ? e->fx->shaders[v->object_id] : NULL;
    *obj = sh ? e->shader_objs[v->object_id] : 0;
    return sh;
}

static void apply_pass(fx_inst *e, fx_pass *ps, bool commit)
{
    extern volatile bool gp_trace_frame_active;
    for (uint32_t i = 0; i < ps->nstates; i++) {
        fx_state *s = &ps->states[i];
        const fx_state_info *si = &fx_state_table[s->op];
        uint8_t buf[256]; fx_param scratch;
        fx_param *v = state_value(e, s, &scratch, buf);
        if (gp_trace_frame_active)
            gp_log("  pass state %s[%u] kind %u ref %s value 0x%08x%s", si->name, s->index, s->kind, s->ref ? s->ref->name : "-",
                   v && v->data && v->bytes >= 4 ? *(uint32_t *)v->data : 0, commit ? " (commit)" : "");
        if (commit && si->klass != SC_VERTEXSHADER && si->klass != SC_PIXELSHADER && si->klass != SC_SETSAMPLER
            && si->klass != SC_TEXTURE && s->kind == ST_CONSTANT) continue;   /* constants cannot change */
        switch (si->klass) {
        case SC_RENDERSTATE: set_rs(e, si->code, state_dword(v)); break;
        case SC_TEXTURESTAGE: set_tss(e, s->index, si->code, state_dword(v)); break;
        case SC_SAMPLERSTATE: set_ss(e, s->index, si->code, state_dword(v)); break;
        case SC_TEXTURE: set_tex(e, s->index, state_dword(v)); break;
        case SC_SETSAMPLER: apply_sampler(e, v, s->index); break;
        case SC_VERTEXSHADER: case SC_PIXELSHADER: {
            gaddr obj;
            fx_shader *sh = shader_of_value(e, v, &obj);
            bool px = si->klass == SC_PIXELSHADER;
            if (px) e->cur_ps = sh; else e->cur_vs = sh;
            set_shader(e, px, obj);
            break;
        }
        case SC_TRANSFORM: {
            float m[16] = {0};
            get_matrix(v, m, false);
            gp_dev_set_transform(si->code + s->index, m);
            break;
        }
        case SC_SHADERCONST: {
            bool px = si->code >= 3;
            int kind = si->code % 3 == 0 ? 0 : si->code % 3 == 2 ? 1 : 2;
            uint32_t n = kind == 2 ? v->bytes / 4 : v->bytes / 16;
            if (kind == 0) {
                float regs[4 * 256] = {0};
                for (uint32_t k = 0; k < 4 * n && k < 4 * 256; k++) regs[k] = getf(v, k);
                gp_dev_set_const(px, 0, s->index, regs, n);
            } else gp_dev_set_const(px, kind, s->index, v->data, n);
            break;
        }
        default:
            gp_fatal("effect state %s (class %u) is not implemented", si->name, si->klass);
        }
    }
    upload_shader_inputs(e, e->cur_vs);
    upload_shader_inputs(e, e->cur_ps);
}

static uint32_t Begin_(gp_thread *t)
{
    fx_inst *e = E;
    if (!e->tech) return D3DERR_INVALIDCALL;
    e->begun = true;
    e->begin_flags = A(2);
    e->nsaved = 0;
    if (A(1)) wr32(A(1), e->tech->npasses);
    return D3D_OK;
}
static uint32_t BeginPass_(gp_thread *t)
{
    fx_inst *e = E;
    if (!e->begun || A(1) >= e->tech->npasses || e->pass) return D3DERR_INVALIDCALL;
    e->pass = &e->tech->passes[A(1)];
    e->cur_vs = e->cur_ps = NULL;
    apply_pass(e, e->pass, false);
    return D3D_OK;
}
static uint32_t CommitChanges_(gp_thread *t)
{
    fx_inst *e = E;
    if (!e->pass) return D3D_OK;
    apply_pass(e, e->pass, true);
    return D3D_OK;
}
static uint32_t EndPass_(gp_thread *t) { fx_inst *e = E; if (!e->pass) return D3DERR_INVALIDCALL; e->pass = NULL; return D3D_OK; }
static uint32_t End_(gp_thread *t)
{
    fx_inst *e = E;
    if (!e->begun) return D3D_OK;
    for (uint32_t i = e->nsaved; i-- > 0;) {
        saved_state *s = &e->saved[i];
        switch (s->kind) {
        case 0: gp_dev_set_rs(s->a, s->v); break;
        case 1: gp_dev_set_tss(s->a, s->b, s->v); break;
        case 2: gp_dev_set_ss(s->a, s->b, s->v); break;
        case 3: gp_dev_set_texture(s->a, s->v); if (s->v) gp_d3d9_release(s->v); break;
        case 4: case 5: gp_dev_set_shader(s->kind == 5, s->v); if (s->v) gp_d3d9_release(s->v); break;
        }
    }
    e->nsaved = 0;
    e->begun = false;
    e->pass = NULL;
    return D3D_OK;
}

static uint32_t GetDevice_(gp_thread *t) { fx_inst *e = E; gp_d3d9_addref(e->device); wr32(A(1), e->device); return D3D_OK; }
static uint32_t OnLostDevice_(gp_thread *t) { (void)t; return D3D_OK; }
static uint32_t OnResetDevice_(gp_thread *t) { (void)t; return D3D_OK; }
static uint32_t GetPool_(gp_thread *t) { fx_inst *e = E; if (e->pool_obj) wr32(e->pool_obj + 4, rd32(e->pool_obj + 4) + 1); wr32(A(1), e->pool_obj); return D3D_OK; }
static uint32_t SetStateManager_(gp_thread *t) { if (A(1)) gp_fatal("ID3DXEffect::SetStateManager with a state manager"); return D3D_OK; }
static uint32_t GetStateManager_(gp_thread *t) { wr32(A(1), 0); return D3D_OK; }
static uint32_t GetVertexShader_(gp_thread *t)
{
    fx_inst *e = E;
    fx_param *p = param_of(e, A(1));
    gaddr obj = 0;
    if (p && p->type == PT_VERTEXSHADER) shader_of_value(e, p, &obj);
    if (obj) gp_d3d9_addref(obj);
    wr32(A(2), obj);
    return p ? D3D_OK : D3DERR_INVALIDCALL;
}
static uint32_t GetPixelShader_(gp_thread *t)
{
    fx_inst *e = E;
    fx_param *p = param_of(e, A(1));
    gaddr obj = 0;
    if (p && p->type == PT_PIXELSHADER) shader_of_value(e, p, &obj);
    if (obj) gp_d3d9_addref(obj);
    wr32(A(2), obj);
    return p ? D3D_OK : D3DERR_INVALIDCALL;
}

static uint32_t AddRefFx_(gp_thread *t) { uint32_t r = rd32(A(0) + 4) + 1; wr32(A(0) + 4, r); return r; }
static uint32_t ReleaseFx_(gp_thread *t)
{
    uint32_t r = rd32(A(0) + 4) - 1;
    wr32(A(0) + 4, r);
    if (r) return r;
    fx_inst *e = inst(A(0));
    uint32_t idx = rd32(A(0) + 8);
    /* release textures held by parameters and the device shaders */
    for (uint32_t i = 0; i < e->fx->nparams; i++) {
        fx_param *p = &e->fx->params[i];
        if (fx_is_texture(p->type) && !p->elements && !(e->pool >= 0 && (p->flags & SHARED_FLAG))) { uint32_t v; memcpy(&v, p->data, 4); if (v) gp_d3d9_release(v); }
        if (e->pool >= 0 && (p->flags & SHARED_FLAG) && p->bytes) p->data = NULL;   /* storage belongs to the pool */
    }
    for (uint32_t i = 0; i < e->fx->nobjects; i++) if (e->shader_objs[i]) gp_d3d9_release(e->shader_objs[i]);
    for (uint32_t i = 0; i < e->fx->nobjects; i++) { free(e->gstrings[i]); if (e->gcode[i]) gp_heap_free(e->gcode[i]); }
    if (e->pool_obj) wr32(e->pool_obj + 4, rd32(e->pool_obj + 4) - 1);
    gp_d3d9_release(e->device);
    /* handles stay allocated (their table entries point at freed data only if used after Release, which is a guest bug) */
    for (uint32_t i = 0; i < nh; i++) if (htab[i].e == e) htab[i].p = NULL, htab[i].kind = 0;
    fx_free(e->fx);
    free(e->saved); free(e->shader_objs); free(e->gstrings); free(e->gcode); free(e);
    effects[idx] = NULL;
    gp_heap_free(A(0));
    return 0;
}
static uint32_t QueryInterfaceFx_(gp_thread *t) { wr32(A(2), 0); return 0x80004002u; }

static uint32_t PoolAddRef_(gp_thread *t) { uint32_t r = rd32(A(0) + 4) + 1; wr32(A(0) + 4, r); return r; }
static uint32_t PoolRelease_(gp_thread *t)
{
    uint32_t r = rd32(A(0) + 4) - 1;
    wr32(A(0) + 4, r);
    return r;     /* shared storage outlives effects created from the pool; the pool id is not reused */
}

#undef DLL
#define DLL "d3dx9_27.dll"
const gp_api gp_api_d3dx9_fx[] = {
    API(D3DXCreateEffectPool_, "D3DXCreateEffectPool", 1), API(D3DXCreateEffect_, "D3DXCreateEffect", 9),
    { 0 }
};
#undef DLL
#define DLL "ID3DXEffectPool"
const gp_api gp_api_id3dxeffectpool[] = { API(QueryInterfaceFx_, "QueryInterface", 3), API(PoolAddRef_, "AddRef", 1), API(PoolRelease_, "Release", 1), { 0 } };
#undef DLL
#define DLL "ID3DXEffect"
const gp_api gp_api_id3dxeffect[] = {
    API(QueryInterfaceFx_, "QueryInterface", 3), API(AddRefFx_, "AddRef", 1), API(ReleaseFx_, "Release", 1),
    API(GetDesc_, "GetDesc", 2), API(GetParameterDesc_, "GetParameterDesc", 3), API(GetTechniqueDesc_, "GetTechniqueDesc", 3),
    API(GetPassDesc_, "GetPassDesc", 3), API(GetParameter_, "GetParameter", 3), API(GetParameterByName_, "GetParameterByName", 3),
    API(GetParameterBySemantic_, "GetParameterBySemantic", 3), API(GetParameterElement_, "GetParameterElement", 3),
    API(GetTechnique_, "GetTechnique", 2), API(GetTechniqueByName_, "GetTechniqueByName", 2), API(GetPass_, "GetPass", 3),
    API(GetPassByName_, "GetPassByName", 3), API(GetAnnotation_, "GetAnnotation", 3), API(GetAnnotationByName_, "GetAnnotationByName", 3),
    API(SetValue_, "SetValue", 4), API(GetValue_, "GetValue", 4), API(SetBool_, "SetBool", 3), API(GetBool_, "GetBool", 3),
    API(SetBoolArray_, "SetBoolArray", 4), API(GetBoolArray_, "GetBoolArray", 4), API(SetInt_, "SetInt", 3), API(GetInt_, "GetInt", 3),
    API(SetIntArray_, "SetIntArray", 4), API(GetIntArray_, "GetIntArray", 4), API(SetFloat_, "SetFloat", 3), API(GetFloat_, "GetFloat", 3),
    API(SetFloatArray_, "SetFloatArray", 4), API(GetFloatArray_, "GetFloatArray", 4), API(SetVector_, "SetVector", 3),
    API(GetVector_, "GetVector", 3), API(SetVectorArray_, "SetVectorArray", 4), API(GetVectorArray_, "GetVectorArray", 4),
    API(SetMatrix_, "SetMatrix", 3), API(GetMatrix_, "GetMatrix", 3), API(SetMatrixArray_, "SetMatrixArray", 4),
    API(GetMatrixArray_, "GetMatrixArray", 4), API(SetMatrixPointerArray_, "SetMatrixPointerArray", 4),
    API(GetMatrixPointerArray_, "GetMatrixPointerArray", 4), API(SetMatrixTranspose_, "SetMatrixTranspose", 3),
    API(GetMatrixTranspose_, "GetMatrixTranspose", 3), API(SetMatrixTransposeArray_, "SetMatrixTransposeArray", 4),
    API(GetMatrixTransposeArray_, "GetMatrixTransposeArray", 4), API(SetMatrixTransposePointerArray_, "SetMatrixTransposePointerArray", 4),
    API(GetMatrixTransposePointerArray_, "GetMatrixTransposePointerArray", 4), API(GetString_, "GetString", 3),
    API(SetTexture_, "SetTexture", 3), API(GetTexture_, "GetTexture", 3), API(GetPixelShader_, "GetPixelShader", 3),
    API(GetVertexShader_, "GetVertexShader", 3), API(GetPool_, "GetPool", 2), API(SetTechnique_, "SetTechnique", 2),
    API(GetCurrentTechnique_, "GetCurrentTechnique", 1), API(ValidateTechnique_, "ValidateTechnique", 2),
    API(FindNextValidTechnique_, "FindNextValidTechnique", 3), API(IsParameterUsed_, "IsParameterUsed", 3),
    API(Begin_, "Begin", 3), API(BeginPass_, "BeginPass", 2), API(CommitChanges_, "CommitChanges", 1),
    API(EndPass_, "EndPass", 1), API(End_, "End", 1), API(GetDevice_, "GetDevice", 2), API(OnLostDevice_, "OnLostDevice", 1),
    API(OnResetDevice_, "OnResetDevice", 1), API(SetStateManager_, "SetStateManager", 2), API(GetStateManager_, "GetStateManager", 2),
    API(SetRawValue_, "SetRawValue", 5),
    { 0 }
};

/* GP_FX_CHECK: after every ID3DX call, every texture parameter of every effect must hold a texture */
void gp_fx_debug_check(const char *method, uint32_t caller)
{
    for (int i = 0; i < MAX_EFFECTS; i++) {
        fx_inst *e = effects[i];
        if (!e) continue;
        for (uint32_t k = 0; k < e->fx->nparams; k++) {
            fx_param *p = &e->fx->params[k];
            if (!fx_is_texture(p->type) || p->elements || !p->data) continue;
            uint32_t v; memcpy(&v, p->data, 4);
            if (v && (v < 0x10000 || !gp_res_at(rd32(v + 8)) || gp_res_at(rd32(v + 8))->obj != v))
                gp_fatal("after %s from 0x%08x: effect %d parameter %s holds 0x%08x", method, caller, i, p->name, v);
        }
    }
}
