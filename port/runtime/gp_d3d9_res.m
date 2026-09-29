/* Direct3D 9 resources: textures, surfaces, vertex/index buffers. */
#import <Metal/Metal.h>
#include "gp_d3d9_state.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

enum { POOL_DEFAULT = 0, POOL_MANAGED = 1, POOL_SYSTEMMEM = 2, POOL_SCRATCH = 3 };
enum { USAGE_RENDERTARGET = 1, USAGE_DEPTHSTENCIL = 2, USAGE_WRITEONLY = 8, USAGE_DYNAMIC = 0x200, USAGE_AUTOGENMIPMAP = 0x400 };
enum { LOCK_READONLY = 0x10, LOCK_DISCARD = 0x2000, LOCK_NOOVERWRITE = 0x1000, LOCK_NOSYSLOCK = 0x800 };

/* ------------------------------------------------------ buffer memory
   Guest regions wrapped by no-copy MTLBuffers; first-fit suballocation. */
#define REGION (16u << 20)
typedef struct { gaddr base; uint32_t size; id<MTLBuffer> buf; uint8_t *used_map; } region;   /* map: 256-byte granules */
static region regions[256];
static int nregions;
typedef struct { gaddr addr; uint32_t size; uint64_t free_after; } pending_free;
static pending_free pending[8192];
static int npending;

static bool region_alloc_in(region *r, uint32_t granules, uint32_t *first)
{
    uint32_t run = 0;
    for (uint32_t i = 0; i < r->size / 256; i++) {
        run = r->used_map[i] ? 0 : run + 1;
        if (run == granules) { *first = i + 1 - granules; return true; }
    }
    return false;
}

static void release_pending(void)
{
    uint64_t done = D.frame_event.signaledValue;
    for (int i = 0; i < npending;) {
        if (pending[i].free_after <= done) {
            for (int k = 0; k < nregions; k++)
                if (pending[i].addr >= regions[k].base && pending[i].addr < regions[k].base + regions[k].size)
                    memset(regions[k].used_map + (pending[i].addr - regions[k].base) / 256, 0, pending[i].size / 256);
            pending[i] = pending[--npending];
        } else i++;
    }
}

/* returns guest address; *gpu = GPU address of the same bytes */
static gaddr buffer_alloc(uint32_t size, uint64_t *gpu)
{
    uint32_t granules = (size + 255) / 256;
    for (int pass = 0; pass < 2; pass++) {
        for (int k = 0; k < nregions; k++) {
            uint32_t first;
            if (region_alloc_in(&regions[k], granules, &first)) {
                memset(regions[k].used_map + first, 1, granules);
                *gpu = regions[k].buf.gpuAddress + (uint64_t)first * 256;
                return regions[k].base + first * 256;
            }
        }
        if (pass == 0 && npending) { release_pending(); continue; }
    }
    if (nregions == 256) gp_fatal("more than 4 GiB of vertex/index buffers");
    region *r = &regions[nregions];
    /* a buffer larger than the standard region gets a region of its own (64 KiB granular) */
    r->size = size > REGION ? (uint32_t)(((uint64_t)size + 0xffffu) & ~0xffffull) : REGION;
    if (size > 0xffff0000u) gp_fatal("vertex/index buffer of %u bytes is too large", size);
    r->base = gp_vm_reserve(0, r->size);
    if (!r->base) gp_fatal("guest address space exhausted for buffers");
    r->buf = [gp_mtl newBufferWithBytesNoCopy:G(r->base) length:r->size options:MTLResourceStorageModeShared deallocator:nil];
    if (!r->buf) gp_fatal("Metal: cannot wrap guest buffer region");
    r->used_map = calloc(r->size / 256, 1);
    if (!r->used_map) gp_fatal("out of memory for the buffer region map");
    gp_residency_add(r->buf);
    nregions++;
    return buffer_alloc(size, gpu);
}

static void buffer_free_later(gaddr a, uint32_t size)
{
    if (npending == 8192) { gp_d3d9_flush_and_wait(); release_pending(); }
    pending[npending++] = (pending_free){ a, (size + 255) & ~255u, D.frame_serial + (D.recording ? 1 : 0) };
}

/* buffer payload */
typedef struct { uint64_t gpu; uint64_t last_use; } bufinfo;

uint64_t gp_d3d9_buffer_gpu(gp_res *r)
{
    bufinfo *b = r->priv;
    b->last_use = D.frame_serial + 1;          /* used by the frame being recorded */
    return b->gpu;
}

static uint32_t create_buffer(gp_thread *t, int kind, const char *iface, uint32_t len, uint32_t usage, uint32_t format, uint32_t pool, gaddr out)
{
    if (!len) return D3DERR_INVALIDCALL;
    bufinfo *b = calloc(1, sizeof *b);
    gp_res r = { .kind = kind, .size = len, .usage = usage, .format = format, .pool = pool, .priv = b };
    r.sysmem = buffer_alloc(len, &b->gpu);
    memset(G(r.sysmem), 0, len);
    uint32_t idx = gp_res_new(r);
    wr32(out, gp_d3d9_new_object(iface, idx));
    (void)t;
    return D3D_OK;
}
static uint32_t CreateVertexBuffer_(gp_thread *t) { return create_buffer(t, R_VB, "IDirect3DVertexBuffer9", A(1), A(2), A(3), A(4), A(5)); }
static uint32_t CreateIndexBuffer_(gp_thread *t) { return create_buffer(t, R_IB, "IDirect3DIndexBuffer9", A(1), A(2), A(3), A(4), A(5)); }

static uint32_t BufLock_(gp_thread *t)
{
    /* (this, offset, size, void **ppbData, flags) */
    gp_res *r = gp_res_get(A(0), 0);
    bufinfo *b = r->priv;
    uint32_t off = A(1), flags = A(4);
    if (off > r->size) return D3DERR_INVALIDCALL;
    bool in_use = b->last_use > D.frame_event.signaledValue;
    if ((flags & LOCK_DISCARD) && in_use) {
        buffer_free_later(r->sysmem, r->size);
        r->sysmem = buffer_alloc(r->size, &b->gpu);             /* rename: the GPU keeps the old copy */
    } else if (in_use && !(flags & (LOCK_NOOVERWRITE | LOCK_READONLY))) {
        if (b->last_use > D.frame_serial) gp_d3d9_flush_and_wait();   /* pending in the current frame */
        if (![D.frame_event waitUntilSignaledValue:b->last_use timeoutMS:10000]) gp_fatal("GPU timeout on buffer lock");
    }
    wr32(A(3), r->sysmem + off);
    return D3D_OK;
}
static uint32_t BufUnlock_(gp_thread *t) { (void)t; return D3D_OK; }   /* the guest wrote GPU-visible memory directly */
static uint32_t BufGetDesc_(gp_thread *t)
{
    gp_res *r = gp_res_get(A(0), 0);
    gaddr d = A(1);
    if (r->kind == R_VB) { wr32(d, D3DFMT_VERTEXDATA); wr32(d + 4, 1); wr32(d + 8, r->usage); wr32(d + 12, r->pool); wr32(d + 16, r->size); wr32(d + 20, r->format); }
    else { wr32(d, r->format); wr32(d + 4, 3); wr32(d + 8, r->usage); wr32(d + 12, r->pool); wr32(d + 16, r->size); }
    return D3D_OK;
}

/* ------------------------------------------------------------ textures */
static uint32_t mip_levels(uint32_t w, uint32_t h, uint32_t d)
{
    uint32_t n = 1, m = w > h ? w : h;
    if (d > m) m = d;
    while (m > 1) { m >>= 1; n++; }
    return n;
}
static uint32_t level_dim(uint32_t v, uint32_t level) { v >>= level; return v ? v : 1; }

/* bytes per row / rows of a level in D3D layout (blocks for DXT) */
static void level_layout(const gp_format *f, uint32_t w, uint32_t h, uint32_t *pitch, uint32_t *rows)
{
    uint32_t bw = (w + f->block - 1) / f->block, bh = (h + f->block - 1) / f->block;
    *pitch = bw * f->bytes_per_block;
    *rows = bh;
}

/* guest mirror: faces x levels, each level tightly packed with the D3D pitch */
static uint32_t mirror_offset(gp_res *r, uint32_t face, uint32_t level)
{
    uint32_t off = 0;
    for (uint32_t fc = 0; fc <= face; fc++)
        for (uint32_t l = 0; l < r->levels; l++) {
            if (fc == face && l == level) return off;
            uint32_t pitch, rows;
            level_layout(r->fmt, level_dim(r->width, l), level_dim(r->height, l), &pitch, &rows);
            off += pitch * rows * level_dim(r->depth ? r->depth : 1, l);
        }
    return off;
}
static uint32_t mirror_size(gp_res *r) { return mirror_offset(r, r->kind == R_CUBE ? 6 : 1, 0); }

static uint32_t create_texture(gp_thread *t, int kind, uint32_t w, uint32_t h, uint32_t depth, uint32_t levels,
                               uint32_t usage, uint32_t format, uint32_t pool, gaddr out)
{
    (void)t;
    const gp_format *f = gp_format_info(format);
    if (!f || !w || !h) return D3DERR_INVALIDCALL;
    uint32_t full = mip_levels(w, h, kind == R_VOLUME ? depth : 1);
    if (!levels || levels > full) levels = full;
    if (usage & USAGE_AUTOGENMIPMAP) levels = full;
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = kind == R_CUBE ? MTLTextureTypeCube : kind == R_VOLUME ? MTLTextureType3D : MTLTextureType2D;
    d.pixelFormat = f->mtl;
    d.width = w; d.height = kind == R_CUBE ? w : h; d.depth = kind == R_VOLUME ? depth : 1;
    d.mipmapLevelCount = levels;
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageShaderRead | ((usage & (USAGE_RENDERTARGET | USAGE_DEPTHSTENCIL)) || f->depth ? MTLTextureUsageRenderTarget : 0);
    if (f->swizzle_bgrx) d.swizzle = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleOne);
    if (format == D3DFMT_L8 || format == D3DFMT_L16) d.swizzle = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleOne);
    if (format == D3DFMT_A8L8) d.swizzle = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleGreen);
    if (format == D3DFMT_A8) d.swizzle = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleZero, MTLTextureSwizzleZero, MTLTextureSwizzleZero, MTLTextureSwizzleAlpha);
    if ((format == D3DFMT_R16F || format == D3DFMT_R32F) ) d.swizzle = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleOne, MTLTextureSwizzleOne, MTLTextureSwizzleOne);
    if (format == D3DFMT_G16R16F || format == D3DFMT_G32R32F || format == D3DFMT_G16R16)
        d.swizzle = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleOne, MTLTextureSwizzleOne);
    gp_res r = { .kind = kind, .format = format, .usage = usage, .pool = pool, .width = w, .height = kind == R_CUBE ? w : h,
                 .depth = kind == R_VOLUME ? depth : 0, .levels = levels, .fmt = f };
    r.tex = [gp_mtl newTextureWithDescriptor:d];
    if (!r.tex) return D3DERR_OUTOFVIDEOMEMORY;
    gp_residency_add(r.tex);
    static const char *const ifaces[] = { [R_TEXTURE] = "IDirect3DTexture9", [R_CUBE] = "IDirect3DCubeTexture9", [R_VOLUME] = "IDirect3DVolumeTexture9" };
    uint32_t idx = gp_res_new(r);
    wr32(out, gp_d3d9_new_object(ifaces[kind], idx));
    return D3D_OK;
}
static uint32_t CreateTexture_(gp_thread *t) { return create_texture(t, R_TEXTURE, A(1), A(2), 1, A(3), A(4), A(5), A(6), A(7)); }
static uint32_t CreateCubeTexture_(gp_thread *t) { return create_texture(t, R_CUBE, A(1), A(1), 1, A(2), A(3), A(4), A(5), A(6)); }
static uint32_t CreateVolumeTexture_(gp_thread *t) { return create_texture(t, R_VOLUME, A(1), A(2), A(3), A(4), A(5), A(6), A(7), A(8)); }

/* surface object for (texture, face, level), created once */
static gaddr level_surface(gp_res *tex, uint32_t tex_index, uint32_t face, uint32_t level)
{
    uint32_t faces = tex->kind == R_CUBE ? 6 : 1;
    if (!tex->level_surfaces) tex->level_surfaces = gp_heap_alloc(4 * faces * tex->levels, true);
    gaddr slot = tex->level_surfaces + 4 * (face * tex->levels + level);
    if (!rd32(slot)) {
        gp_res s = { .kind = R_SURFACE, .format = tex->format, .usage = tex->usage, .pool = tex->pool,
                     .width = level_dim(tex->width, level), .height = level_dim(tex->height, level), .levels = 1,
                     .fmt = tex->fmt, .tex = tex->tex, .owner = tex_index, .level = level, .face = face };
        uint32_t idx = gp_res_new(s);
        gaddr o = gp_d3d9_new_object("IDirect3DSurface9", idx);
        wr32(o + 4, 0);                        /* level surfaces count through their container */
        wr32(slot, o);
    }
    gaddr o = rd32(slot);
    gp_d3d9_addref(o);
    return o;
}
gaddr gp_d3d9_level0_surface(gaddr tex) { return level_surface(gp_res_get(tex, R_TEXTURE), rd32(tex + 8), 0, 0); }

static uint32_t visible_levels(const gp_res *r);
static uint32_t GetSurfaceLevel_(gp_thread *t)
{
    gp_res *r = gp_res_get(A(0), R_TEXTURE);
    if (A(1) >= visible_levels(r)) return D3DERR_INVALIDCALL;
    wr32(A(2), level_surface(r, rd32(A(0) + 8), 0, A(1)));
    return D3D_OK;
}
static uint32_t GetCubeMapSurface_(gp_thread *t)
{
    gp_res *r = gp_res_get(A(0), R_CUBE);
    if (A(1) >= 6 || A(2) >= r->levels) return D3DERR_INVALIDCALL;
    wr32(A(3), level_surface(r, rd32(A(0) + 8), A(1), A(2)));
    return D3D_OK;
}
/* D3D9: an auto-generated mip chain is the driver's business. The application sees one level, cannot lock the
   others, and the runtime rebuilds them whenever level 0 changes. */
static uint32_t visible_levels(const gp_res *r) { return (r->usage & USAGE_AUTOGENMIPMAP) && r->kind != R_VOLUME ? 1 : r->levels; }
static uint32_t GetLevelCount_(gp_thread *t) { return visible_levels(gp_res_get(A(0), 0)); }
static uint32_t GetLevelDesc_(gp_thread *t)
{
    /* D3DSURFACE_DESC: Format, Type, Usage, Pool, MultiSampleType, MultiSampleQuality, Width, Height */
    gp_res *r = gp_res_get(A(0), 0);
    if (A(1) >= r->levels) return D3DERR_INVALIDCALL;
    gaddr d = A(2);
    wr32(d, r->format); wr32(d + 4, 1); wr32(d + 8, r->usage); wr32(d + 12, r->pool); wr32(d + 16, 0); wr32(d + 20, 0);
    wr32(d + 24, level_dim(r->width, A(1))); wr32(d + 28, level_dim(r->height, A(1)));
    return D3D_OK;
}
static uint32_t SetLOD_(gp_thread *t) { (void)t; return 0; }
static uint32_t GetLOD_(gp_thread *t) { (void)t; return 0; }
static uint32_t PreLoad_(gp_thread *t) { (void)t; return 0; }
static uint32_t GetType_(gp_thread *t)
{
    gp_res *r = gp_res_get(A(0), 0);
    switch (r->kind) { case R_SURFACE: return 1; case R_VOLUME: return 4; case R_TEXTURE: return 3; case R_CUBE: return 5; case R_VB: return 6; case R_IB: return 7; }
    return 0;
}

static void upload_level(gp_res *r, uint32_t face, uint32_t level)
{
    uint32_t w = level_dim(r->width, level), h = level_dim(r->height, level), dd = r->kind == R_VOLUME ? level_dim(r->depth, level) : 1;
    uint32_t pitch, rows;
    level_layout(r->fmt, w, h, &pitch, &rows);
    const uint8_t *src = G(r->sysmem + mirror_offset(r, face, level));
    if (getenv("GP_TRACE_MAGENTA") && (r->format == D3DFMT_A8R8G8B8 || r->format == D3DFMT_X8R8G8B8)) {
        uint32_t n = w * h, magenta = 0;
        for (uint32_t i = 0; i < n; i++) { uint32_t px; memcpy(&px, src + 4 * i, 4); if ((px & 0xffffff) == 0xff00ff) magenta++; }
        if (magenta * 10 > n * 9) gp_log("magenta upload: %ux%u level %u fmt %u usage 0x%x pool %u kind %d (texture object 0x%08x)", w, h, level, r->format, r->usage, r->pool, r->kind, r->obj);
    }
    if (getenv("GP_TRACE_MAGENTA") && r->fmt->block == 4) {       /* DXT: a block is magenta when both endpoint colours are 0xF81F */
        uint32_t bb = r->fmt->bytes_per_block, cbo = bb == 8 ? 0 : 8, blocks = pitch / bb * rows, magenta = 0;
        for (uint32_t i = 0; i < blocks; i++) {
            const uint8_t *b = src + i * bb + cbo;
            if (b[0] == 0x1f && b[1] == 0xf8 && b[2] == 0x1f && b[3] == 0xf8) magenta++;
        }
        if (blocks && magenta * 10 > blocks * 9) gp_log("magenta DXT upload: %ux%u level %u fmt 0x%x usage 0x%x pool %u (texture object 0x%08x)", w, h, level, r->format, r->usage, r->pool, r->obj);
    }
    uint32_t size = pitch * rows * dd, out_pitch = pitch;
    void *dst;
    uint64_t gpu;
    if (r->fmt->convert16) {
        out_pitch = w * 4;
        gpu = gp_transient(NULL, out_pitch * h * dd, 256, &dst);
        uint32_t *o = dst;
        for (uint32_t i = 0; i < w * h * dd; i++) {
            uint16_t p = (uint16_t)(src[2 * i] | (src[2 * i + 1] << 8));
            uint32_t a = 255, rr, g, b;
            switch (r->format) {
            case D3DFMT_R5G6B5: rr = (p >> 11) & 31; g = (p >> 5) & 63; b = p & 31; rr = rr * 255 / 31; g = g * 255 / 63; b = b * 255 / 31; break;
            case D3DFMT_A4R4G4B4: a = (p >> 12) * 17; rr = ((p >> 8) & 15) * 17; g = ((p >> 4) & 15) * 17; b = (p & 15) * 17; break;
            default: if (r->format == D3DFMT_A1R5G5B5) a = (p >> 15) ? 255 : 0;
                     rr = ((p >> 10) & 31) * 255 / 31; g = ((p >> 5) & 31) * 255 / 31; b = (p & 31) * 255 / 31; break;
            }
            o[i] = b | (g << 8) | (rr << 16) | (a << 24);
        }
    } else gpu = gp_transient(src, size, 256, &dst);
    (void)gpu;
    uint32_t off;
    id<MTLBuffer> buf = gp_transient_buffer(dst, &off);
    id<MTL4ComputeCommandEncoder> ce = gp_d3d9_blit_encoder();
    [ce copyFromBuffer:buf sourceOffset:off sourceBytesPerRow:out_pitch sourceBytesPerImage:out_pitch * (r->fmt->convert16 ? h : rows)
            sourceSize:MTLSizeMake(w, h, dd) toTexture:r->tex destinationSlice:face destinationLevel:level destinationOrigin:MTLOriginMake(0, 0, 0)];
    if ((r->usage & USAGE_AUTOGENMIPMAP) && level == 0 && r->levels > 1) {
        /* rebuild the rest of the chain from the new level 0 */
        [ce barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
        [ce generateMipmapsForTexture:r->tex];
    }
    [ce endEncoding];
}

/* LockRect on a texture level or surface: guest mirror; upload on unlock */
static uint32_t lock_level(gp_res *r, uint32_t face, uint32_t level, gaddr locked, gaddr rect, uint32_t flags)
{
    if ((r->usage & (USAGE_RENDERTARGET | USAGE_DEPTHSTENCIL)) && r->pool == POOL_DEFAULT)
        return D3DERR_INVALIDCALL;           /* D3D9: render targets in the default pool are not lockable */
    if (!r->sysmem) {
        r->sysmem = gp_heap_alloc(mirror_size(r), true);
        if (!r->sysmem) return D3DERR_OUTOFVIDEOMEMORY;
    }
    uint32_t pitch, rows;
    level_layout(r->fmt, level_dim(r->width, level), level_dim(r->height, level), &pitch, &rows);
    gaddr p = r->sysmem + mirror_offset(r, face, level);
    if (rect) {
        uint32_t x = rd32(rect), y = rd32(rect + 4);
        p += (y / r->fmt->block) * pitch + (x / r->fmt->block) * r->fmt->bytes_per_block;
    }
    wr32(locked, pitch); wr32(locked + 4, p);
    r->locked = true; r->lock_face = face; r->lock_level = level; r->lock_flags = flags;
    return D3D_OK;
}
static void unlock_level(gp_res *r)
{
    if (!r->locked) return;
    r->locked = false;
    if (r->pool == POOL_SYSTEMMEM || r->pool == POOL_SCRATCH || (r->lock_flags & LOCK_READONLY)) return;   /* no GPU copy */
    upload_level(r, r->lock_face, r->lock_level);
}

/* internal access for D3DX: level mirror of a surface (creating it) and the upload after writing */
bool gp_d3d9_surface_mirror(gaddr surf, gaddr *base, uint32_t *pitch, uint32_t *w, uint32_t *h, uint32_t *format)
{
    gp_res *s = gp_res_get(surf, R_SURFACE);
    gp_res *r = s->owner ? gp_res_at(s->owner) : s;
    gaddr locked = gp_heap_alloc(8, true);
    uint32_t hr = lock_level(r, s->owner ? s->face : 0, s->owner ? s->level : 0, locked, 0, 0);
    *pitch = rd32(locked); *base = rd32(locked + 4);
    gp_heap_free(locked);
    *w = s->width; *h = s->height; *format = s->format;
    return hr == D3D_OK;
}
void gp_d3d9_surface_commit(gaddr surf)
{
    gp_res *s = gp_res_get(surf, R_SURFACE);
    unlock_level(s->owner ? gp_res_at(s->owner) : s);
}

static uint32_t TexLockRect_(gp_thread *t)
{
    gp_res *r = gp_res_get(A(0), R_TEXTURE);
    if (A(1) >= visible_levels(r)) return D3DERR_INVALIDCALL;
    return lock_level(r, 0, A(1), A(2), A(3), A(4));
}
static uint32_t TexUnlockRect_(gp_thread *t) { unlock_level(gp_res_get(A(0), R_TEXTURE)); return D3D_OK; }
static uint32_t CubeLockRect_(gp_thread *t)
{
    gp_res *r = gp_res_get(A(0), R_CUBE);
    if (A(1) >= 6 || A(2) >= r->levels) return D3DERR_INVALIDCALL;
    return lock_level(r, A(1), A(2), A(3), A(4), A(5));
}
static uint32_t CubeUnlockRect_(gp_thread *t) { unlock_level(gp_res_get(A(0), R_CUBE)); return D3D_OK; }

/* volume textures: D3DLOCKED_BOX {RowPitch, SlicePitch, pBits} */
static uint32_t VolLockBox_(gp_thread *t)
{
    gp_res *r = gp_res_get(A(0), R_VOLUME);
    uint32_t level = A(1);
    gaddr locked = A(2), box = A(3);
    if (level >= r->levels) return D3DERR_INVALIDCALL;
    if (!r->sysmem) { r->sysmem = gp_heap_alloc(mirror_size(r), true); if (!r->sysmem) return D3DERR_OUTOFVIDEOMEMORY; }
    uint32_t pitch, rows;
    level_layout(r->fmt, level_dim(r->width, level), level_dim(r->height, level), &pitch, &rows);
    gaddr p = r->sysmem + mirror_offset(r, 0, level);
    if (box) p += rd32(box + 16) * pitch * rows + (rd32(box + 4) / r->fmt->block) * pitch + (rd32(box) / r->fmt->block) * r->fmt->bytes_per_block;
    wr32(locked, pitch); wr32(locked + 4, pitch * rows); wr32(locked + 8, p);
    r->locked = true; r->lock_face = 0; r->lock_level = level; r->lock_flags = A(4);
    return D3D_OK;
}
static uint32_t VolUnlockBox_(gp_thread *t) { unlock_level(gp_res_get(A(0), R_VOLUME)); return D3D_OK; }
static uint32_t VolGetLevelDesc_(gp_thread *t)
{
    /* D3DVOLUME_DESC: Format, Type, Usage, Pool, Width, Height, Depth */
    gp_res *r = gp_res_get(A(0), R_VOLUME);
    if (A(1) >= r->levels) return D3DERR_INVALIDCALL;
    gaddr d = A(2);
    wr32(d, r->format); wr32(d + 4, 2); wr32(d + 8, r->usage); wr32(d + 12, r->pool);
    wr32(d + 16, level_dim(r->width, A(1))); wr32(d + 20, level_dim(r->height, A(1))); wr32(d + 24, level_dim(r->depth, A(1)));
    return D3D_OK;
}

static uint32_t SurfLockRect_(gp_thread *t)
{
    gp_res *s = gp_res_get(A(0), R_SURFACE);
    if (s->owner) return lock_level(gp_res_at(s->owner), s->face, s->level, A(1), A(2), A(3));
    return lock_level(s, 0, 0, A(1), A(2), A(3));
}
static uint32_t SurfUnlockRect_(gp_thread *t)
{
    gp_res *s = gp_res_get(A(0), R_SURFACE);
    unlock_level(s->owner ? gp_res_at(s->owner) : s);
    return D3D_OK;
}
static uint32_t SurfGetDesc_(gp_thread *t)
{
    gp_res *s = gp_res_get(A(0), R_SURFACE);
    gaddr d = A(1);
    wr32(d, s->format); wr32(d + 4, 1); wr32(d + 8, s->usage); wr32(d + 12, s->pool); wr32(d + 16, 0); wr32(d + 20, 0);
    wr32(d + 24, s->width); wr32(d + 28, s->height);
    return D3D_OK;
}
static uint32_t SurfGetContainer_(gp_thread *t)
{
    gp_res *s = gp_res_get(A(0), R_SURFACE);
    if (!s->owner) return D3DERR_INVALIDCALL;
    gaddr o = gp_res_at(s->owner)->obj;
    gp_d3d9_addref(o);
    wr32(A(2), o);
    return D3D_OK;
}

static uint32_t GenerateMipSubLevels_(gp_thread *t)
{
    gp_res *r = gp_res_get(A(0), 0);
    if (r->levels < 2) return 0;
    id<MTL4ComputeCommandEncoder> ce = gp_d3d9_blit_encoder();
    [ce generateMipmapsForTexture:r->tex];
    [ce endEncoding];
    return 0;
}
static uint32_t SetAutoGenFilterType_(gp_thread *t) { (void)t; return D3D_OK; }

/* standalone surfaces */
static uint32_t CreateRenderTarget_(gp_thread *t)
{
    /* (this, w, h, format, msType, msQuality, lockable, IDirect3DSurface9**, shared) */
    if (A(4)) gp_fatal("multisampled render target (type %u)", A(4));
    if (!gp_format_info(A(3))) return D3DERR_INVALIDCALL;
    uint32_t idx = gp_d3d9_new_surface(A(3), A(1), A(2), USAGE_RENDERTARGET, true);
    if (A(6)) gp_res_at(idx)->pool = POOL_SYSTEMMEM;      /* lockable */
    wr32(A(7), gp_d3d9_new_object("IDirect3DSurface9", idx));
    return D3D_OK;
}
static uint32_t CreateDepthStencilSurface_(gp_thread *t)
{
    if (A(4)) gp_fatal("multisampled depth surface (type %u)", A(4));
    const gp_format *f = gp_format_info(A(3));
    if (!f || !f->depth) return D3DERR_INVALIDCALL;
    uint32_t idx = gp_d3d9_new_surface(A(3), A(1), A(2), USAGE_DEPTHSTENCIL, true);
    wr32(A(7), gp_d3d9_new_object("IDirect3DSurface9", idx));
    return D3D_OK;
}
static uint32_t CreateOffscreenPlainSurface_(gp_thread *t)
{
    /* (this, w, h, format, pool, IDirect3DSurface9**, shared) */
    const gp_format *f = gp_format_info(A(3));
    if (!f) return D3DERR_INVALIDCALL;
    uint32_t idx = gp_d3d9_new_surface(A(3), A(1), A(2), 0, false);
    gp_res_at(idx)->pool = A(4);
    wr32(A(5), gp_d3d9_new_object("IDirect3DSurface9", idx));
    return D3D_OK;
}

/* ------------------------------------------------------- binding
   Device bindings hold a COM reference, like the D3D9 runtime. */
/* AddRef; a texture level surface forwards to its container like D3D9 */
uint32_t gp_d3d9_addref(gaddr obj)
{
    gp_res *r = gp_res_at(rd32(obj + 8));
    if (r && r->kind == R_SURFACE && r->owner) obj = gp_res_at(r->owner)->obj;
    uint32_t n = rd32(obj + 4) + 1;
    wr32(obj + 4, n);
    return n;
}

void gp_d3d9_bind(uint32_t *slot, uint32_t new_index)
{
    if (*slot == new_index) return;
    gp_res *n = gp_res_at(new_index);
    if (n) gp_d3d9_addref(n->obj);
    gp_res *o = gp_res_at(*slot);
    *slot = new_index;
    if (o) gp_d3d9_release(o->obj);
}
uint32_t gp_dev_set_texture(uint32_t s, gaddr obj)
{
    int slot = s < 16 ? (int)s : s == 256 ? 16 : (s >= 257 && s <= 260) ? (int)(s - 257 + 17) : -1;
    if (slot < 0) return D3DERR_INVALIDCALL;
    if (obj) gp_res_get(obj, 0);
    extern volatile bool gp_trace_frame_active;
    if (gp_trace_frame_active) gp_log("  device texture %u = 0x%08x", s, obj);
    gp_d3d9_bind(&D.textures[slot], obj ? rd32(obj + 8) : 0);
    return D3D_OK;
}
static uint32_t SetTexture_(gp_thread *t) { return gp_dev_set_texture(A(1), A(2)); }
static uint32_t GetTexture_(gp_thread *t)
{
    uint32_t s = A(1);
    int slot = s < 16 ? (int)s : s == 256 ? 16 : (s >= 257 && s <= 260) ? (int)(s - 257 + 17) : -1;
    if (slot < 0) return D3DERR_INVALIDCALL;
    gp_res *r = gp_res_at(D.textures[slot]);
    gaddr o = r ? r->obj : 0;
    if (o) gp_d3d9_addref(o);
    wr32(A(2), o);
    return D3D_OK;
}
static uint32_t SetStreamSource_(gp_thread *t)
{
    if (A(1) >= 16) return D3DERR_INVALIDCALL;
    if (A(2)) gp_res_get(A(2), R_VB);
    gp_d3d9_bind(&D.streams[A(1)].vb, A(2) ? rd32(A(2) + 8) : 0);
    D.streams[A(1)].offset = A(3);
    D.streams[A(1)].stride = A(4);
    return D3D_OK;
}
static uint32_t GetStreamSource_(gp_thread *t)
{
    if (A(1) >= 16) return D3DERR_INVALIDCALL;
    gp_res *r = gp_res_at(D.streams[A(1)].vb);
    gaddr o = r ? r->obj : 0;
    if (o) gp_d3d9_addref(o);
    wr32(A(2), o); wr32(A(3), D.streams[A(1)].offset); wr32(A(4), D.streams[A(1)].stride);
    return D3D_OK;
}
static uint32_t SetStreamSourceFreq_(gp_thread *t) { if (A(1) >= 16) return D3DERR_INVALIDCALL; D.streams[A(1)].freq = A(2); return D3D_OK; }
static uint32_t SetIndices_(gp_thread *t)
{
    if (A(1)) gp_res_get(A(1), R_IB);
    gp_d3d9_bind(&D.indices, A(1) ? rd32(A(1) + 8) : 0);
    return D3D_OK;
}
static uint32_t GetIndices_(gp_thread *t)
{
    gp_res *r = gp_res_at(D.indices);
    gaddr o = r ? r->obj : 0;
    if (o) gp_d3d9_addref(o);
    wr32(A(1), o);
    return D3D_OK;
}

/* ------------------------------------------------------- lifetime */
static uint32_t ResAddRef_(gp_thread *t) { return gp_d3d9_addref(A(0)); }

static void destroy_res(uint32_t idx)
{
    gp_res *r = gp_res_at(idx);
    if (r->kind == R_VB || r->kind == R_IB) buffer_free_later(r->sysmem, r->size);
    else if (r->sysmem) gp_heap_free(r->sysmem);
    if (r->tex && !r->owner) gp_d3d9_release_texture_later(r->tex);
    if (r->level_surfaces) {
        uint32_t n = (r->kind == R_CUBE ? 6 : 1) * r->levels;
        for (uint32_t i = 0; i < n; i++) {
            gaddr s = rd32(r->level_surfaces + 4 * i);
            if (s) { uint32_t si = rd32(s + 8); gp_heap_free(s); *gp_res_at(si) = (gp_res){0}; }
        }
        gp_heap_free(r->level_surfaces);
    }
    gaddr obj = r->obj;
    free(r->priv);
    *r = (gp_res){0};
    gp_heap_free(obj);
}

uint32_t gp_d3d9_release(gaddr obj)
{
    gp_res *r = gp_res_at(rd32(obj + 8));
    if (r && r->kind == R_SURFACE && r->owner) {           /* texture level: the container's count */
        uint32_t owner = r->owner;
        gp_res *c = gp_res_at(owner);
        uint32_t cn = rd32(c->obj + 4) - 1;
        wr32(c->obj + 4, cn);
        if (!cn) destroy_res(owner);
        return cn;
    }
    uint32_t n = rd32(obj + 4) - 1;
    wr32(obj + 4, n);
    if (!n && r) {
        uint32_t idx = rd32(obj + 8);
        if (idx == D.backbuffer || idx == D.auto_depth) return 0;   /* owned by the device */
        destroy_res(idx);
    }
    return n;
}
static uint32_t ResRelease_(gp_thread *t) { return gp_d3d9_release(A(0)); }
static uint32_t ResGetDevice_(gp_thread *t)
{
    gaddr dev = rd32(A(0) + 12);
    wr32(dev + 4, rd32(dev + 4) + 1);
    wr32(A(1), dev);
    return D3D_OK;
}
static uint32_t SetPriority_(gp_thread *t) { (void)t; return 0; }
static uint32_t GetPriority_(gp_thread *t) { (void)t; return 0; }


/* ------------------------------------------------------------- queries
   D3DQUERYTYPE_EVENT completes when the GPU has finished all work issued before
   Issue(D3DISSUE_END); tracked with the frame shared event. */
typedef struct { uint32_t type; uint64_t target; bool issued; } gp_query;

static uint32_t CreateQuery_(gp_thread *t)
{
    uint32_t type = A(1);
    if (type != 8) gp_fatal("IDirect3DDevice9::CreateQuery type %u is not implemented", type);
    if (!A(2)) return D3D_OK;                                       /* support probe */
    gp_query *q = calloc(1, sizeof *q);
    if (!q) gp_fatal("CreateQuery: out of memory");
    q->type = type;
    gp_res r = { .kind = R_QUERY, .priv = q };
    wr32(A(2), gp_d3d9_new_object("IDirect3DQuery9", gp_res_new(r)));
    return D3D_OK;
}
static uint32_t QGetType_(gp_thread *t) { return ((gp_query *)gp_res_get(A(0), R_QUERY)->priv)->type; }
static uint32_t QGetDataSize_(gp_thread *t) { (void)gp_res_get(A(0), R_QUERY); return 4; }   /* EVENT: BOOL */
static uint32_t QIssue_(gp_thread *t)
{
    gp_query *q = gp_res_get(A(0), R_QUERY)->priv;
    if (!(A(1) & 1)) return D3D_OK;                                /* D3DISSUE_BEGIN is ignored for events */
    q->target = D.frame_serial + (D.recording ? 1 : 0);
    q->issued = true;
    return D3D_OK;
}
static uint32_t QGetData_(gp_thread *t)
{
    gp_query *q = gp_res_get(A(0), R_QUERY)->priv;
    gaddr data = A(1);
    uint32_t size = A(2), flags = A(3);
    if (!q->issued) return D3DERR_INVALIDCALL;
    if (q->target > D.frame_serial && (flags & 1)) gp_d3d9_flush_and_wait();   /* D3DGETDATA_FLUSH submits */
    bool done = q->target <= D.frame_serial && D.frame_event.signaledValue >= q->target;
    if (!done) return 1;                                            /* S_FALSE */
    if (data && size >= 4) wr32(data, 1);
    return D3D_OK;
}

#undef DLL
#define DLL "IDirect3DDevice9"
const gp_api gp_api_idirect3ddevice9_res[] = {
    API(CreateQuery_, "CreateQuery", 3),
    API(CreateTexture_, "CreateTexture", 9), API(CreateCubeTexture_, "CreateCubeTexture", 8),
    API(CreateVolumeTexture_, "CreateVolumeTexture", 10),
    API(CreateVertexBuffer_, "CreateVertexBuffer", 7), API(CreateIndexBuffer_, "CreateIndexBuffer", 7),
    API(CreateRenderTarget_, "CreateRenderTarget", 9), API(CreateDepthStencilSurface_, "CreateDepthStencilSurface", 9),
    API(CreateOffscreenPlainSurface_, "CreateOffscreenPlainSurface", 7),
    API(SetTexture_, "SetTexture", 3), API(GetTexture_, "GetTexture", 3),
    API(SetStreamSource_, "SetStreamSource", 5), API(GetStreamSource_, "GetStreamSource", 5),
    API(SetStreamSourceFreq_, "SetStreamSourceFreq", 3), API(SetIndices_, "SetIndices", 2), API(GetIndices_, "GetIndices", 2),
    { 0 }
};
#define COMMON(D_) API(ResAddRef_, "AddRef", 1), API(ResRelease_, "Release", 1), API(ResGetDevice_, "GetDevice", 2), \
    API(SetPriority_, "SetPriority", 2), API(GetPriority_, "GetPriority", 1), API(PreLoad_, "PreLoad", 1), API(GetType_, "GetType", 1)
#undef DLL
#define DLL "IDirect3DTexture9"
const gp_api gp_api_idirect3dtexture9[] = { COMMON(), API(GetLevelCount_, "GetLevelCount", 1), API(GetLevelDesc_, "GetLevelDesc", 3),
    API(GetSurfaceLevel_, "GetSurfaceLevel", 3), API(TexLockRect_, "LockRect", 5), API(TexUnlockRect_, "UnlockRect", 2),
    API(SetLOD_, "SetLOD", 2), API(GetLOD_, "GetLOD", 1), API(GenerateMipSubLevels_, "GenerateMipSubLevels", 1),
    API(SetAutoGenFilterType_, "SetAutoGenFilterType", 2), { 0 } };
#undef DLL
#define DLL "IDirect3DCubeTexture9"
const gp_api gp_api_idirect3dcubetexture9[] = { COMMON(), API(GetLevelCount_, "GetLevelCount", 1), API(GetLevelDesc_, "GetLevelDesc", 3),
    API(GetCubeMapSurface_, "GetCubeMapSurface", 4), API(CubeLockRect_, "LockRect", 6), API(CubeUnlockRect_, "UnlockRect", 3),
    API(SetLOD_, "SetLOD", 2), API(GetLOD_, "GetLOD", 1), API(GenerateMipSubLevels_, "GenerateMipSubLevels", 1),
    API(SetAutoGenFilterType_, "SetAutoGenFilterType", 2), { 0 } };
#undef DLL
#define DLL "IDirect3DVolumeTexture9"
const gp_api gp_api_idirect3dvolumetexture9[] = { COMMON(), API(GetLevelCount_, "GetLevelCount", 1), API(VolGetLevelDesc_, "GetLevelDesc", 3),
    API(VolLockBox_, "LockBox", 5), API(VolUnlockBox_, "UnlockBox", 2), API(SetLOD_, "SetLOD", 2), API(GetLOD_, "GetLOD", 1),
    API(GenerateMipSubLevels_, "GenerateMipSubLevels", 1), { 0 } };
#undef DLL
#define DLL "IDirect3DSurface9"
const gp_api gp_api_idirect3dsurface9[] = { COMMON(), API(SurfLockRect_, "LockRect", 4), API(SurfUnlockRect_, "UnlockRect", 1),
    API(SurfGetDesc_, "GetDesc", 2), API(SurfGetContainer_, "GetContainer", 3), { 0 } };
#undef DLL
#define DLL "IDirect3DVertexBuffer9"
const gp_api gp_api_idirect3dvertexbuffer9[] = { COMMON(), API(BufLock_, "Lock", 5), API(BufUnlock_, "Unlock", 1), API(BufGetDesc_, "GetDesc", 2), { 0 } };
#undef DLL
#define DLL "IDirect3DIndexBuffer9"
const gp_api gp_api_idirect3dindexbuffer9[] = { COMMON(), API(BufLock_, "Lock", 5), API(BufUnlock_, "Unlock", 1), API(BufGetDesc_, "GetDesc", 2), { 0 } };

#undef DLL
#define DLL "IDirect3DQuery9"
const gp_api gp_api_idirect3dquery9[] = { API(ResAddRef_, "AddRef", 1), API(ResRelease_, "Release", 1), API(ResGetDevice_, "GetDevice", 2),
    API(QGetType_, "GetType", 1), API(QGetDataSize_, "GetDataSize", 1), API(QIssue_, "Issue", 2), API(QGetData_, "GetData", 4), { 0 } };
