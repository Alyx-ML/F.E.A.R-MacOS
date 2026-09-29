/* Direct3D 9 draw calls on Metal 4: shader variants, pipelines, fixed state objects, bindings. */
#import <Metal/Metal.h>
#include "gp_d3d9_state.h"
#include "gp_d3d9_shader.h"
#include "gp_sm.h"
#include "gp_ff.h"
uint64_t gp_d3d9_draws_total;
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------- hashing */
static uint64_t fnv(const void *p, size_t n, uint64_t h)
{
    const uint8_t *b = p;
    for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ull; }
    return h;
}
#define FNV0 1469598103934665603ull

/* ------------------------------------------------------------- vertex formats */
typedef struct { MTLVertexFormat fmt; uint8_t cls; } vfmt;   /* cls: 1 float, 2 uint, 3 int */
static vfmt decl_format(uint8_t t)
{
    switch (t) {
    case 0: return (vfmt){ MTLVertexFormatFloat, 1 };
    case 1: return (vfmt){ MTLVertexFormatFloat2, 1 };
    case 2: return (vfmt){ MTLVertexFormatFloat3, 1 };
    case 3: return (vfmt){ MTLVertexFormatFloat4, 1 };
    case 4: return (vfmt){ MTLVertexFormatUChar4Normalized_BGRA, 1 };
    case 5: return (vfmt){ MTLVertexFormatUChar4, 2 };
    case 6: return (vfmt){ MTLVertexFormatShort2, 3 };
    case 7: return (vfmt){ MTLVertexFormatShort4, 3 };
    case 8: return (vfmt){ MTLVertexFormatUChar4Normalized, 1 };
    case 9: return (vfmt){ MTLVertexFormatShort2Normalized, 1 };
    case 10: return (vfmt){ MTLVertexFormatShort4Normalized, 1 };
    case 11: return (vfmt){ MTLVertexFormatUShort2Normalized, 1 };
    case 12: return (vfmt){ MTLVertexFormatUShort4Normalized, 1 };
    case 14: return (vfmt){ MTLVertexFormatInt1010102Normalized, 1 };
    case 15: return (vfmt){ MTLVertexFormatHalf2, 1 };
    case 16: return (vfmt){ MTLVertexFormatHalf4, 1 };
    }
    gp_fatal("vertex element type %u is not supported", t);
}

/* current declaration (vertex declaration object or FVF) */
static const gp_vdecl *current_decl(void)
{
    static gp_vdecl fvf_decl;
    static uint32_t fvf_cached = 0xffffffffu;
    if (D.vdecl) return gp_res_at(D.vdecl)->priv;
    if (!D.fvf) gp_fatal("draw without a vertex declaration or FVF");
    if (D.fvf != fvf_cached) { gp_fvf_to_decl(D.fvf, &fvf_decl); fvf_cached = D.fvf; }
    return &fvf_decl;
}

/* ------------------------------------------------------------- shader variants */
static id<MTLFunction> compile(const char *src, const char *what)
{
    NSError *e = nil;
    if (getenv("GP_DUMP_MSL")) gp_log("---- %s ----\n%s", what, src);
    MTLCompileOptions *o = [MTLCompileOptions new];
    o.mathMode = MTLMathModeFast;
    id<MTLLibrary> lib = [gp_mtl newLibraryWithSource:@(src) options:o error:&e];
    id<MTLFunction> f = lib ? [lib newFunctionWithName:@"gp_main"] : nil;
    if (!f) {
        fprintf(stderr, "---- %s ----\n%s\n", what, src);
        gp_fatal("Metal compile of %s failed: %s", what, e.localizedDescription.UTF8String);
    }
    return f;
}

static id<MTLFunction> shader_variant(uint32_t idx, const sm_key *k, sm_info *info_out)
{
    gp_shader *sh = gp_res_at(idx)->priv;
    uint64_t key = fnv(k, sizeof *k, FNV0);
    for (gp_shader_variant *v = sh->variants; v; v = v->next)
        if (v->key == key) {
            if (info_out) { char e[64]; sm_scan(sh->code, sh->words, info_out, e, sizeof e); }
            return v->fn;
        }
    sm_info info;
    char err[256];
    char *src = sm_translate(sh->code, sh->words, k, &info, err, sizeof err);
    if (!src) gp_fatal("shader translation: %s", err);
    gp_shader_variant *v = calloc(1, sizeof *v);
    v->key = key;
    v->fn = compile(src, sh->pixel ? "pixel shader" : "vertex shader");
    free(src);
    v->next = sh->variants;
    sh->variants = v;
    if (info_out) *info_out = info;
    return v->fn;
}

/* ------------------------------------------------------------- pipelines */
typedef struct pso_entry { uint64_t key; id<MTLRenderPipelineState> pso; struct pso_entry *next; } pso_entry;
#define PSO_BUCKETS 4096
static pso_entry *pso_table[PSO_BUCKETS];

static MTLBlendFactor blend_factor(uint32_t b, bool alpha)
{
    switch (b) {
    case 1: return MTLBlendFactorZero; case 2: return MTLBlendFactorOne;
    case 3: return MTLBlendFactorSourceColor; case 4: return MTLBlendFactorOneMinusSourceColor;
    case 5: return MTLBlendFactorSourceAlpha; case 6: return MTLBlendFactorOneMinusSourceAlpha;
    case 7: return MTLBlendFactorDestinationAlpha; case 8: return MTLBlendFactorOneMinusDestinationAlpha;
    case 9: return MTLBlendFactorDestinationColor; case 10: return MTLBlendFactorOneMinusDestinationColor;
    case 11: return MTLBlendFactorSourceAlphaSaturated;
    case 12: return MTLBlendFactorSourceAlpha;                           /* BOTHSRCALPHA: src = a, dst = 1-a */
    case 13: return MTLBlendFactorOneMinusSourceAlpha;                   /* BOTHINVSRCALPHA */
    case 14: return alpha ? MTLBlendFactorBlendAlpha : MTLBlendFactorBlendColor;
    case 15: return alpha ? MTLBlendFactorOneMinusBlendAlpha : MTLBlendFactorOneMinusBlendColor;
    }
    gp_fatal("blend factor %u", b);
}
static MTLBlendOperation blend_op(uint32_t o)
{
    switch (o) { case 1: return MTLBlendOperationAdd; case 2: return MTLBlendOperationSubtract;
    case 3: return MTLBlendOperationReverseSubtract; case 4: return MTLBlendOperationMin; case 5: return MTLBlendOperationMax; }
    gp_fatal("blend operation %u", o);
}

typedef struct {
    MTLPixelFormat color[4], depth;
    uint32_t blend_enable, src, dst, op, sep, src_a, dst_a, op_a;
    uint32_t write[4];
    uint32_t stride_mask;                     /* streams used */
    MTLVertexFormat attr_fmt[16]; uint8_t attr_stream[16]; uint16_t attr_offset[16]; uint16_t attr_mask;
    uint32_t stream_step[16];                 /* instancing: 0 per-vertex, else per-instance rate */
    uintptr_t vs, ps;
} pso_key;

static id<MTLRenderPipelineState> pipeline(const pso_key *k, id<MTLFunction> vs, id<MTLFunction> ps)
{
    uint64_t h = fnv(k, sizeof *k, FNV0);
    for (pso_entry *e = pso_table[h % PSO_BUCKETS]; e; e = e->next) if (e->key == h) return e->pso;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = vs; d.fragmentFunction = ps;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    for (int a = 0; a < 16; a++) {
        if (!(k->attr_mask & (1u << a))) continue;
        vd.attributes[a].format = k->attr_fmt[a];
        vd.attributes[a].offset = k->attr_offset[a];
        vd.attributes[a].bufferIndex = k->attr_stream[a];
    }
    for (int s = 0; s < 16; s++) {
        if (!(k->stride_mask & (1u << s))) continue;
        vd.layouts[s].stride = MTLBufferLayoutStrideDynamic;
        if (k->stream_step[s]) { vd.layouts[s].stepFunction = MTLVertexStepFunctionPerInstance; vd.layouts[s].stepRate = k->stream_step[s]; }
    }
    d.vertexDescriptor = vd;
    for (int i = 0; i < 4; i++) {
        if (!k->color[i]) continue;
        MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[i];
        c.pixelFormat = k->color[i];
        c.writeMask = ((k->write[i] & 1) ? MTLColorWriteMaskRed : 0) | ((k->write[i] & 2) ? MTLColorWriteMaskGreen : 0) |
                      ((k->write[i] & 4) ? MTLColorWriteMaskBlue : 0) | ((k->write[i] & 8) ? MTLColorWriteMaskAlpha : 0);
        if (k->blend_enable) {
            c.blendingEnabled = YES;
            c.sourceRGBBlendFactor = blend_factor(k->src, false); c.destinationRGBBlendFactor = blend_factor(k->dst, false);
            if (k->src == 12) c.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            if (k->src == 13) c.destinationRGBBlendFactor = MTLBlendFactorSourceAlpha;
            c.rgbBlendOperation = blend_op(k->op);
            if (k->sep) {
                c.sourceAlphaBlendFactor = blend_factor(k->src_a, true); c.destinationAlphaBlendFactor = blend_factor(k->dst_a, true);
                c.alphaBlendOperation = blend_op(k->op_a);
            } else {
                c.sourceAlphaBlendFactor = blend_factor(k->src, true); c.destinationAlphaBlendFactor = blend_factor(k->dst, true);
                if (k->src == 12) c.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                if (k->src == 13) c.destinationAlphaBlendFactor = MTLBlendFactorSourceAlpha;
                c.alphaBlendOperation = blend_op(k->op);
            }
        }
    }
    if (k->depth) { d.depthAttachmentPixelFormat = k->depth; d.stencilAttachmentPixelFormat = k->depth; }
    NSError *e = nil;
    id<MTLRenderPipelineState> p = [gp_mtl newRenderPipelineStateWithDescriptor:d error:&e];
    if (!p) gp_fatal("Metal pipeline creation failed: %s", e.localizedDescription.UTF8String);
    pso_entry *n = calloc(1, sizeof *n);
    n->key = h; n->pso = p; n->next = pso_table[h % PSO_BUCKETS];
    pso_table[h % PSO_BUCKETS] = n;
    return p;
}

/* ------------------------------------------------------------- depth/stencil and samplers */
static MTLCompareFunction cmpf(uint32_t f)
{
    static const MTLCompareFunction m[9] = { MTLCompareFunctionAlways, MTLCompareFunctionNever, MTLCompareFunctionLess,
        MTLCompareFunctionEqual, MTLCompareFunctionLessEqual, MTLCompareFunctionGreater, MTLCompareFunctionNotEqual,
        MTLCompareFunctionGreaterEqual, MTLCompareFunctionAlways };
    if (f < 1 || f > 8) gp_fatal("compare function %u", f);
    return m[f];
}
static MTLStencilOperation stencil_op(uint32_t o)
{
    static const MTLStencilOperation m[9] = { MTLStencilOperationKeep, MTLStencilOperationKeep, MTLStencilOperationZero,
        MTLStencilOperationReplace, MTLStencilOperationIncrementClamp, MTLStencilOperationDecrementClamp,
        MTLStencilOperationInvert, MTLStencilOperationIncrementWrap, MTLStencilOperationDecrementWrap };
    if (o < 1 || o > 8) gp_fatal("stencil operation %u", o);
    return m[o];
}

typedef struct ds_entry { uint64_t key; id<MTLDepthStencilState> s; struct ds_entry *next; } ds_entry;
static ds_entry *ds_list;
static id<MTLDepthStencilState> depth_state(bool has_depth, bool has_stencil)
{
    uint32_t k[14] = { has_depth && D.rs[7], has_depth && D.rs[14], D.rs[23], has_stencil && D.rs[52], D.rs[53], D.rs[54],
                       D.rs[55], D.rs[56], D.rs[58], D.rs[59], D.rs[185], D.rs[186], D.rs[187] | (D.rs[188] << 8), D.rs[189] };
    uint64_t h = fnv(k, sizeof k, FNV0);
    for (ds_entry *e = ds_list; e; e = e->next) if (e->key == h) return e->s;
    MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
    d.depthCompareFunction = k[0] ? cmpf(D.rs[23]) : MTLCompareFunctionAlways;
    d.depthWriteEnabled = k[0] && k[1];
    if (k[3]) {
        MTLStencilDescriptor *f = [MTLStencilDescriptor new];
        f.stencilCompareFunction = cmpf(D.rs[56]);
        f.stencilFailureOperation = stencil_op(D.rs[53]); f.depthFailureOperation = stencil_op(D.rs[54]); f.depthStencilPassOperation = stencil_op(D.rs[55]);
        f.readMask = D.rs[58] & 0xff; f.writeMask = D.rs[59] & 0xff;
        MTLStencilDescriptor *bk = f;
        if (D.rs[185]) {                                                  /* two-sided stencil: CCW faces */
            bk = [MTLStencilDescriptor new];
            bk.stencilCompareFunction = cmpf(D.rs[189]);
            bk.stencilFailureOperation = stencil_op(D.rs[186]); bk.depthFailureOperation = stencil_op(D.rs[187]); bk.depthStencilPassOperation = stencil_op(D.rs[188]);
            bk.readMask = f.readMask; bk.writeMask = f.writeMask;
        }
        /* D3D front faces are clockwise; the encoder's front winding is set to clockwise */
        d.frontFaceStencil = f; d.backFaceStencil = bk;
    }
    id<MTLDepthStencilState> s = [gp_mtl newDepthStencilStateWithDescriptor:d];
    ds_entry *n = calloc(1, sizeof *n);
    n->key = h; n->s = s; n->next = ds_list; ds_list = n;
    return s;
}

static MTLSamplerAddressMode addr_mode(uint32_t a)
{
    switch (a) {
    case 1: return MTLSamplerAddressModeRepeat; case 2: return MTLSamplerAddressModeMirrorRepeat;
    case 3: return MTLSamplerAddressModeClampToEdge; case 4: return MTLSamplerAddressModeClampToBorderColor;
    case 5: return MTLSamplerAddressModeMirrorClampToEdge;
    }
    gp_fatal("texture address mode %u", a);
}
typedef struct smp_entry { uint64_t key; id<MTLSamplerState> s; struct smp_entry *next; } smp_entry;
static smp_entry *smp_list;
static id<MTLSamplerState> sampler(int slot, bool compare)
{
    uint32_t *ss = D.ss[slot];
    uint32_t k[9] = { ss[1], ss[2], ss[3], ss[4], ss[5], ss[6], ss[7], ss[9] | (ss[10] << 16), compare };
    uint64_t h = fnv(k, sizeof k, FNV0);
    for (smp_entry *e = smp_list; e; e = e->next) if (e->key == h) return e->s;
    MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
    d.sAddressMode = addr_mode(ss[1]); d.tAddressMode = addr_mode(ss[2]); d.rAddressMode = addr_mode(ss[3]);
    uint32_t bc = ss[4];
    d.borderColor = (bc >> 24) == 0 ? MTLSamplerBorderColorTransparentBlack : (bc & 0xffffff) ? MTLSamplerBorderColorOpaqueWhite : MTLSamplerBorderColorOpaqueBlack;
    uint32_t mag = ss[5], min = ss[6], mip = ss[7], aniso = ss[10];
    d.magFilter = mag == 1 ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
    d.minFilter = min == 1 ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
    d.mipFilter = mip == 0 ? MTLSamplerMipFilterNotMipmapped : mip == 1 ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterLinear;
    if (min == 3 || mag == 3) d.maxAnisotropy = aniso < 1 ? 1 : aniso > 16 ? 16 : aniso;   /* D3DTEXF_ANISOTROPIC */
    d.lodMinClamp = (float)ss[9];                                             /* D3DSAMP_MAXMIPLEVEL: most detailed level used */
    if (compare) d.compareFunction = MTLCompareFunctionLessEqual;
    d.supportArgumentBuffers = YES;
    id<MTLSamplerState> s = [gp_mtl newSamplerStateWithDescriptor:d];
    smp_entry *n = calloc(1, sizeof *n);
    n->key = h; n->s = s; n->next = smp_list; smp_list = n;
    return s;
}

/* ------------------------------------------------------------- argument tables */
static id<MTL4ArgumentTable> vtable, ftable;
static void make_tables(void)
{
    if (vtable) return;
    MTL4ArgumentTableDescriptor *d = [MTL4ArgumentTableDescriptor new];
    d.maxBufferBindCount = 19; d.maxTextureBindCount = 16; d.maxSamplerStateBindCount = 16;
    d.supportAttributeStrides = YES; d.initializeBindings = YES;
    NSError *e = nil;
    vtable = [gp_mtl newArgumentTableWithDescriptor:d error:&e];
    ftable = [gp_mtl newArgumentTableWithDescriptor:d error:&e];
    if (!vtable || !ftable) gp_fatal("Metal argument table: %s", e.localizedDescription.UTF8String);
}

/* 1x1 texture for samplers a shader reads while D3D has nothing bound (D3D returns 0,0,0,1) */
static id<MTLTexture> null_tex[4];
static id<MTLTexture> null_texture(uint8_t type)
{
    if (null_tex[type]) return null_tex[type];
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = type == SM_TEX_CUBE ? MTLTextureTypeCube : type == SM_TEX_3D ? MTLTextureType3D : MTLTextureType2D;
    d.pixelFormat = type == SM_TEX_SHADOW2D ? MTLPixelFormatDepth32Float : MTLPixelFormatRGBA8Unorm;
    d.width = d.height = 1; d.depth = 1;
    d.storageMode = type == SM_TEX_SHADOW2D ? MTLStorageModePrivate : MTLStorageModeShared;
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [gp_mtl newTextureWithDescriptor:d];
    if (type != SM_TEX_SHADOW2D) {
        uint8_t px[4] = { 0, 0, 0, 255 };
        for (int f = 0; f < (type == SM_TEX_CUBE ? 6 : 1); f++)
            [t replaceRegion:MTLRegionMake3D(0, 0, 0, 1, 1, 1) mipmapLevel:0 slice:(NSUInteger)f withBytes:px bytesPerRow:4 bytesPerImage:4];
    }
    gp_residency_add(t);
    null_tex[type] = t;
    return t;
}

static uint8_t tex_type(uint32_t idx)
{
    gp_res *r = gp_res_at(idx);
    if (!r) return SM_TEX_2D;
    if (r->kind == R_CUBE) return SM_TEX_CUBE;
    if (r->kind == R_VOLUME) return SM_TEX_3D;
    if (r->fmt && r->fmt->depth) return SM_TEX_SHADOW2D;
    return SM_TEX_2D;
}

/* ------------------------------------------------------------- draw */
static MTLPrimitiveType prim(uint32_t t, uint32_t count, uint32_t *vertices)
{
    switch (t) {
    case 1: *vertices = count; return MTLPrimitiveTypePoint;
    case 2: *vertices = count * 2; return MTLPrimitiveTypeLine;
    case 3: *vertices = count + 1; return MTLPrimitiveTypeLineStrip;
    case 4: *vertices = count * 3; return MTLPrimitiveTypeTriangle;
    case 5: *vertices = count + 2; return MTLPrimitiveTypeTriangleStrip;
    case 6: *vertices = count + 2; return MTLPrimitiveTypeTriangle;      /* fan: converted to a list */
    }
    gp_fatal("primitive type %u", t);
}

typedef struct { uint64_t addr; uint32_t stride; } stream_bind;


/* GP_DRAW_TRACE=N logs the state of the first N draws */
static void trace_draw(const gp_vdecl *decl, const stream_bind *streams)
{
    static long left = -1;
    if (left < 0) left = getenv("GP_DRAW_TRACE") ? atol(getenv("GP_DRAW_TRACE")) : 0;
    extern volatile bool gp_trace_frame_active;
    if (!left && !gp_trace_frame_active) return;
    if (left) left--;
    gp_log("draw: vs %u ps %u fvf 0x%x vp %u,%u %ux%u z %.2f-%.2f rt0 %u ds %u blend %u (%u,%u) atest %u/%u ref %u zen %u cull %u cwrite 0x%x",
           D.vs, D.ps, D.fvf, D.viewport.x, D.viewport.y, D.viewport.w, D.viewport.h, D.viewport.minz, D.viewport.maxz,
           D.rt[0], D.ds, D.rs[27], D.rs[19], D.rs[20], D.rs[15], D.rs[25], D.rs[24], D.rs[7], D.rs[22], D.rs[168]);
    for (uint32_t i = 0; i < decl->n; i++)
        gp_log("  elem stream %u off %u type %u usage %u/%u", decl->e[i].stream, decl->e[i].offset, decl->e[i].type, decl->e[i].usage, decl->e[i].index);
    for (int s = 0; s < 2; s++) {
        gp_res *t = gp_res_at(D.textures[s]);
        if (t) gp_log("  tex%d kind %d fmt %u %ux%u levels %u  tss cop %u a1 %u a2 %u aop %u", s, t->kind, t->format, t->width, t->height, t->levels, D.tss[s][1], D.tss[s][2], D.tss[s][3], D.tss[s][4]);
        else gp_log("  tex%d none  tss cop %u a1 %u a2 %u aop %u", s, D.tss[s][1], D.tss[s][2], D.tss[s][3], D.tss[s][4]);
    }
    gp_res *vb = gp_res_at(D.streams[0].vb);
    if (vb && vb->sysmem) {
        const float *f = (const float *)G(vb->sysmem + D.streams[0].offset);
        uint32_t n = D.streams[0].stride / 4 > 8 ? 8 : D.streams[0].stride / 4;
        char line[256]; int o = 0;
        for (uint32_t k = 0; k < n * 2 && o < 240; k++) o += snprintf(line + o, sizeof line - (size_t)o, " %g", f[k]);
        gp_log("  vb0 stride %u:%s", D.streams[0].stride, line);
    }
    gp_log("  scissor %u (%d,%d,%d,%d) stencil %u func %u ref %u mask %x zfunc %u zwrite %u srgb %u fill %u clipplanes %x",
           D.rs[174], D.scissor.l, D.scissor.t, D.scissor.r, D.scissor.b, D.rs[52], D.rs[56], D.rs[57], D.rs[58], D.rs[23], D.rs[14], D.rs[194], D.rs[8], D.rs[152]);
    for (int c = 0; c < 4; c++) gp_log("  vs c%d = %g %g %g %g", c, D.vs_const[c][0], D.vs_const[c][1], D.vs_const[c][2], D.vs_const[c][3]);
    gp_res *vsr = gp_res_at(D.vs);
    if (vsr) {
        gp_shader *sh = vsr->priv;
        char line[512]; int o = 0;
        for (uint32_t k = 0; k < sh->words && k < 40 && o < 480; k++) o += snprintf(line + o, sizeof line - (size_t)o, " %08x", sh->code[k]);
        gp_log("  vs code:%s", line);
    }
    (void)streams;
}

static bool prepare(stream_bind *streams, uint32_t nstreams_user)
{
    (void)nstreams_user;
    make_tables();
    if (!D.enc || D.pass_invalid) gp_d3d9_begin_pass(false, 0, false, 0, false, 0);
    const gp_vdecl *decl = current_decl();

    /* ---- vertex shader and its inputs ---- */
    sm_key vk = {0};
    gp_res *vsr = gp_res_at(D.vs);
    id<MTLFunction> vs;
    pso_key pk = {0};
    uint32_t stream_used = 0;
    if (vsr) {
        sm_info vi;
        char err[128];
        gp_shader *sh = vsr->priv;
        if (!sm_scan(sh->code, sh->words, &vi, err, sizeof err)) gp_fatal("vertex shader: %s", err);
        for (int r = 0; r < 16; r++) {
            if (!(vi.input_mask & (1u << r))) continue;
            for (uint32_t i = 0; i < decl->n; i++)
                if (decl->e[i].usage == vi.usage[r] && decl->e[i].index == vi.usage_index[r]) {
                    vfmt f = decl_format(decl->e[i].type);
                    vk.input_class[r] = f.cls;
                    pk.attr_mask |= (uint16_t)(1u << r);
                    pk.attr_fmt[r] = f.fmt; pk.attr_stream[r] = (uint8_t)decl->e[i].stream; pk.attr_offset[r] = decl->e[i].offset;
                    stream_used |= 1u << decl->e[i].stream;
                    break;
                }
        }
        vk.clip_planes = (uint8_t)(D.rs[152] & 0x3f);
        vs = shader_variant(D.vs, &vk, NULL);
    } else {
        vs = gp_ff_vertex_function(decl, &pk.attr_mask, pk.attr_fmt, pk.attr_stream, pk.attr_offset, &stream_used);
    }
    /* ---- pixel shader ---- */
    sm_key pkk = {0};
    id<MTLFunction> ps;
    gp_res *psr = gp_res_at(D.ps);
    sm_info pinfo = {0};
    if (psr) {
        for (int s = 0; s < 16; s++) pkk.sampler_type[s] = tex_type(D.textures[s]);
        for (int s = 0; s < 8; s++) pkk.ps_texcoord_projected[s] = (D.tss[s][24] & 0x100) != 0;   /* D3DTTFF_PROJECTED */
        ps = shader_variant(D.ps, &pkk, &pinfo);
    } else {
        ps = gp_ff_fragment_function(&pinfo.sampler_mask);
    }
    /* ---- pipeline ---- */
    for (int i = 0; i < 4; i++) {
        gp_res *rt = gp_res_at(D.rt[i]);
        pk.color[i] = rt ? rt->tex.pixelFormat : MTLPixelFormatInvalid;
        pk.write[i] = i == 0 ? (D.rs[168] & 0xf) : (D.rs[189 + i] & 0xf);
    }
    gp_res *dsr = gp_res_at(D.ds);
    pk.depth = dsr ? dsr->tex.pixelFormat : MTLPixelFormatInvalid;
    pk.blend_enable = D.rs[27];
    if (pk.blend_enable) {
        pk.src = D.rs[19]; pk.dst = D.rs[20]; pk.op = D.rs[171];
        pk.sep = D.rs[206];
        if (pk.sep) { pk.src_a = D.rs[207]; pk.dst_a = D.rs[208]; pk.op_a = D.rs[209]; }
    }
    pk.stride_mask = stream_used;
    for (int s = 0; s < 16; s++)
        if ((stream_used & (1u << s)) && (D.streams[s].freq & 0x40000000u))              /* D3DSTREAMSOURCE_INSTANCEDATA */
            pk.stream_step[s] = D.streams[s].freq & 0x3fffffffu;
    pk.vs = (uintptr_t)(__bridge void *)vs; pk.ps = (uintptr_t)(__bridge void *)ps;
    [D.enc setRenderPipelineState:pipeline(&pk, vs, ps)];
    [D.enc setDepthStencilState:depth_state(dsr != NULL, dsr && dsr->fmt->stencil)];
    if (dsr && dsr->fmt->stencil && D.rs[52]) [D.enc setStencilReferenceValue:D.rs[57] & 0xff];

    /* ---- raster state ---- */
    [D.enc setFrontFacingWinding:MTLWindingClockwise];
    [D.enc setCullMode:D.rs[22] == 1 ? MTLCullModeNone : D.rs[22] == 2 ? MTLCullModeFront : MTLCullModeBack];   /* D3DCULL_CW culls clockwise = front */
    [D.enc setTriangleFillMode:D.rs[8] == 2 ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
    float bias, slope;
    memcpy(&bias, &D.rs[195], 4); memcpy(&slope, &D.rs[175], 4);
    [D.enc setDepthBias:bias * (dsr && dsr->format == D3DFMT_D16 ? 65535.0f : 16777215.0f) slopeScale:slope clamp:0];
    d3d_viewport vp = D.viewport;
    [D.enc setViewport:(MTLViewport){ vp.x, vp.y, vp.w, vp.h, vp.minz, vp.maxz }];
    if (D.rs[174]) {
        int32_t l = D.scissor.l < 0 ? 0 : D.scissor.l, t = D.scissor.t < 0 ? 0 : D.scissor.t;
        int32_t r = D.scissor.r > (int32_t)D.pass_w ? (int32_t)D.pass_w : D.scissor.r, b = D.scissor.b > (int32_t)D.pass_h ? (int32_t)D.pass_h : D.scissor.b;
        if (r <= l || b <= t) return false;                              /* empty scissor: nothing is drawn */
        [D.enc setScissorRect:(MTLScissorRect){ (NSUInteger)l, (NSUInteger)t, (NSUInteger)(r - l), (NSUInteger)(b - t) }];
    } else [D.enc setScissorRect:(MTLScissorRect){ 0, 0, D.pass_w, D.pass_h }];
    uint32_t bf = D.rs[193];
    [D.enc setBlendColorRed:((bf >> 16) & 255) / 255.0f green:((bf >> 8) & 255) / 255.0f blue:(bf & 255) / 255.0f alpha:(bf >> 24) / 255.0f];

    /* ---- vertex stage bindings ---- */
    for (int s = 0; s < 16; s++) {
        if (!(stream_used & (1u << s))) continue;
        if (!streams[s].addr) gp_fatal("draw reads vertex stream %d but nothing is bound", s);
        [vtable setAddress:streams[s].addr attributeStride:streams[s].stride atIndex:(NSUInteger)s];
    }
    if (vsr) {
        sm_vs_misc vm = {0};
        vm.pos_fixup[0] = 1.0f / (float)vp.w;                          /* D3D9 pixel centres: +0.5 px right, */
        vm.pos_fixup[1] = -1.0f / (float)vp.h;                         /* +0.5 px down */
        for (int i = 0; i < 6; i++) memcpy(vm.clip_planes[i], D.clip_planes[i], 16);
        [vtable setAddress:gp_transient(D.vs_const, sizeof D.vs_const, 256, NULL) atIndex:16];
        [vtable setAddress:gp_transient(&vm, sizeof vm, 256, NULL) atIndex:17];
        struct { int32_t i[16][4]; uint32_t b[16]; } ints;
        memcpy(ints.i, D.vs_const_i, sizeof ints.i); memcpy(ints.b, D.vs_const_b, sizeof ints.b);
        [vtable setAddress:gp_transient(&ints, sizeof ints, 256, NULL) atIndex:18];
    } else gp_ff_bind_vertex(vtable, (float)vp.x, (float)vp.y, (float)vp.w, (float)vp.h);
    [D.enc setArgumentTable:vtable atStages:MTLRenderStageVertex];

    /* ---- fragment stage bindings ---- */
    if (psr) {
        sm_ps_misc pm = {0};
        pm.alpha_ref = (float)(D.rs[24] & 0xff) / 255.0f;
        pm.alpha_func = D.rs[15] ? D.rs[25] : 8;
        pm.fog_mode = 0;
        if (D.rs[28]) {
            uint32_t table = D.rs[35];
            pm.fog_mode = table ? table : 4;                             /* table fog, else the vertex fog factor */
            memcpy(&pm.fog_start, &D.rs[36], 4); memcpy(&pm.fog_end, &D.rs[37], 4); memcpy(&pm.fog_density, &D.rs[38], 4);
            uint32_t fc = D.rs[34];
            pm.fog_color[0] = ((fc >> 16) & 255) / 255.0f; pm.fog_color[1] = ((fc >> 8) & 255) / 255.0f; pm.fog_color[2] = (fc & 255) / 255.0f; pm.fog_color[3] = 1;
        }
        for (int s = 0; s < 16; s++) memcpy(&pm.lod_bias[s], &D.ss[s][8], 4);
        for (int s = 0; s < 8; s++) for (int k = 0; k < 4; k++) memcpy(&pm.bumpenv[s][k], &D.tss[s][7 + k], 4);
        [ftable setAddress:gp_transient(D.ps_const, sizeof D.ps_const, 256, NULL) atIndex:0];
        [ftable setAddress:gp_transient(&pm, sizeof pm, 256, NULL) atIndex:1];
        struct { int32_t i[16][4]; uint32_t b[16]; } ints;
        memcpy(ints.i, D.ps_const_i, sizeof ints.i); memcpy(ints.b, D.ps_const_b, sizeof ints.b);
        [ftable setAddress:gp_transient(&ints, sizeof ints, 256, NULL) atIndex:2];
    } else gp_ff_bind_fragment(ftable);
    for (int s = 0; s < 16; s++) {
        if (!(pinfo.sampler_mask & (1u << s))) continue;
        gp_res *t = gp_res_at(D.textures[s]);
        uint8_t ty = psr ? (pinfo.sampler_dcl[s] != 255 ? pinfo.sampler_dcl[s] : pkk.sampler_type[s]) : tex_type(D.textures[s]);
        id<MTLTexture> mt = t && t->tex ? t->tex : null_texture(ty);
        [ftable setTexture:mt.gpuResourceID atIndex:(NSUInteger)s];
        [ftable setSamplerState:sampler(s, ty == SM_TEX_SHADOW2D).gpuResourceID atIndex:(NSUInteger)s];
    }
    [D.enc setArgumentTable:ftable atStages:MTLRenderStageFragment];
    trace_draw(decl, streams);
    D.pass_draws++;
    gp_d3d9_draws_total++;
    return true;
}

/* streams from the device state */
static void bind_streams(stream_bind *out)
{
    for (int s = 0; s < 16; s++) {
        gp_res *vb = gp_res_at(D.streams[s].vb);
        out[s] = (stream_bind){ vb ? gp_d3d9_buffer_gpu(vb) + D.streams[s].offset : 0, D.streams[s].stride };
    }
}

static uint32_t instances(void)
{
    uint32_t f = D.streams[0].freq;
    return (f & 0x80000000u) ? (f & 0x3fffffffu) : 1;                    /* D3DSTREAMSOURCE_INDEXEDDATA on stream 0 */
}

/* triangle fans become lists through generated indices */
static uint64_t fan_indices(uint32_t count, uint32_t first, uint32_t *n_out)
{
    uint32_t n = count * 3;
    uint32_t *ix;
    uint64_t a = gp_transient(NULL, 4 * n, 4, (void **)&ix);
    for (uint32_t i = 0; i < count; i++) { ix[3 * i] = first; ix[3 * i + 1] = first + i + 1; ix[3 * i + 2] = first + i + 2; }
    *n_out = n;
    return a;
}


/* ------------------------------------------------------------- per-draw magenta trace
   In a traced frame, after each draw the first render target is read back and pure-magenta pixels are counted;
   a draw that adds many is logged with its state. Debug only: it flushes the GPU after every draw. */
extern volatile bool gp_trace_frame_active;
extern const char *gp_fx_last_technique;
static uint32_t count_magenta(void)
{
    gp_res *rt = gp_res_at(D.rt[0]);
    if (!rt || !rt->tex || (rt->format != D3DFMT_A8R8G8B8 && rt->format != D3DFMT_X8R8G8B8)) return 0;
    uint32_t w = rt->width, h = rt->height;
    static id<MTLBuffer> buf;
    if (!buf || buf.length < (NSUInteger)w * h * 4) { buf = [gp_mtl newBufferWithLength:(NSUInteger)w * h * 4 options:MTLResourceStorageModeShared]; gp_residency_add(buf); }
    id<MTL4ComputeCommandEncoder> ce = gp_d3d9_blit_encoder();
    [ce copyFromTexture:rt->tex sourceSlice:rt->owner ? rt->face : 0 sourceLevel:rt->owner ? rt->level : 0 sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(w, h, 1) toBuffer:buf destinationOffset:0 destinationBytesPerRow:w * 4 destinationBytesPerImage:(NSUInteger)w * h * 4];
    [ce endEncoding];
    gp_d3d9_flush_and_wait();
    const uint8_t *p = buf.contents;
    uint32_t n = 0;
    for (size_t i = 0; i < (size_t)w * h; i++) if (p[4 * i] == 0xff && p[4 * i + 1] == 0 && p[4 * i + 2] == 0xff) n++;
    return n;
}
static uint32_t traced_draw(uint32_t (*impl)(gp_thread *), const char *name, gp_thread *t)
{
    static bool enabled = false, checked = false;
    if (!checked) { checked = true; enabled = getenv("GP_TRACE_MAGENTA_DRAW") != NULL; }
    if (!enabled || !gp_trace_frame_active) return impl(t);
    static uint32_t before;
    static uint64_t frame = ~0ull;
    if (frame != D.frame_serial) { frame = D.frame_serial; before = count_magenta(); }
    uint32_t r = impl(t);
    uint32_t after = count_magenta();
    if (after > before + 50) {
        gp_res *v = gp_res_at(D.vs), *p = gp_res_at(D.ps);
        gp_log("MAGENTA +%u pixels by %s: rt %u, technique \"%s\", vs %u (%s) ps %u (%s), blend %u src %u dst %u, fvf 0x%x", after - before, name, D.rt[0],
               gp_fx_last_technique, D.vs, v ? "shader" : "fixed", D.ps, p ? "shader" : "fixed", D.rs[27], D.rs[19], D.rs[20], D.fvf);
        if (getenv("GP_DUMP_SHADER_DIR")) {                       /* raw bytecode of the culprit shaders, for offline translation */
            for (int k = 0; k < 2; k++) {
                gp_res *sr = k ? p : v;
                if (!sr) continue;
                gp_shader *sh = sr->priv;
                char path[1200];
                snprintf(path, sizeof path, "%s/%s_%u.bin", getenv("GP_DUMP_SHADER_DIR"), k ? "ps" : "vs", k ? D.ps : D.vs);
                FILE *f = fopen(path, "wb");
                if (f) { fwrite(sh->code, 4, sh->words, f); fclose(f); }
            }
        }
        for (int s = 0; s < 8; s++) {
            gp_res *x = gp_res_at(D.textures[s]);
            if (x) {
                gp_log("  texture %d: kind %d %ux%u fmt 0x%x usage 0x%x pool %u levels %u mirror %s", s, x->kind, x->width, x->height, x->format, x->usage, x->pool, x->levels, x->sysmem ? "yes" : "none");
                if (x->tex && x->kind == R_TEXTURE && x->fmt && !x->fmt->convert16 && x->fmt->block == 1 && x->fmt->bytes_per_block == 4) {
                    /* what the GPU holds: the centre pixel of every mip level */
                    id<MTLBuffer> mb = [gp_mtl newBufferWithLength:4 * x->levels options:MTLResourceStorageModeShared];
                    gp_residency_add(mb);
                    id<MTL4ComputeCommandEncoder> ce = gp_d3d9_blit_encoder();
                    for (uint32_t lv = 0; lv < x->levels; lv++) {
                        uint32_t lw = x->width >> lv ? x->width >> lv : 1, lh = x->height >> lv ? x->height >> lv : 1;
                        [ce copyFromTexture:x->tex sourceSlice:0 sourceLevel:lv sourceOrigin:MTLOriginMake(lw / 2, lh / 2, 0) sourceSize:MTLSizeMake(1, 1, 1)
                                   toBuffer:mb destinationOffset:4 * lv destinationBytesPerRow:4 destinationBytesPerImage:4];
                    }
                    [ce endEncoding];
                    gp_d3d9_flush_and_wait();
                    char line[200]; int o = 0;
                    for (uint32_t lv = 0; lv < x->levels; lv++) o += snprintf(line + o, sizeof line - (size_t)o, " %08x", ((const uint32_t *)mb.contents)[lv]);
                    gp_log("    GPU centre pixel per mip level:%s", line);
                    gp_residency_remove(mb);
                }
                if (x->sysmem && x->fmt && !x->fmt->convert16 && x->fmt->block == 1) {       /* a few level-0 pixels: corners, centre */
                    uint32_t bpp = x->fmt->bytes_per_block, idx[5] = { 0, x->width - 1, (x->height / 2) * x->width + x->width / 2, (x->height - 1) * x->width, x->width * x->height - 1 };
                    char line[160]; int o = 0;
                    for (int k = 0; k < 5; k++) { uint32_t px = 0; memcpy(&px, G(x->sysmem + idx[k] * bpp), bpp < 4 ? bpp : 4); o += snprintf(line + o, sizeof line - (size_t)o, " %08x", px); }
                    gp_log("    level 0 pixels (corners, centre):%s", line);
                }
            }
        }
    }
    before = after;
    return r;
}

static uint32_t DrawPrimitive_impl(gp_thread *t)
{
    /* (this, type, StartVertex, PrimitiveCount) */
    uint32_t type = A(1), start = A(2), count = A(3), nv;
    if (!count) return D3D_OK;
    MTLPrimitiveType pt = prim(type, count, &nv);
    stream_bind s[16];
    bind_streams(s);
    if (!prepare(s, 0)) return D3D_OK;
    if (type == 6) {
        uint32_t n;
        uint64_t ib = fan_indices(count, start, &n);
        [D.enc drawIndexedPrimitives:pt indexCount:n indexType:MTLIndexTypeUInt32 indexBuffer:ib indexBufferLength:4 * n];
    } else [D.enc drawPrimitives:pt vertexStart:start vertexCount:nv instanceCount:instances()];
    return D3D_OK;
}

static uint32_t DrawIndexedPrimitive_impl(gp_thread *t)
{
    /* (this, type, BaseVertexIndex, MinVertexIndex, NumVertices, startIndex, primCount) */
    uint32_t type = A(1), count = A(6), start = A(5), nv;
    int32_t base = (int32_t)A(2);
    if (!count) return D3D_OK;
    gp_res *ib = gp_res_at(D.indices);
    if (!ib) gp_fatal("DrawIndexedPrimitive without an index buffer");
    MTLPrimitiveType pt = prim(type, count, &nv);
    uint32_t isize = ib->format == D3DFMT_INDEX32 ? 4 : 2;
    stream_bind s[16];
    bind_streams(s);
    if (!prepare(s, 0)) return D3D_OK;
    uint64_t addr = gp_d3d9_buffer_gpu(ib) + (uint64_t)start * isize;
    if (type == 6) {
        /* indexed fan: expand the fan through the index buffer contents */
        uint32_t *ix; uint32_t n = count * 3;
        uint64_t a = gp_transient(NULL, 4 * n, 4, (void **)&ix);
        const uint8_t *src = G(ib->sysmem + start * isize);
        for (uint32_t i = 0; i < count; i++) {
            uint32_t v[3];
            uint32_t k[3] = { 0, i + 1, i + 2 };
            for (int j = 0; j < 3; j++) v[j] = isize == 4 ? ((const uint32_t *)src)[k[j]] : ((const uint16_t *)src)[k[j]];
            ix[3 * i] = v[0]; ix[3 * i + 1] = v[1]; ix[3 * i + 2] = v[2];
        }
        [D.enc drawIndexedPrimitives:pt indexCount:n indexType:MTLIndexTypeUInt32 indexBuffer:a indexBufferLength:4 * n
                       instanceCount:instances() baseVertex:base baseInstance:0];
        return D3D_OK;
    }
    [D.enc drawIndexedPrimitives:pt indexCount:nv indexType:isize == 4 ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16
                     indexBuffer:addr indexBufferLength:ib->size - start * isize
                   instanceCount:instances() baseVertex:base baseInstance:0];
    extern volatile bool gp_trace_frame_active;
    if (gp_trace_frame_active) {
        const uint8_t *ix = G(ib->sysmem + start * isize);
        gp_log("  indexed: type %u count %u start %u base %d min %u nv %u; first indices %u %u %u",
               type, count, start, base, A(3), A(4), isize == 2 ? ((const uint16_t *)ix)[0] : ((const uint32_t *)ix)[0],
               isize == 2 ? ((const uint16_t *)ix)[1] : ((const uint32_t *)ix)[1], isize == 2 ? ((const uint16_t *)ix)[2] : ((const uint32_t *)ix)[2]);
        gp_d3d9_log_backbuffer_stats(D.frame_serial);
    }
    return D3D_OK;
}

static uint32_t DrawPrimitiveUP_impl(gp_thread *t)
{
    /* (this, type, PrimitiveCount, pVertexStreamZeroData, VertexStreamZeroStride) */
    uint32_t type = A(1), count = A(2), stride = A(4), nv;
    if (!count) return D3D_OK;
    MTLPrimitiveType pt = prim(type, count, &nv);
    stream_bind s[16] = {0};
    s[0] = (stream_bind){ gp_transient(G(A(3)), nv * stride, 16, NULL), stride };
    /* D3D: DrawPrimitiveUP unbinds stream 0 and the index buffer afterwards */
    gp_d3d9_bind(&D.streams[0].vb, 0);
    D.streams[0].offset = 0; D.streams[0].stride = 0;
    if (!prepare(s, 1)) return D3D_OK;
    if (type == 6) {
        uint32_t n;
        uint64_t ib = fan_indices(count, 0, &n);
        [D.enc drawIndexedPrimitives:pt indexCount:n indexType:MTLIndexTypeUInt32 indexBuffer:ib indexBufferLength:4 * n];
    } else [D.enc drawPrimitives:pt vertexStart:0 vertexCount:nv];
    return D3D_OK;
}

static uint32_t DrawIndexedPrimitiveUP_impl(gp_thread *t)
{
    /* (this, type, MinVertexIndex, NumVertices, PrimitiveCount, pIndexData, IndexDataFormat, pVertexStreamZeroData, stride) */
    uint32_t type = A(1), minv = A(2), numv = A(3), count = A(4), ifmt = A(6), stride = A(8), nv;
    if (!count) return D3D_OK;
    MTLPrimitiveType pt = prim(type, count, &nv);
    uint32_t isize = ifmt == D3DFMT_INDEX32 ? 4 : 2;
    stream_bind s[16] = {0};
    s[0] = (stream_bind){ gp_transient(G(A(7)), (minv + numv) * stride, 16, NULL), stride };
    gp_d3d9_bind(&D.streams[0].vb, 0);
    gp_d3d9_bind(&D.indices, 0);
    D.streams[0].offset = 0; D.streams[0].stride = 0;
    if (!prepare(s, 1)) return D3D_OK;
    if (type == 6) {
        uint32_t *ix; uint32_t n = count * 3;
        uint64_t a = gp_transient(NULL, 4 * n, 4, (void **)&ix);
        for (uint32_t i = 0; i < count; i++) {
            uint32_t k[3] = { 0, i + 1, i + 2 };
            for (int j = 0; j < 3; j++) ix[3 * i + (uint32_t)j] = isize == 4 ? rd32(A(5) + 4 * k[j]) : rd16(A(5) + 2 * k[j]);
        }
        [D.enc drawIndexedPrimitives:pt indexCount:n indexType:MTLIndexTypeUInt32 indexBuffer:a indexBufferLength:4 * n];
        return D3D_OK;
    }
    uint64_t ia = gp_transient(G(A(5)), nv * isize, 4, NULL);
    [D.enc drawIndexedPrimitives:pt indexCount:nv indexType:isize == 4 ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16
                     indexBuffer:ia indexBufferLength:nv * isize];
    return D3D_OK;
}

#undef DLL
#define DLL "IDirect3DDevice9"

/* ------------------------------------------------------------- StretchRect
   Colour surfaces: a filtered quad from a 2D view of the source level into the
   destination rectangle. Depth-stencil surfaces: a direct copy (D3D9 allows only
   whole, unscaled depth-stencil copies). */
static const char *blit_msl =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct BV { float4 pos [[position]]; float2 uv; };\n"
    "struct BU { float4 src; };\n"   /* u0 v0 u1 v1 */
    "vertex BV blit_vs(uint vid [[vertex_id]], constant BU &u [[buffer(0)]]) {\n"
    "    float2 t = float2((vid & 1) ? 1.0f : 0.0f, (vid & 2) ? 1.0f : 0.0f);\n"
    "    BV o; o.pos = float4(t.x * 2.0f - 1.0f, 1.0f - t.y * 2.0f, 0.0f, 1.0f); o.uv = mix(u.src.xy, u.src.zw, t); return o; }\n"
    "fragment float4 blit_fs(BV in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "    return tex.sample(s, in.uv); }\n";

typedef struct blit_entry { MTLPixelFormat fmt; id<MTLRenderPipelineState> p; struct blit_entry *next; } blit_entry;
static blit_entry *blit_psos;

static id<MTLRenderPipelineState> blit_pipeline(MTLPixelFormat fmt)
{
    static id<MTLFunction> v, f;
    for (blit_entry *e = blit_psos; e; e = e->next) if (e->fmt == fmt) return e->p;
    if (!v) {
        NSError *e = nil;
        id<MTLLibrary> lib = [gp_mtl newLibraryWithSource:@(blit_msl) options:nil error:&e];
        v = [lib newFunctionWithName:@"blit_vs"]; f = [lib newFunctionWithName:@"blit_fs"];
        if (!v || !f) gp_fatal("StretchRect shader compile failed: %s", e.localizedDescription.UTF8String);
    }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = v; d.fragmentFunction = f;
    d.colorAttachments[0].pixelFormat = fmt;
    NSError *e = nil;
    id<MTLRenderPipelineState> p = [gp_mtl newRenderPipelineStateWithDescriptor:d error:&e];
    if (!p) gp_fatal("StretchRect pipeline creation failed: %s", e.localizedDescription.UTF8String);
    blit_entry *n = calloc(1, sizeof *n);
    if (!n) gp_fatal("out of memory");
    n->fmt = fmt; n->p = p; n->next = blit_psos; blit_psos = n;
    return p;
}

static bool read_rect(gaddr a, const gp_res *r, int32_t *l, int32_t *t, int32_t *rt, int32_t *b)
{
    if (!a) { *l = 0; *t = 0; *rt = (int32_t)r->width; *b = (int32_t)r->height; return true; }
    *l = (int32_t)rd32(a); *t = (int32_t)rd32(a + 4); *rt = (int32_t)rd32(a + 8); *b = (int32_t)rd32(a + 12);
    return *l >= 0 && *t >= 0 && *rt > *l && *b > *t && *rt <= (int32_t)r->width && *b <= (int32_t)r->height;
}

static uint32_t StretchRect_(gp_thread *t)
{
    /* (this, pSourceSurface, pSourceRect, pDestSurface, pDestRect, Filter) */
    gp_res *src = gp_res_get(A(1), R_SURFACE), *dst = gp_res_get(A(3), R_SURFACE);
    uint32_t filter = A(5);
    int32_t sl, st, sr, sb, dl, dt, dr, db;
    if (!src->tex || !dst->tex) return D3DERR_INVALIDCALL;
    if (!read_rect(A(2), src, &sl, &st, &sr, &sb) || !read_rect(A(4), dst, &dl, &dt, &dr, &db)) return D3DERR_INVALIDCALL;
    uint32_t slevel = src->owner ? src->level : 0, sface = src->owner ? src->face : 0;
    uint32_t dlevel = dst->owner ? dst->level : 0, dface = dst->owner ? dst->face : 0;
    if (src->fmt->depth || dst->fmt->depth) {
        if (!src->fmt->depth || !dst->fmt->depth || src->format != dst->format || A(2) || A(4) ||
            src->width != dst->width || src->height != dst->height) return D3DERR_INVALIDCALL;
        id<MTL4ComputeCommandEncoder> ce = gp_d3d9_blit_encoder();
        [ce copyFromTexture:src->tex sourceSlice:sface sourceLevel:slevel sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(src->width, src->height, 1) toTexture:dst->tex destinationSlice:dface
           destinationLevel:dlevel destinationOrigin:MTLOriginMake(0, 0, 0)];
        [ce endEncoding];
        return D3D_OK;
    }
    if (filter > 2) gp_fatal("StretchRect filter %u", filter);
    if (!(dst->tex.usage & MTLTextureUsageRenderTarget)) gp_fatal("StretchRect into a surface that is not a render target (format %u)", dst->format);
    make_tables();
    gp_d3d9_begin_frame();
    gp_d3d9_end_pass();
    /* 2D view of the one source level/face; released once the GPU is done with this frame */
    id<MTLTexture> view = [src->tex newTextureViewWithPixelFormat:src->tex.pixelFormat textureType:MTLTextureType2D
                                                             levels:NSMakeRange(slevel, 1) slices:NSMakeRange(sface, 1)];
    if (!view) gp_fatal("StretchRect: cannot create a source texture view");
    gp_residency_add(view);
    gp_d3d9_release_texture_later(view);
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = dst->tex;
    rp.colorAttachments[0].level = dlevel;
    rp.colorAttachments[0].slice = dface;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTL4RenderCommandEncoder> enc = [D.cmd renderCommandEncoderWithDescriptor:rp];
    if (!enc) gp_fatal("Metal: cannot open the StretchRect pass");
    GP_SYNC_BARRIER(enc);
    [enc setRenderPipelineState:blit_pipeline(dst->tex.pixelFormat)];
    [enc setViewport:(MTLViewport){ dl, dt, dr - dl, db - dt, 0, 1 }];
    [enc setScissorRect:(MTLScissorRect){ (NSUInteger)dl, (NSUInteger)dt, (NSUInteger)(dr - dl), (NSUInteger)(db - dt) }];
    float sw = (float)src->width, sh = (float)src->height;
    float u[4] = { sl / sw, st / sh, sr / sw, sb / sh };
    [vtable setAddress:gp_transient(u, sizeof u, 256, NULL) atIndex:0];
    static id<MTLSamplerState> smp[2];
    int lin = filter == 2;
    if (!smp[lin]) {
        MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
        d.minFilter = d.magFilter = lin ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        d.sAddressMode = d.tAddressMode = MTLSamplerAddressModeClampToEdge;
        d.supportArgumentBuffers = YES;
        smp[lin] = [gp_mtl newSamplerStateWithDescriptor:d];
    }
    [ftable setTexture:view.gpuResourceID atIndex:0];
    [ftable setSamplerState:smp[lin].gpuResourceID atIndex:0];
    [enc setArgumentTable:vtable atStages:MTLRenderStageVertex];
    [enc setArgumentTable:ftable atStages:MTLRenderStageFragment];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [enc endEncoding];
    D.pass_invalid = true;
    return D3D_OK;
}

static uint32_t DrawPrimitive_(gp_thread *t) { return traced_draw(DrawPrimitive_impl, "DrawPrimitive", t); }
static uint32_t DrawIndexedPrimitive_(gp_thread *t) { return traced_draw(DrawIndexedPrimitive_impl, "DrawIndexedPrimitive", t); }
static uint32_t DrawPrimitiveUP_(gp_thread *t) { return traced_draw(DrawPrimitiveUP_impl, "DrawPrimitiveUP", t); }
static uint32_t DrawIndexedPrimitiveUP_(gp_thread *t) { return traced_draw(DrawIndexedPrimitiveUP_impl, "DrawIndexedPrimitiveUP", t); }

const gp_api gp_api_idirect3ddevice9_draw[] = {
    API(StretchRect_, "StretchRect", 6),
    API(DrawPrimitive_, "DrawPrimitive", 4), API(DrawIndexedPrimitive_, "DrawIndexedPrimitive", 7),
    API(DrawPrimitiveUP_, "DrawPrimitiveUP", 5), API(DrawIndexedPrimitiveUP_, "DrawIndexedPrimitiveUP", 9),
    { 0 }
};

/* GP_D3D_SELFTEST: after device creation, clear to blue and draw a red pretransformed
   triangle over the left half through the guest-facing entry points, logging
   back-buffer statistics after each step. */
void gp_d3d9_selftest(gp_thread *t)
{
    if (!getenv("GP_D3D_SELFTEST")) return;
    gaddr scratch = gp_heap_alloc(256, true), verts = gp_heap_alloc(3 * 20, true);
    if (!scratch || !verts) gp_fatal("selftest: out of guest memory");
    uint32_t saved_esp = t->cpu._esp;
    t->cpu._esp = scratch;
    /* Clear(this, 0, NULL, D3DCLEAR_TARGET, blue, 1.0, 0) */
    float one = 1.0f; uint32_t onebits; memcpy(&onebits, &one, 4);
    uint32_t cargs[7] = { 0, 0, 0, 1, 0xff0000ff, onebits, 0 };
    for (int i = 0; i < 7; i++) wr32(scratch + 4 + 4 * (uint32_t)i, cargs[i]);
    extern const gp_api gp_api_idirect3ddevice9_core[];
    gp_api_fn clear = NULL, present = NULL;
    for (const gp_api *a = gp_api_idirect3ddevice9_core; a->name; a++) {
        if (!strcmp(a->name, "Clear")) clear = a->fn;
        if (!strcmp(a->name, "Present")) present = a->fn;
    }
    if (!clear || !present) gp_fatal("selftest: Clear/Present entry points not found");
    clear(t);
    gp_d3d9_flush_and_wait();
    gp_d3d9_log_backbuffer_stats(1);
    /* red triangle: XYZRHW | DIFFUSE */
    float v[3][4] = { { 0, 0, 0.5f, 1 }, { 320, 0, 0.5f, 1 }, { 0, 480, 0.5f, 1 } };
    for (int i = 0; i < 3; i++) { memcpy(G(verts + 20 * (uint32_t)i), v[i], 16); wr32(verts + 20 * (uint32_t)i + 16, 0xffff0000u); }
    gp_d3d9_bind(&D.vs, 0); gp_d3d9_bind(&D.ps, 0); gp_d3d9_bind(&D.vdecl, 0);
    D.fvf = 0x004 | 0x040;
    D.tss[0][1] = 2; D.tss[0][2] = 0; D.tss[0][4] = 2; D.tss[0][5] = 0; D.tss[1][1] = 1;   /* SELECTARG1 diffuse */
    D.rs[7] = 0; D.rs[27] = 0; D.rs[15] = 0; D.rs[22] = 1; D.rs[168] = 0xf; D.rs[28] = 0;
    uint32_t dargs[4] = { 4 /* TRIANGLELIST */, 1, verts, 20 };
    wr32(scratch + 4, 0);
    for (int i = 0; i < 4; i++) wr32(scratch + 8 + 4 * (uint32_t)i, dargs[i]);
    DrawPrimitiveUP_(t);
    gp_d3d9_flush_and_wait();
    gp_d3d9_log_backbuffer_stats(2);
    /* partial clear: green over the right half */
    wr32(verts, 320); wr32(verts + 4, 0); wr32(verts + 8, 640); wr32(verts + 12, 480);
    gp_d3d9_clear_rects(1, verts, 1, 0xff00ff00u, 1.0f, 0);
    gp_d3d9_flush_and_wait();
    gp_d3d9_log_backbuffer_stats(3);
    t->cpu._esp = saved_esp;
    gp_heap_free(scratch); gp_heap_free(verts);
    gp_fatal("GP_D3D_SELFTEST finished");
}

/* ------------------------------------------------------------- partial clears
   Clear limited to rectangles, the viewport or the scissor rectangle: a quad per
   rectangle that writes colour (through COLORWRITEENABLE), depth and stencil. */
static const char *clear_msl =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct CV { float4 pos [[position]]; };\n"
    "struct CU { float4 color; float z; };\n"
    "vertex CV clear_vs(uint vid [[vertex_id]], constant CU &u [[buffer(0)]]) {\n"
    "    float2 p = float2((vid & 1) ? 1.0f : -1.0f, (vid & 2) ? -1.0f : 1.0f);\n"
    "    CV o; o.pos = float4(p, u.z, 1.0f); return o; }\n"
    "struct CF { float4 c0 [[color(0)]]; float4 c1 [[color(1)]]; float4 c2 [[color(2)]]; float4 c3 [[color(3)]]; };\n"
    "fragment CF clear_fs(constant CU &u [[buffer(0)]]) { CF o; o.c0 = o.c1 = o.c2 = o.c3 = u.color; return o; }\n";

typedef struct { MTLPixelFormat color[4], depth; uint32_t mask[4]; } clear_key;
typedef struct clear_entry { clear_key k; id<MTLRenderPipelineState> p; struct clear_entry *next; } clear_entry;
static clear_entry *clear_psos;
static id<MTLFunction> clear_v, clear_f;

static id<MTLRenderPipelineState> clear_pipeline(const clear_key *k)
{
    for (clear_entry *e = clear_psos; e; e = e->next) if (!memcmp(&e->k, k, sizeof *k)) return e->p;
    if (!clear_v) {
        NSError *e = nil;
        id<MTLLibrary> lib = [gp_mtl newLibraryWithSource:@(clear_msl) options:nil error:&e];
        clear_v = [lib newFunctionWithName:@"clear_vs"]; clear_f = [lib newFunctionWithName:@"clear_fs"];
        if (!clear_v || !clear_f) gp_fatal("clear shader compile failed: %s", e.localizedDescription.UTF8String);
    }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = clear_v; d.fragmentFunction = clear_f;
    for (int i = 0; i < 4; i++) {
        if (!k->color[i]) continue;
        d.colorAttachments[i].pixelFormat = k->color[i];
        uint32_t m = k->mask[i];
        d.colorAttachments[i].writeMask = ((m & 1) ? MTLColorWriteMaskRed : 0) | ((m & 2) ? MTLColorWriteMaskGreen : 0) |
                                          ((m & 4) ? MTLColorWriteMaskBlue : 0) | ((m & 8) ? MTLColorWriteMaskAlpha : 0);
    }
    if (k->depth) { d.depthAttachmentPixelFormat = k->depth; d.stencilAttachmentPixelFormat = k->depth; }
    NSError *e = nil;
    id<MTLRenderPipelineState> p = [gp_mtl newRenderPipelineStateWithDescriptor:d error:&e];
    if (!p) gp_fatal("clear pipeline creation failed: %s", e.localizedDescription.UTF8String);
    clear_entry *n = calloc(1, sizeof *n);
    if (!n) gp_fatal("out of memory");
    n->k = *k; n->p = p; n->next = clear_psos; clear_psos = n;
    return p;
}

static id<MTLDepthStencilState> clear_depth_state(bool depth, bool stencil)
{
    static id<MTLDepthStencilState> s[4];
    int i = (depth ? 1 : 0) | (stencil ? 2 : 0);
    if (s[i]) return s[i];
    MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
    d.depthCompareFunction = MTLCompareFunctionAlways;
    d.depthWriteEnabled = depth;
    if (stencil) {
        MTLStencilDescriptor *f = [MTLStencilDescriptor new];
        f.stencilCompareFunction = MTLCompareFunctionAlways;
        f.depthStencilPassOperation = MTLStencilOperationReplace;
        f.readMask = 0xff; f.writeMask = 0xff;
        d.frontFaceStencil = f; d.backFaceStencil = f;
    }
    s[i] = [gp_mtl newDepthStencilStateWithDescriptor:d];
    return s[i];
}

uint32_t gp_d3d9_clear_rects(uint32_t count, gaddr rects, uint32_t flags, uint32_t color, float z, uint32_t stencil)
{
    bool c = flags & 1, d = flags & 2, s = flags & 4;
    gp_res *dsr = gp_res_at(D.ds);
    if ((d || s) && !dsr) return D3DERR_INVALIDCALL;
    if (s && !dsr->fmt->stencil) return D3DERR_INVALIDCALL;
    if (count && !rects) return D3DERR_INVALIDCALL;
    make_tables();
    if (!D.enc || D.pass_invalid) gp_d3d9_begin_pass(false, 0, false, 0, false, 0);
    clear_key k = {0};
    for (int i = 0; i < 4; i++) {
        gp_res *rt = gp_res_at(D.rt[i]);
        k.color[i] = rt ? rt->tex.pixelFormat : MTLPixelFormatInvalid;
        k.mask[i] = c ? (i == 0 ? (D.rs[168] & 0xf) : (D.rs[189 + i] & 0xf)) : 0;
    }
    k.depth = dsr ? dsr->tex.pixelFormat : MTLPixelFormatInvalid;
    [D.enc setRenderPipelineState:clear_pipeline(&k)];
    [D.enc setDepthStencilState:clear_depth_state(d, s)];
    if (s) [D.enc setStencilReferenceValue:stencil & 0xff];
    [D.enc setCullMode:MTLCullModeNone];
    [D.enc setTriangleFillMode:MTLTriangleFillModeFill];
    [D.enc setDepthBias:0 slopeScale:0 clamp:0];
    [D.enc setViewport:(MTLViewport){ 0, 0, D.pass_w, D.pass_h, 0, 1 }];
    struct { float color[4]; float z; float pad[3]; } u = {
        { ((color >> 16) & 255) / 255.0f, ((color >> 8) & 255) / 255.0f, (color & 255) / 255.0f, (color >> 24) / 255.0f },
        z < 0 ? 0 : z > 1 ? 1 : z, { 0 } };
    uint64_t ua = gp_transient(&u, sizeof u, 256, NULL);
    [vtable setAddress:ua atIndex:0];
    [ftable setAddress:ua atIndex:0];
    [D.enc setArgumentTable:vtable atStages:MTLRenderStageVertex];
    [D.enc setArgumentTable:ftable atStages:MTLRenderStageFragment];
    /* the cleared area: each rectangle (or the whole target) within the viewport and, if enabled, the scissor */
    int32_t vl = (int32_t)D.viewport.x, vt = (int32_t)D.viewport.y, vr = vl + (int32_t)D.viewport.w, vb = vt + (int32_t)D.viewport.h;
    if (D.rs[174]) {
        if (D.scissor.l > vl) vl = D.scissor.l;
        if (D.scissor.t > vt) vt = D.scissor.t;
        if (D.scissor.r < vr) vr = D.scissor.r;
        if (D.scissor.b < vb) vb = D.scissor.b;
    }
    if (vr > (int32_t)D.pass_w) vr = (int32_t)D.pass_w;
    if (vb > (int32_t)D.pass_h) vb = (int32_t)D.pass_h;
    if (vl < 0) vl = 0;
    if (vt < 0) vt = 0;
    uint32_t n = count ? count : 1;
    for (uint32_t i = 0; i < n; i++) {
        int32_t l = vl, t = vt, r = vr, b = vb;
        if (count) {
            gaddr rc = rects + 16 * i;
            int32_t x1 = (int32_t)rd32(rc), y1 = (int32_t)rd32(rc + 4), x2 = (int32_t)rd32(rc + 8), y2 = (int32_t)rd32(rc + 12);
            if (x1 > l) l = x1;
            if (y1 > t) t = y1;
            if (x2 < r) r = x2;
            if (y2 < b) b = y2;
        }
        if (r <= l || b <= t) continue;
        [D.enc setScissorRect:(MTLScissorRect){ (NSUInteger)l, (NSUInteger)t, (NSUInteger)(r - l), (NSUInteger)(b - t) }];
        [D.enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    return D3D_OK;
}
