/* Direct3D 9 fixed-function pipeline: MSL generated per state key and cached. */
#import <Metal/Metal.h>
#include "gp_d3d9_state.h"
#include "gp_ff.h"
#include "gp_sm.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
static uint64_t fnv(const void *p, size_t n) { const uint8_t *b = p; uint64_t h = 1469598103934665603ull; for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ull; } return h; }

typedef struct fn_entry { uint64_t key; id<MTLFunction> fn; struct fn_entry *next; } fn_entry;
static fn_entry *cache;
static id<MTLFunction> cached(uint64_t key) { for (fn_entry *e = cache; e; e = e->next) if (e->key == key) return e->fn; return nil; }
static id<MTLFunction> build(uint64_t key, const char *src)
{
    NSError *e = nil;
    id<MTLLibrary> lib = [gp_mtl newLibraryWithSource:@(src) options:nil error:&e];
    id<MTLFunction> f = lib ? [lib newFunctionWithName:@"gp_main"] : nil;
    if (!f) { fprintf(stderr, "%s\n", src); gp_fatal("fixed-function shader compile failed: %s", e.localizedDescription.UTF8String); }
    fn_entry *n = calloc(1, sizeof *n);
    n->key = key; n->fn = f; n->next = cache; cache = n;
    return f;
}

/* ------------------------------------------------------------- vertex */
typedef struct {
    uint8_t postype;                  /* 1 float3 position, 2 float4 position, 3 pretransformed xyzrhw */
    uint8_t has_normal, has_d0, has_d1, lighting, colorvertex, src_d, src_s, src_a, src_e;
    uint8_t tc_size[8];               /* components of each texcoord set in the stream (0 absent) */
    uint8_t tci[8];                   /* D3DTSS_TEXCOORDINDEX (set) per stage */
    uint8_t ttff[8];                  /* D3DTSS_TEXTURETRANSFORMFLAGS per stage */
} vs_key;

typedef struct { float wvp[16]; float tex[8][16]; float mat_d[4], mat_a[4], mat_s[4], mat_e[4], ambient[4]; float vp[4], depth[4], fixup[4]; } ff_vs_uniforms;

static void mat_mul(const float *a, const float *b, float *o)
{
    for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) {
        float s = 0; for (int k = 0; k < 4; k++) s += a[i * 4 + k] * b[k * 4 + j];
        o[i * 4 + j] = s;
    }
}

id<MTLFunction> gp_ff_vertex_function(const gp_vdecl *decl, uint16_t *attr_mask, MTLVertexFormat *fmt, uint8_t *stream, uint16_t *offset, uint32_t *used)
{
    vs_key k = {0};
    *attr_mask = 0; *used = 0;
    /* attribute slots: 0 position, 1 normal, 2 diffuse, 3 specular, 4..11 texcoord sets */
    for (uint32_t i = 0; i < decl->n; i++) {
        const gp_velem *e = &decl->e[i];
        int slot = -1;
        if (e->usage == 0 && e->index == 0) { slot = 0; k.postype = e->type == 3 ? 2 : 1; }
        else if (e->usage == 9 && e->index == 0) { slot = 0; k.postype = 3; }
        else if (e->usage == 3 && e->index == 0) { slot = 1; k.has_normal = 1; }
        else if (e->usage == 10 && e->index < 2) { slot = 2 + e->index; if (e->index) k.has_d1 = 1; else k.has_d0 = 1; }
        else if (e->usage == 5 && e->index < 8) { slot = 4 + e->index; k.tc_size[e->index] = e->type <= 3 ? e->type + 1 : 4; }
        else continue;                                        /* blend weights etc.: not used without vertex blending */
        MTLVertexFormat f;
        switch (e->type) {
        case 0: f = MTLVertexFormatFloat; break; case 1: f = MTLVertexFormatFloat2; break;
        case 2: f = MTLVertexFormatFloat3; break; case 3: f = MTLVertexFormatFloat4; break;
        case 4: f = MTLVertexFormatUChar4Normalized_BGRA; break;
        case 15: f = MTLVertexFormatHalf2; break; case 16: f = MTLVertexFormatHalf4; break;
        default: gp_fatal("fixed-function vertex element type %u", e->type);
        }
        *attr_mask |= (uint16_t)(1u << slot); fmt[slot] = f; stream[slot] = (uint8_t)e->stream; offset[slot] = e->offset;
        *used |= 1u << e->stream;
    }
    if (!k.postype) gp_fatal("fixed-function draw without a position");
    k.lighting = D.rs[137] && k.postype != 3;
    if (D.rs[151]) gp_fatal("fixed-function vertex blending (D3DRS_VERTEXBLEND %u)", D.rs[151]);
    if (D.rs[28] && !D.rs[35] && D.rs[140] && k.postype != 3) gp_fatal("fixed-function vertex fog");
    k.colorvertex = D.rs[141] && (k.has_d0 || k.has_d1);
    k.src_d = (uint8_t)D.rs[145]; k.src_s = (uint8_t)D.rs[146]; k.src_a = (uint8_t)D.rs[147]; k.src_e = (uint8_t)D.rs[148];
    for (int s = 0; s < 8; s++) {
        k.tci[s] = (uint8_t)(D.tss[s][11] & 7);
        if (D.tss[s][11] & 0xffff0000u) gp_fatal("fixed-function texture coordinate generation 0x%x", D.tss[s][11]);
        k.ttff[s] = (uint8_t)(D.tss[s][24] & 0x1ff);
    }
    /* SetLight/LightEnable trap as unimplemented, so no light is ever enabled here */
    uint64_t key = fnv(&k, sizeof k) ^ 0x76733131u;
    id<MTLFunction> f = cached(key);
    if (f) return f;
    const char *vd0 = k.has_d0 ? "v.d0" : "float4(1.0f)", *vd1 = k.has_d1 ? "v.d1" : "float4(0.0f)";
    sb b = {0};
    put(&b, "#include <metal_stdlib>\nusing namespace metal;\n"
            "struct U { float4x4 wvp; float4x4 tex[8]; float4 mat_d, mat_a, mat_s, mat_e, ambient; float4 vp, depth, fixup; };\n"
            "struct vin { float4 pos [[attribute(0)]];%s%s%s", k.has_normal ? " float3 n [[attribute(1)]];" : "",
            k.has_d0 ? " float4 d0 [[attribute(2)]];" : "", k.has_d1 ? " float4 d1 [[attribute(3)]];" : "");
    for (int i = 0; i < 8; i++) if (k.tc_size[i]) put(&b, " float4 tc%d [[attribute(%d)]];", i, 4 + i);
    put(&b, " };\n");
    put(&b, "struct vout { float4 pos [[position]]; float4 d0 [[user(d0)]]; float4 d1 [[user(d1)]];"
            " float4 t0 [[user(t0)]]; float4 t1 [[user(t1)]]; float4 t2 [[user(t2)]]; float4 t3 [[user(t3)]];"
            " float4 t4 [[user(t4)]]; float4 t5 [[user(t5)]]; float4 t6 [[user(t6)]]; float4 t7 [[user(t7)]];"
            " float fog [[user(fog)]]; float psize [[point_size]]; };\n");
    put(&b, "vertex vout gp_main(vin v [[stage_in]], constant U &u [[buffer(16)]]) {\n    vout o = {};\n");
    if (k.postype == 3) {
        put(&b, "    float w = 1.0f / (v.pos.w == 0.0f ? 1.0f : v.pos.w);\n"
                "    float2 ndc = float2((v.pos.x + 0.5f - u.vp.x) / u.vp.z * 2.0f - 1.0f, 1.0f - (v.pos.y + 0.5f - u.vp.y) / u.vp.w * 2.0f);\n"
                "    float z = (v.pos.z - u.depth.x) / max(u.depth.y - u.depth.x, 1e-20f);\n"
                "    o.pos = float4(ndc * w, z * w, w);\n");
    } else {
        put(&b, "    float4 p = %s;\n    o.pos = u.wvp * p;\n    o.pos.xy += u.fixup.xy * o.pos.w;\n",
            k.postype == 2 ? "v.pos" : "float4(v.pos.xyz, 1.0f)");
    }
    if (k.lighting) {
#define SRC(x, mat) (k.colorvertex && (x) == 1 && k.has_d0 ? "v.d0" : k.colorvertex && (x) == 2 && k.has_d1 ? "v.d1" : mat)
        put(&b, "    float4 amb = %s, emi = %s, dif = %s;\n", SRC(k.src_a, "u.mat_a"), SRC(k.src_e, "u.mat_e"), SRC(k.src_d, "u.mat_d"));
        put(&b, "    o.d0 = float4(saturate(emi.xyz + u.ambient.xyz * amb.xyz), dif.w);\n    o.d1 = float4(0.0f);\n");
#undef SRC
    } else put(&b, "    o.d0 = %s;\n    o.d1 = %s;\n", vd0, vd1);
    for (int s = 0; s < 8; s++) {
        int set = k.tci[s];
        if (!k.tc_size[set]) { put(&b, "    o.t%d = float4(0.0f, 0.0f, 0.0f, 1.0f);\n", s); continue; }
        int n = k.tc_size[set];
        static const char comp[4] = { 'x', 'y', 'z', 'w' };
        put(&b, "    { float4 tc = float4(0.0f, 0.0f, 0.0f, 1.0f);");
        for (int c = 0; c < n; c++) put(&b, " tc.%c = v.tc%d.%c;", comp[c], set, comp[c]);
        put(&b, "\n");
        if (k.ttff[s] & 0xff) put(&b, "      float4 in4 = tc; in4[%d] = 1.0f; tc = u.tex[%d] * in4;\n", n < 4 ? n : 3, s);
        put(&b, "      o.t%d = tc; }\n", s);
    }
    put(&b, "    o.fog = 1.0f;\n    o.psize = 1.0f;\n    return o;\n}\n");
    f = build(key, b.s);
    free(b.s);
    return f;
}

void gp_ff_bind_vertex(id<MTL4ArgumentTable> t, float vx, float vy, float vw, float vh)
{
    ff_vs_uniforms u = {0};
    float wv[16];
    mat_mul(D.transforms[256], D.transforms[2], wv);                    /* WORLD * VIEW */
    mat_mul(wv, D.transforms[3], u.wvp);                                /* * PROJECTION */
    for (int s = 0; s < 8; s++) memcpy(u.tex[s], D.transforms[16 + s], 64);
    memcpy(u.mat_d, D.material, 16); memcpy(u.mat_a, D.material + 16, 16); memcpy(u.mat_s, D.material + 32, 16); memcpy(u.mat_e, D.material + 48, 16);
    uint32_t a = D.rs[139];
    u.ambient[0] = ((a >> 16) & 255) / 255.0f; u.ambient[1] = ((a >> 8) & 255) / 255.0f; u.ambient[2] = (a & 255) / 255.0f; u.ambient[3] = (a >> 24) / 255.0f;
    u.vp[0] = vx; u.vp[1] = vy; u.vp[2] = vw; u.vp[3] = vh;
    u.depth[0] = D.viewport.minz; u.depth[1] = D.viewport.maxz;
    u.fixup[0] = 1.0f / vw; u.fixup[1] = -1.0f / vh;
    [t setAddress:gp_transient(&u, sizeof u, 256, NULL) atIndex:16];
}

/* ------------------------------------------------------------- pixel: texture stage cascade */
typedef struct { uint8_t cop, ca0, ca1, ca2, aop, aa0, aa1, aa2, res, type, proj; } stage_key;
typedef struct { stage_key st[8]; uint8_t nstages, specular; } ps_key;

typedef struct { float tfactor[4]; float constant[8][4]; float alpha_ref; uint32_t alpha_func, fog_mode; float fog_start, fog_end, fog_density; float pad[2]; float fog_color[4]; float lod_bias[8]; } ff_ps_uniforms;

static void arg(sb *b, uint8_t a, int stage, bool alpha)
{
    const char *base;
    char buf[48];
    switch (a & 0xf) {
    case 0: base = "in.d0"; break;
    case 1: base = "cur"; break;
    case 2: snprintf(buf, sizeof buf, "tx%d", stage); base = buf; break;
    case 3: base = "u.tfactor"; break;
    case 4: base = "in.d1"; break;
    case 5: base = "tmp"; break;
    case 6: snprintf(buf, sizeof buf, "u.tconst[%d]", stage); base = buf; break;
    default: gp_fatal("texture stage argument 0x%x", a);
    }
    char v[96];
    snprintf(v, sizeof v, (a & 0x20) && !alpha ? "float4((%s).w)" : "(%s)", base);   /* D3DTA_ALPHAREPLICATE */
    if (a & 0x10) put(b, "(1.0f - %s)", v); else put(b, "%s", v);                     /* D3DTA_COMPLEMENT */
}

static void op(sb *b, uint8_t o, const uint8_t *args, int stage, bool alpha, const char *comp)
{
#define A1 arg(b, args[1], stage, alpha)
#define A2 arg(b, args[2], stage, alpha)
#define A0 arg(b, args[0], stage, alpha)
    switch (o) {
    case 2: A1; break;
    case 3: A2; break;
    case 4: A1; put(b, " * "); A2; break;
    case 5: put(b, "2.0f * "); A1; put(b, " * "); A2; break;
    case 6: put(b, "4.0f * "); A1; put(b, " * "); A2; break;
    case 7: A1; put(b, " + "); A2; break;
    case 8: A1; put(b, " + "); A2; put(b, " - 0.5f"); break;
    case 9: put(b, "2.0f * ("); A1; put(b, " + "); A2; put(b, " - 0.5f)"); break;
    case 10: A1; put(b, " - "); A2; break;
    case 11: A1; put(b, " + "); A2; put(b, " * (1.0f - "); A1; put(b, ")"); break;
    case 12: put(b, "mix("); A2; put(b, ", "); A1; put(b, ", in.d0.w)"); break;
    case 13: put(b, "mix("); A2; put(b, ", "); A1; put(b, ", tx%d.w)", stage); break;
    case 14: put(b, "mix("); A2; put(b, ", "); A1; put(b, ", u.tfactor.w)"); break;
    case 15: A1; put(b, " + "); A2; put(b, " * (1.0f - tx%d.w)", stage); break;
    case 16: put(b, "mix("); A2; put(b, ", "); A1; put(b, ", cur.w)"); break;
    case 18: A1; put(b, " + ("); A1; put(b, ").w * "); A2; break;           /* MODULATEALPHA_ADDCOLOR */
    case 19: A1; put(b, " * "); A2; put(b, " + ("); A1; put(b, ").w"); break;
    case 20: A1; put(b, " + (1.0f - ("); A1; put(b, ").w) * "); A2; break;
    case 21: put(b, "(1.0f - "); A1; put(b, ") * "); A2; put(b, " + ("); A1; put(b, ").w"); break;
    case 24: put(b, "float4(saturate(4.0f * dot(("); A1; put(b, ").xyz - 0.5f, ("); A2; put(b, ").xyz - 0.5f)))"); break;
    case 25: A0; put(b, " + "); A1; put(b, " * "); A2; break;
    case 26: put(b, "mix("); A2; put(b, ", "); A1; put(b, ", "); A0; put(b, ")"); break;
    default: gp_fatal("texture stage operation %u", o);
    }
    (void)comp;
#undef A0
#undef A1
#undef A2
}

static uint8_t tex_type_of(uint32_t idx)
{
    gp_res *r = gp_res_at(idx);
    if (!r) return 255;
    return r->kind == R_CUBE ? SM_TEX_CUBE : r->kind == R_VOLUME ? SM_TEX_3D : SM_TEX_2D;
}

id<MTLFunction> gp_ff_fragment_function(uint16_t *sampler_mask)
{
    ps_key k = {0};
    *sampler_mask = 0;
    for (int s = 0; s < 8; s++) {
        uint32_t *t = D.tss[s];
        if (t[1] == 1) break;                                           /* D3DTOP_DISABLE ends the cascade */
        stage_key *st = &k.st[s];
        st->cop = (uint8_t)t[1]; st->ca1 = (uint8_t)t[2]; st->ca2 = (uint8_t)t[3]; st->ca0 = (uint8_t)t[26];
        st->aop = (uint8_t)t[4]; st->aa1 = (uint8_t)t[5]; st->aa2 = (uint8_t)t[6]; st->aa0 = (uint8_t)t[27]; st->res = (uint8_t)t[28];
        st->type = tex_type_of(D.textures[s]);
        st->proj = (t[24] & 0x100) != 0;
        k.nstages++;
    }
    k.specular = (uint8_t)D.rs[29];
    uint64_t key = fnv(&k, sizeof k) ^ 0x70733131u;
    for (int s = 0; s < k.nstages; s++) {
        stage_key *st = &k.st[s];
        bool uses = (st->ca1 & 0xf) == 2 || (st->ca2 & 0xf) == 2 || (st->ca0 & 0xf) == 2 || (st->aa1 & 0xf) == 2 ||
                    (st->aa2 & 0xf) == 2 || (st->aa0 & 0xf) == 2 || st->cop == 13 || st->cop == 15;
        if (uses && st->type != 255) *sampler_mask |= (uint16_t)(1u << s);
    }
    id<MTLFunction> f = cached(key);
    if (f) return f;
    sb b = {0};
    put(&b, "#include <metal_stdlib>\nusing namespace metal;\n"
            "struct U { float4 tfactor; float4 tconst[8]; float alpha_ref; uint alpha_func, fog_mode; float fog_start, fog_end, fog_density; float2 pad; float4 fog_color; float lod_bias[8]; };\n"
            "struct vin { float4 pos [[position]]; float4 d0 [[user(d0)]]; float4 d1 [[user(d1)]];"
            " float4 t0 [[user(t0)]]; float4 t1 [[user(t1)]]; float4 t2 [[user(t2)]]; float4 t3 [[user(t3)]];"
            " float4 t4 [[user(t4)]]; float4 t5 [[user(t5)]]; float4 t6 [[user(t6)]]; float4 t7 [[user(t7)]]; float fog [[user(fog)]]; };\n"
            "fragment float4 gp_main(vin in [[stage_in]], constant U &u [[buffer(0)]]");
    for (int s = 0; s < k.nstages; s++) {
        if (!(*sampler_mask & (1u << s))) continue;
        const char *tt = k.st[s].type == SM_TEX_CUBE ? "texturecube<float>" : k.st[s].type == SM_TEX_3D ? "texture3d<float>" : "texture2d<float>";
        put(&b, ", %s tex%d [[texture(%d)]], sampler smp%d [[sampler(%d)]]", tt, s, s, s, s);
    }
    put(&b, ") {\n    float4 cur = in.d0, tmp = float4(0.0f);\n");
    if (!k.nstages) put(&b, "    cur = in.d0;\n");
    for (int s = 0; s < k.nstages; s++) {
        stage_key *st = &k.st[s];
        if (*sampler_mask & (1u << s)) {
            const char *coord = st->type == SM_TEX_2D ? (st->proj ? "(in.t%d.xy / in.t%d.w)" : "in.t%d.xy") : "in.t%d.xyz";
            char c[64]; snprintf(c, sizeof c, coord, s, s);
            put(&b, "    float4 tx%d = tex%d.sample(smp%d, %s, bias(u.lod_bias[%d]));\n", s, s, s, c, s);
        } else put(&b, "    float4 tx%d = float4(1.0f);\n", s);          /* D3D: no texture reads as opaque white */
        uint8_t ca[3] = { st->ca0, st->ca1, st->ca2 }, aa[3] = { st->aa0, st->aa1, st->aa2 };
        put(&b, "    { float4 rc = ");
        op(&b, st->cop, ca, s, false, "xyz");
        put(&b, ";\n      float4 ra = ");
        if (st->aop == 1) put(&b, "cur"); else op(&b, st->aop, aa, s, true, "w");
        put(&b, ";\n      float4 r = saturate(float4(rc.xyz, ra.w));\n");
        put(&b, st->res == 5 ? "      tmp = r; }\n" : "      cur = r; }\n");
    }
    if (k.specular) put(&b, "    cur.xyz = saturate(cur.xyz + in.d1.xyz);\n");
    put(&b, "    switch (u.alpha_func) { case 1: discard_fragment(); break; case 2: if (!(cur.w < u.alpha_ref)) discard_fragment(); break;"
            " case 3: if (!(cur.w == u.alpha_ref)) discard_fragment(); break; case 4: if (!(cur.w <= u.alpha_ref)) discard_fragment(); break;"
            " case 5: if (!(cur.w > u.alpha_ref)) discard_fragment(); break; case 6: if (!(cur.w != u.alpha_ref)) discard_fragment(); break;"
            " case 7: if (!(cur.w >= u.alpha_ref)) discard_fragment(); break; default: break; }\n");
    put(&b, "    if (u.fog_mode != 0) { float z = in.pos.z; float f = u.fog_mode == 4 ? in.fog : u.fog_mode == 3 ? saturate((u.fog_end - z) / (u.fog_end - u.fog_start))"
            " : u.fog_mode == 1 ? exp(-u.fog_density * z) : exp(-(u.fog_density * z) * (u.fog_density * z)); cur.xyz = mix(u.fog_color.xyz, cur.xyz, saturate(f)); }\n");
    put(&b, "    return cur;\n}\n");
    f = build(key, b.s);
    free(b.s);
    return f;
}

void gp_ff_bind_fragment(id<MTL4ArgumentTable> t)
{
    ff_ps_uniforms u = {0};
    uint32_t tf = D.rs[60];
    u.tfactor[0] = ((tf >> 16) & 255) / 255.0f; u.tfactor[1] = ((tf >> 8) & 255) / 255.0f; u.tfactor[2] = (tf & 255) / 255.0f; u.tfactor[3] = (tf >> 24) / 255.0f;
    for (int s = 0; s < 8; s++) {
        uint32_t c = D.tss[s][32];
        u.constant[s][0] = ((c >> 16) & 255) / 255.0f; u.constant[s][1] = ((c >> 8) & 255) / 255.0f; u.constant[s][2] = (c & 255) / 255.0f; u.constant[s][3] = (c >> 24) / 255.0f;
        memcpy(&u.lod_bias[s], &D.ss[s][8], 4);
    }
    u.alpha_ref = (float)(D.rs[24] & 0xff) / 255.0f;
    u.alpha_func = D.rs[15] ? D.rs[25] : 8;
    if (D.rs[28]) {
        u.fog_mode = D.rs[35] ? D.rs[35] : 4;
        memcpy(&u.fog_start, &D.rs[36], 4); memcpy(&u.fog_end, &D.rs[37], 4); memcpy(&u.fog_density, &D.rs[38], 4);
        uint32_t fc = D.rs[34];
        u.fog_color[0] = ((fc >> 16) & 255) / 255.0f; u.fog_color[1] = ((fc >> 8) & 255) / 255.0f; u.fog_color[2] = (fc & 255) / 255.0f; u.fog_color[3] = 1;
    }
    [t setAddress:gp_transient(&u, sizeof u, 256, NULL) atIndex:0];
}
