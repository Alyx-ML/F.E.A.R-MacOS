/* IDirect3DDevice9 state storage, defaults, transient memory, interface vtables, diagnostics. */
#import <Metal/Metal.h>
#include "gp_d3d9_state.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static uint32_t fbits(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }

void gp_d3d9_state_defaults(void)
{
    uint32_t *rs = D.rs;
    memset(rs, 0, sizeof D.rs);
    rs[7] = D.auto_depth ? 1 : 0; rs[8] = 3; rs[9] = 2; rs[14] = 1; rs[16] = 1; rs[19] = 2; rs[20] = 1; rs[22] = 3;
    rs[23] = 4; rs[25] = 8; rs[37] = fbits(1.0f); rs[38] = fbits(1.0f);
    rs[53] = rs[54] = rs[55] = 1; rs[56] = 8; rs[58] = rs[59] = 0xffffffffu; rs[60] = 0xffffffffu;
    rs[136] = 1; rs[137] = 1; rs[141] = 1; rs[142] = 1; rs[145] = 1; rs[146] = 2;
    rs[154] = rs[155] = fbits(1.0f); rs[158] = fbits(1.0f); rs[161] = 1; rs[162] = 0xffffffffu; rs[166] = fbits(64.0f);
    rs[168] = 0xf; rs[171] = 1; rs[172] = 3; rs[173] = 1; rs[178] = rs[179] = fbits(1.0f); rs[182] = fbits(1.0f);
    rs[186] = rs[187] = rs[188] = 1; rs[189] = 8; rs[190] = rs[191] = rs[192] = 0xf; rs[193] = 0xffffffffu;
    rs[207] = 2; rs[208] = 1; rs[209] = 1;
    for (int s = 0; s < 21; s++) {
        memset(D.ss[s], 0, sizeof D.ss[s]);
        D.ss[s][1] = D.ss[s][2] = D.ss[s][3] = 1; D.ss[s][5] = D.ss[s][6] = 1; D.ss[s][10] = 1;
    }
    for (int s = 0; s < 8; s++) {
        memset(D.tss[s], 0, sizeof D.tss[s]);
        D.tss[s][1] = s ? 1 : 4; D.tss[s][2] = 2; D.tss[s][4] = s ? 1 : 2; D.tss[s][5] = 2; D.tss[s][11] = (uint32_t)s;
        D.tss[s][26] = 1; D.tss[s][27] = 1;                    /* COLORARG0/ALPHAARG0/RESULTARG = CURRENT */
    }
    for (int i = 0; i < 512; i++) { memset(D.transforms[i], 0, 64); D.transforms[i][0] = D.transforms[i][5] = D.transforms[i][10] = D.transforms[i][15] = 1.0f; }
    memset(D.textures, 0, sizeof D.textures);
    memset(D.streams, 0, sizeof D.streams);
    for (int i = 0; i < 16; i++) D.streams[i].freq = 1;
    D.vs = D.ps = D.vdecl = D.fvf = D.indices = 0;
}

/* ---------------------------------------------------------- transient memory */
#define CHUNK (64u << 20)
typedef struct { id<MTLBuffer> buf; uint32_t used; } chunk;
static chunk frame_chunks[FRAMES][8];
static int nchunks[FRAMES];

/* textures released by the game stay alive until the GPU finished the frames that used them */
typedef struct { __strong id<MTLTexture> tex; uint64_t after; } dead_tex;
static dead_tex dead[4096];
static int ndead;

void gp_d3d9_release_texture_later(id<MTLTexture> tex)
{
    if (ndead == 4096) gp_d3d9_flush_and_wait();
    uint64_t done = D.frame_event.signaledValue;
    for (int i = 0; i < ndead;) {
        if (dead[i].after <= done) { gp_residency_remove(dead[i].tex); dead[i] = dead[--ndead]; dead[ndead].tex = nil; }
        else i++;
    }
    if (ndead == 4096) gp_fatal("texture release queue full");
    dead[ndead++] = (dead_tex){ tex, D.frame_serial + (D.recording ? 1 : 0) };
}

void gp_d3d9_frame_begin(void)
{
    int f = (int)(D.frame_serial % FRAMES);
    for (int i = 0; i < nchunks[f]; i++) frame_chunks[f][i].used = 0;
}

id<MTLBuffer> gp_transient_buffer(const void *cpu, uint32_t *offset)
{
    int f = (int)(D.frame_serial % FRAMES);
    for (int i = 0; i < nchunks[f]; i++) {
        const uint8_t *base = frame_chunks[f][i].buf.contents;
        if ((const uint8_t *)cpu >= base && (const uint8_t *)cpu < base + CHUNK) { *offset = (uint32_t)((const uint8_t *)cpu - base); return frame_chunks[f][i].buf; }
    }
    gp_fatal("pointer is not transient GPU memory");
}
void gp_d3d9_frame_end(void) {}

/* device destruction: transient chunks go with the residency set they were added to */
void gp_d3d9_state_release(void)
{
    for (int f = 0; f < FRAMES; f++) { for (int i = 0; i < nchunks[f]; i++) frame_chunks[f][i].buf = nil; nchunks[f] = 0; }
    for (int i = 0; i < ndead; i++) dead[i].tex = nil;
    ndead = 0;
}
void gp_d3d9_pass_opened(void) { D.pass_invalid = false; }

uint64_t gp_transient(const void *data, uint32_t size, uint32_t align, void **cpu)
{
    gp_d3d9_begin_frame();                      /* opening a frame recycles its chunks: do it before allocating */
    int f = (int)(D.frame_serial % FRAMES);
    for (int i = 0;; i++) {
        if (i == nchunks[f]) {
            if (i == 8) gp_fatal("more than 512 MiB of per-frame transient GPU data");
            id<MTLBuffer> b = [gp_mtl newBufferWithLength:CHUNK options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
            if (!b) gp_fatal("Metal: cannot allocate transient buffer");
            gp_residency_add(b);
            frame_chunks[f][nchunks[f]++] = (chunk){ b, 0 };
        }
        chunk *c = &frame_chunks[f][i];
        uint32_t off = (c->used + align - 1) & ~(align - 1);
        if (off + size > CHUNK) continue;
        c->used = off + size;
        uint8_t *p = (uint8_t *)c->buf.contents + off;
        if (data) memcpy(p, data, size);
        if (cpu) *cpu = p;
        return c->buf.gpuAddress + off;
    }
}

/* ---------------------------------------------------------- simple setters */
uint32_t gp_dev_set_rs(uint32_t state, uint32_t value)
{
    if (state >= 256) return D3DERR_INVALIDCALL;
    D.rs[state] = value;
    return D3D_OK;
}
static uint32_t SetRenderState_(gp_thread *t) { return gp_dev_set_rs(A(1), A(2)); }
static uint32_t GetRenderState_(gp_thread *t) { if (A(1) >= 256) return D3DERR_INVALIDCALL; wr32(A(2), D.rs[A(1)]); return D3D_OK; }

static int sampler_slot(uint32_t s)
{
    if (s < 16) return (int)s;
    if (s == 256) return 16;                                   /* D3DDMAPSAMPLER */
    if (s >= 257 && s <= 260) return (int)(s - 257 + 17);      /* D3DVERTEXTEXTURESAMPLER0..3 */
    return -1;
}
uint32_t gp_dev_set_ss(uint32_t sampler, uint32_t type, uint32_t value)
{
    int s = sampler_slot(sampler);
    if (s < 0 || type >= 14) return D3DERR_INVALIDCALL;
    D.ss[s][type] = value;
    return D3D_OK;
}
uint32_t gp_dev_get_ss(uint32_t sampler, uint32_t type)
{
    int s = sampler_slot(sampler);
    return s < 0 || type >= 14 ? 0 : D.ss[s][type];
}
static uint32_t SetSamplerState_(gp_thread *t) { return gp_dev_set_ss(A(1), A(2), A(3)); }
static uint32_t GetSamplerState_(gp_thread *t)
{
    int s = sampler_slot(A(1));
    if (s < 0 || A(2) >= 14) return D3DERR_INVALIDCALL;
    wr32(A(3), D.ss[s][A(2)]);
    return D3D_OK;
}
uint32_t gp_dev_set_tss(uint32_t stage, uint32_t type, uint32_t value)
{
    if (stage >= 8 || type >= 33) return D3DERR_INVALIDCALL;
    D.tss[stage][type] = value;
    return D3D_OK;
}
static uint32_t SetTextureStageState_(gp_thread *t) { return gp_dev_set_tss(A(1), A(2), A(3)); }
static uint32_t GetTextureStageState_(gp_thread *t) { if (A(1) >= 8 || A(2) >= 33) return D3DERR_INVALIDCALL; wr32(A(3), D.tss[A(1)][A(2)]); return D3D_OK; }

uint32_t gp_dev_set_transform(uint32_t state, const float *m)
{
    if (state >= 512) return D3DERR_INVALIDCALL;
    memcpy(D.transforms[state], m, 64);
    return D3D_OK;
}
static uint32_t SetTransform_(gp_thread *t) { return gp_dev_set_transform(A(1), G(A(2))); }
static uint32_t GetTransform_(gp_thread *t) { if (A(1) >= 512) return D3DERR_INVALIDCALL; memcpy(G(A(2)), D.transforms[A(1)], 64); return D3D_OK; }
static uint32_t MultiplyTransform_(gp_thread *t)
{
    if (A(1) >= 512) return D3DERR_INVALIDCALL;
    float m[16], r[16];
    memcpy(m, G(A(2)), 64);
    float *a = D.transforms[A(1)];
    for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) {
        float s = 0; for (int k = 0; k < 4; k++) s += a[i * 4 + k] * m[k * 4 + j];
        r[i * 4 + j] = s;
    }
    memcpy(a, r, 64);
    return D3D_OK;
}

static uint32_t SetViewport_(gp_thread *t)
{
    gaddr v = A(1);
    d3d_viewport vp;
    vp.x = rd32(v); vp.y = rd32(v + 4); vp.w = rd32(v + 8); vp.h = rd32(v + 12);
    memcpy(&vp.minz, G(v + 16), 4); memcpy(&vp.maxz, G(v + 20), 4);
    D.viewport = vp;
    return D3D_OK;
}
static uint32_t GetViewport_(gp_thread *t)
{
    gaddr v = A(1);
    wr32(v, D.viewport.x); wr32(v + 4, D.viewport.y); wr32(v + 8, D.viewport.w); wr32(v + 12, D.viewport.h);
    memcpy(G(v + 16), &D.viewport.minz, 4); memcpy(G(v + 20), &D.viewport.maxz, 4);
    return D3D_OK;
}
static uint32_t SetScissorRect_(gp_thread *t)
{
    gaddr r = A(1);
    D.scissor = (d3d_rect){ (int32_t)rd32(r), (int32_t)rd32(r + 4), (int32_t)rd32(r + 8), (int32_t)rd32(r + 12) };
    return D3D_OK;
}
static uint32_t GetScissorRect_(gp_thread *t)
{
    gaddr r = A(1);
    wr32(r, (uint32_t)D.scissor.l); wr32(r + 4, (uint32_t)D.scissor.t); wr32(r + 8, (uint32_t)D.scissor.r); wr32(r + 12, (uint32_t)D.scissor.b);
    return D3D_OK;
}
static uint32_t SetClipPlane_(gp_thread *t) { if (A(1) >= 6) return D3DERR_INVALIDCALL; memcpy(D.clip_planes[A(1)], G(A(2)), 16); return D3D_OK; }
static uint32_t GetClipPlane_(gp_thread *t) { if (A(1) >= 6) return D3DERR_INVALIDCALL; memcpy(G(A(2)), D.clip_planes[A(1)], 16); return D3D_OK; }
static uint32_t SetMaterial_(gp_thread *t) { memcpy(D.material, G(A(1)), 68); return D3D_OK; }
static uint32_t GetMaterial_(gp_thread *t) { memcpy(G(A(1)), D.material, 68); return D3D_OK; }
static uint32_t SetSoftwareVertexProcessing_(gp_thread *t) { (void)t; return D3D_OK; }
static uint32_t GetSoftwareVertexProcessing_(gp_thread *t) { (void)t; return 0; }

/* shader constants */
uint32_t gp_dev_set_const(bool pixel, int kind, uint32_t start, const void *data, uint32_t count)
{
    switch (kind) {
    case 0:
        if (start + count > (pixel ? 224u : 256u)) return D3DERR_INVALIDCALL;
        memcpy(pixel ? D.ps_const[start] : D.vs_const[start], data, 16 * count);
        return D3D_OK;
    case 1:
        if (start + count > 16) return D3DERR_INVALIDCALL;
        memcpy(pixel ? D.ps_const_i[start] : D.vs_const_i[start], data, 16 * count);
        return D3D_OK;
    default:
        if (start + count > 16) return D3DERR_INVALIDCALL;
        memcpy(pixel ? &D.ps_const_b[start] : &D.vs_const_b[start], data, 4 * count);
        return D3D_OK;
    }
}
static uint32_t get_const(bool pixel, int kind, uint32_t start, gaddr dst, uint32_t count)
{
    uint32_t max = kind == 0 ? (pixel ? 224u : 256u) : 16u;
    if (start + count > max) return D3DERR_INVALIDCALL;
    const void *src = kind == 0 ? (pixel ? (void *)D.ps_const[start] : (void *)D.vs_const[start])
                    : kind == 1 ? (pixel ? (void *)D.ps_const_i[start] : (void *)D.vs_const_i[start])
                    : (pixel ? (void *)&D.ps_const_b[start] : (void *)&D.vs_const_b[start]);
    memcpy(G(dst), src, (kind == 2 ? 4 : 16) * count);
    return D3D_OK;
}
static uint32_t SetVertexShaderConstantF_(gp_thread *t) { return gp_dev_set_const(false, 0, A(1), G(A(2)), A(3)); }
static uint32_t GetVertexShaderConstantF_(gp_thread *t) { return get_const(false, 0, A(1), A(2), A(3)); }
static uint32_t SetPixelShaderConstantF_(gp_thread *t) { return gp_dev_set_const(true, 0, A(1), G(A(2)), A(3)); }
static uint32_t GetPixelShaderConstantF_(gp_thread *t) { return get_const(true, 0, A(1), A(2), A(3)); }
static uint32_t SetVertexShaderConstantI_(gp_thread *t) { return gp_dev_set_const(false, 1, A(1), G(A(2)), A(3)); }
static uint32_t SetPixelShaderConstantI_(gp_thread *t) { return gp_dev_set_const(true, 1, A(1), G(A(2)), A(3)); }
static uint32_t SetVertexShaderConstantB_(gp_thread *t) { return gp_dev_set_const(false, 2, A(1), G(A(2)), A(3)); }
static uint32_t SetPixelShaderConstantB_(gp_thread *t) { return gp_dev_set_const(true, 2, A(1), G(A(2)), A(3)); }
static uint32_t GetVertexShaderConstantI_(gp_thread *t) { return get_const(false, 1, A(1), A(2), A(3)); }
static uint32_t GetPixelShaderConstantI_(gp_thread *t) { return get_const(true, 1, A(1), A(2), A(3)); }
static uint32_t GetVertexShaderConstantB_(gp_thread *t) { return get_const(false, 2, A(1), A(2), A(3)); }
static uint32_t GetPixelShaderConstantB_(gp_thread *t) { return get_const(true, 2, A(1), A(2), A(3)); }

/* ---------------------------------------------------------- partial clears */

/* ---------------------------------------------------------- diagnostics
   Numeric back-buffer statistics (no images): mean colour, fraction of pixels
   that are not black, and an FNV-1a checksum. GP_FRAME_STATS=N logs every N frames. */
void gp_d3d9_log_backbuffer_stats(uint64_t frame)
{
    gp_res *bb = gp_res_at(D.backbuffer);
    uint32_t w = bb->width, h = bb->height;
    id<MTLBuffer> buf = [gp_mtl newBufferWithLength:(NSUInteger)w * h * 4 options:MTLResourceStorageModeShared];
    gp_residency_add(buf);
    id<MTL4ComputeCommandEncoder> ce = gp_d3d9_blit_encoder();
    [ce copyFromTexture:bb->tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
               toBuffer:buf destinationOffset:0 destinationBytesPerRow:w * 4 destinationBytesPerImage:(NSUInteger)w * h * 4];
    [ce endEncoding];
    gp_d3d9_flush_and_wait();
    const uint8_t *p = buf.contents;
    uint64_t sum[3] = {0}, lit = 0, hash = 1469598103934665603ull;
    for (size_t i = 0; i < (size_t)w * h; i++) {
        sum[0] += p[4 * i + 2]; sum[1] += p[4 * i + 1]; sum[2] += p[4 * i];
        if (p[4 * i] | p[4 * i + 1] | p[4 * i + 2]) lit++;
        for (int k = 0; k < 3; k++) { hash ^= p[4 * i + (size_t)k]; hash *= 1099511628211ull; }
    }
    double n = (double)w * h;
    gp_log("frame %llu: %ux%u mean RGB %.1f %.1f %.1f, non-black %.1f%%, checksum %016llx",
           (unsigned long long)frame, w, h, sum[0] / n, sum[1] / n, sum[2] / n, 100.0 * lit / n, (unsigned long long)hash);
    gp_residency_remove(buf);
}

/* ---------------------------------------------------------- vtables */
static const char *const device_methods[] = { "QueryInterface", "AddRef", "Release", "TestCooperativeLevel",
    "GetAvailableTextureMem", "EvictManagedResources", "GetDirect3D", "GetDeviceCaps", "GetDisplayMode",
    "GetCreationParameters", "SetCursorProperties", "SetCursorPosition", "ShowCursor", "CreateAdditionalSwapChain",
    "GetSwapChain", "GetNumberOfSwapChains", "Reset", "Present", "GetBackBuffer", "GetRasterStatus", "SetDialogBoxMode",
    "SetGammaRamp", "GetGammaRamp", "CreateTexture", "CreateVolumeTexture", "CreateCubeTexture", "CreateVertexBuffer",
    "CreateIndexBuffer", "CreateRenderTarget", "CreateDepthStencilSurface", "UpdateSurface", "UpdateTexture",
    "GetRenderTargetData", "GetFrontBufferData", "StretchRect", "ColorFill", "CreateOffscreenPlainSurface",
    "SetRenderTarget", "GetRenderTarget", "SetDepthStencilSurface", "GetDepthStencilSurface", "BeginScene", "EndScene",
    "Clear", "SetTransform", "GetTransform", "MultiplyTransform", "SetViewport", "GetViewport", "SetMaterial",
    "GetMaterial", "SetLight", "GetLight", "LightEnable", "GetLightEnable", "SetClipPlane", "GetClipPlane",
    "SetRenderState", "GetRenderState", "CreateStateBlock", "BeginStateBlock", "EndStateBlock", "SetClipStatus",
    "GetClipStatus", "GetTexture", "SetTexture", "GetTextureStageState", "SetTextureStageState", "GetSamplerState",
    "SetSamplerState", "ValidateDevice", "SetPaletteEntries", "GetPaletteEntries", "SetCurrentTexturePalette",
    "GetCurrentTexturePalette", "SetScissorRect", "GetScissorRect", "SetSoftwareVertexProcessing",
    "GetSoftwareVertexProcessing", "SetNPatchMode", "GetNPatchMode", "DrawPrimitive", "DrawIndexedPrimitive",
    "DrawPrimitiveUP", "DrawIndexedPrimitiveUP", "ProcessVertices", "CreateVertexDeclaration", "SetVertexDeclaration",
    "GetVertexDeclaration", "SetFVF", "GetFVF", "CreateVertexShader", "SetVertexShader", "GetVertexShader",
    "SetVertexShaderConstantF", "GetVertexShaderConstantF", "SetVertexShaderConstantI", "GetVertexShaderConstantI",
    "SetVertexShaderConstantB", "GetVertexShaderConstantB", "SetStreamSource", "GetStreamSource", "SetStreamSourceFreq",
    "GetStreamSourceFreq", "SetIndices", "GetIndices", "CreatePixelShader", "SetPixelShader", "GetPixelShader",
    "SetPixelShaderConstantF", "GetPixelShaderConstantF", "SetPixelShaderConstantI", "GetPixelShaderConstantI",
    "SetPixelShaderConstantB", "GetPixelShaderConstantB", "DrawRectPatch", "DrawTriPatch", "DeletePatch", "CreateQuery" };
#define RESOURCE_METHODS "QueryInterface", "AddRef", "Release", "GetDevice", "SetPrivateData", "GetPrivateData", \
    "FreePrivateData", "SetPriority", "GetPriority", "PreLoad", "GetType"
#define BASETEX_METHODS RESOURCE_METHODS, "SetLOD", "GetLOD", "GetLevelCount", "SetAutoGenFilterType", \
    "GetAutoGenFilterType", "GenerateMipSubLevels"
static const char *const surface_methods[] = { RESOURCE_METHODS, "GetContainer", "GetDesc", "LockRect", "UnlockRect", "GetDC", "ReleaseDC" };
static const char *const texture_methods[] = { BASETEX_METHODS, "GetLevelDesc", "GetSurfaceLevel", "LockRect", "UnlockRect", "AddDirtyRect" };
static const char *const cube_methods[] = { BASETEX_METHODS, "GetLevelDesc", "GetCubeMapSurface", "LockRect", "UnlockRect", "AddDirtyRect" };
static const char *const volume_methods[] = { BASETEX_METHODS, "GetLevelDesc", "GetVolumeLevel", "LockBox", "UnlockBox", "AddDirtyBox" };
static const char *const vb_methods[] = { RESOURCE_METHODS, "Lock", "Unlock", "GetDesc" };
static const char *const decl_methods[] = { "QueryInterface", "AddRef", "Release", "GetDevice", "GetDeclaration" };
static const char *const shader_methods[] = { "QueryInterface", "AddRef", "Release", "GetDevice", "GetFunction" };
static const char *const query_methods[] = { "QueryInterface", "AddRef", "Release", "GetDevice", "GetType", "GetDataSize", "Issue", "GetData" };
static const char *const stateblock_methods[] = { "QueryInterface", "AddRef", "Release", "GetDevice", "Capture", "Apply" };

gaddr gp_d3d9_vtable(const char *iface)
{
    static struct { const char *name; const char *const *m; int n; gaddr vt; } t[] = {
        { "IDirect3DDevice9", device_methods, sizeof device_methods / sizeof *device_methods, 0 },
        { "IDirect3DSurface9", surface_methods, sizeof surface_methods / sizeof *surface_methods, 0 },
        { "IDirect3DTexture9", texture_methods, sizeof texture_methods / sizeof *texture_methods, 0 },
        { "IDirect3DCubeTexture9", cube_methods, sizeof cube_methods / sizeof *cube_methods, 0 },
        { "IDirect3DVolumeTexture9", volume_methods, sizeof volume_methods / sizeof *volume_methods, 0 },
        { "IDirect3DVertexBuffer9", vb_methods, sizeof vb_methods / sizeof *vb_methods, 0 },
        { "IDirect3DIndexBuffer9", vb_methods, sizeof vb_methods / sizeof *vb_methods, 0 },
        { "IDirect3DVertexDeclaration9", decl_methods, sizeof decl_methods / sizeof *decl_methods, 0 },
        { "IDirect3DVertexShader9", shader_methods, sizeof shader_methods / sizeof *shader_methods, 0 },
        { "IDirect3DPixelShader9", shader_methods, sizeof shader_methods / sizeof *shader_methods, 0 },
        { "IDirect3DQuery9", query_methods, sizeof query_methods / sizeof *query_methods, 0 },
        { "IDirect3DStateBlock9", stateblock_methods, sizeof stateblock_methods / sizeof *stateblock_methods, 0 },
    };
    for (size_t i = 0; i < sizeof t / sizeof *t; i++)
        if (!strcmp(t[i].name, iface)) {
            if (!t[i].vt) t[i].vt = gp_com_vtable(iface, t[i].m, t[i].n);
            return t[i].vt;
        }
    gp_fatal("no vtable for %s", iface);
}

#undef DLL
#define DLL "IDirect3DDevice9"
const gp_api gp_api_idirect3ddevice9_state[] = {
    API(SetRenderState_, "SetRenderState", 3), API(GetRenderState_, "GetRenderState", 3),
    API(SetSamplerState_, "SetSamplerState", 4), API(GetSamplerState_, "GetSamplerState", 4),
    API(SetTextureStageState_, "SetTextureStageState", 4), API(GetTextureStageState_, "GetTextureStageState", 4),
    API(SetTransform_, "SetTransform", 3), API(GetTransform_, "GetTransform", 3), API(MultiplyTransform_, "MultiplyTransform", 3),
    API(SetViewport_, "SetViewport", 2), API(GetViewport_, "GetViewport", 2),
    API(SetScissorRect_, "SetScissorRect", 2), API(GetScissorRect_, "GetScissorRect", 2),
    API(SetClipPlane_, "SetClipPlane", 3), API(GetClipPlane_, "GetClipPlane", 3),
    API(SetMaterial_, "SetMaterial", 2), API(GetMaterial_, "GetMaterial", 2),
    API(SetSoftwareVertexProcessing_, "SetSoftwareVertexProcessing", 2),
    API(GetSoftwareVertexProcessing_, "GetSoftwareVertexProcessing", 1),
    API(SetVertexShaderConstantF_, "SetVertexShaderConstantF", 4), API(GetVertexShaderConstantF_, "GetVertexShaderConstantF", 4),
    API(SetPixelShaderConstantF_, "SetPixelShaderConstantF", 4), API(GetPixelShaderConstantF_, "GetPixelShaderConstantF", 4),
    API(SetVertexShaderConstantI_, "SetVertexShaderConstantI", 4), API(SetPixelShaderConstantI_, "SetPixelShaderConstantI", 4),
    API(SetVertexShaderConstantB_, "SetVertexShaderConstantB", 4), API(SetPixelShaderConstantB_, "SetPixelShaderConstantB", 4),
    API(GetVertexShaderConstantI_, "GetVertexShaderConstantI", 4), API(GetPixelShaderConstantI_, "GetPixelShaderConstantI", 4),
    API(GetVertexShaderConstantB_, "GetVertexShaderConstantB", 4), API(GetPixelShaderConstantB_, "GetPixelShaderConstantB", 4),
    { 0 }
};
