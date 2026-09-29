/* d3dx9_27.dll utility functions: surface loading/saving, plane transform. */
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "gp_d3d9_state.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------- pixel codecs (float RGBA) */
static bool decodable(uint32_t f)
{
    switch (f) {
    case D3DFMT_A8R8G8B8: case D3DFMT_X8R8G8B8: case D3DFMT_A8B8G8R8: case D3DFMT_X8B8G8R8: case D3DFMT_R5G6B5:
    case D3DFMT_X1R5G5B5: case D3DFMT_A1R5G5B5: case D3DFMT_A4R4G4B4: case D3DFMT_A8: case D3DFMT_L8: case D3DFMT_A8L8:
    case D3DFMT_R8G8B8: case D3DFMT_A16B16G16R16F: case D3DFMT_R32F:
        return true;
    }
    return false;
}
static uint32_t bpp(uint32_t f)
{
    switch (f) {
    case D3DFMT_A8: case D3DFMT_L8: return 1;
    case D3DFMT_R5G6B5: case D3DFMT_X1R5G5B5: case D3DFMT_A1R5G5B5: case D3DFMT_A4R4G4B4: case D3DFMT_A8L8: return 2;
    case D3DFMT_R8G8B8: return 3;
    case D3DFMT_A16B16G16R16F: return 8;
    default: return 4;
    }
}
static float h2f(uint16_t h)
{
    uint32_t s = (h >> 15) & 1, e = (h >> 10) & 31, m = h & 1023;
    float v = e == 0 ? ldexpf((float)m, -24) : e == 31 ? (m ? NAN : INFINITY) : ldexpf((float)(m | 1024), (int)e - 25);
    return s ? -v : v;
}
static uint16_t f2h(float f)
{
    __fp16 h = (__fp16)f;
    uint16_t u; memcpy(&u, &h, 2);
    return u;
}
static void decode(uint32_t f, const uint8_t *p, float *o)
{
    uint32_t v = 0;
    memcpy(&v, p, bpp(f) < 4 ? bpp(f) : 4);
    switch (f) {
    case D3DFMT_A8R8G8B8: o[0] = ((v >> 16) & 255) / 255.f; o[1] = ((v >> 8) & 255) / 255.f; o[2] = (v & 255) / 255.f; o[3] = (v >> 24) / 255.f; break;
    case D3DFMT_X8R8G8B8: o[0] = ((v >> 16) & 255) / 255.f; o[1] = ((v >> 8) & 255) / 255.f; o[2] = (v & 255) / 255.f; o[3] = 1; break;
    case D3DFMT_A8B8G8R8: o[0] = (v & 255) / 255.f; o[1] = ((v >> 8) & 255) / 255.f; o[2] = ((v >> 16) & 255) / 255.f; o[3] = (v >> 24) / 255.f; break;
    case D3DFMT_X8B8G8R8: o[0] = (v & 255) / 255.f; o[1] = ((v >> 8) & 255) / 255.f; o[2] = ((v >> 16) & 255) / 255.f; o[3] = 1; break;
    case D3DFMT_R8G8B8: o[0] = p[2] / 255.f; o[1] = p[1] / 255.f; o[2] = p[0] / 255.f; o[3] = 1; break;
    case D3DFMT_R5G6B5: o[0] = ((v >> 11) & 31) / 31.f; o[1] = ((v >> 5) & 63) / 63.f; o[2] = (v & 31) / 31.f; o[3] = 1; break;
    case D3DFMT_X1R5G5B5: case D3DFMT_A1R5G5B5:
        o[0] = ((v >> 10) & 31) / 31.f; o[1] = ((v >> 5) & 31) / 31.f; o[2] = (v & 31) / 31.f;
        o[3] = f == D3DFMT_A1R5G5B5 ? (float)((v >> 15) & 1) : 1; break;
    case D3DFMT_A4R4G4B4: o[0] = ((v >> 8) & 15) / 15.f; o[1] = ((v >> 4) & 15) / 15.f; o[2] = (v & 15) / 15.f; o[3] = ((v >> 12) & 15) / 15.f; break;
    case D3DFMT_A8: o[0] = o[1] = o[2] = 0; o[3] = p[0] / 255.f; break;
    case D3DFMT_L8: o[0] = o[1] = o[2] = p[0] / 255.f; o[3] = 1; break;
    case D3DFMT_A8L8: o[0] = o[1] = o[2] = p[0] / 255.f; o[3] = p[1] / 255.f; break;
    case D3DFMT_R32F: { float x; memcpy(&x, p, 4); o[0] = x; o[1] = o[2] = o[3] = 1; break; }
    case D3DFMT_A16B16G16R16F: for (int i = 0; i < 4; i++) { uint16_t h; memcpy(&h, p + 2 * i, 2); o[i] = h2f(h); } break;
    }
}
static uint32_t q(float x, uint32_t max) { x = x < 0 ? 0 : x > 1 ? 1 : x; return (uint32_t)lrintf(x * (float)max); }
static void encode(uint32_t f, uint8_t *p, const float *c)
{
    uint32_t v = 0;
    switch (f) {
    case D3DFMT_A8R8G8B8: case D3DFMT_X8R8G8B8: v = (q(c[3], 255) << 24) | (q(c[0], 255) << 16) | (q(c[1], 255) << 8) | q(c[2], 255); if (f == D3DFMT_X8R8G8B8) v |= 0xff000000u; break;
    case D3DFMT_A8B8G8R8: case D3DFMT_X8B8G8R8: v = (q(c[3], 255) << 24) | (q(c[2], 255) << 16) | (q(c[1], 255) << 8) | q(c[0], 255); if (f == D3DFMT_X8B8G8R8) v |= 0xff000000u; break;
    case D3DFMT_R8G8B8: p[0] = (uint8_t)q(c[2], 255); p[1] = (uint8_t)q(c[1], 255); p[2] = (uint8_t)q(c[0], 255); return;
    case D3DFMT_R5G6B5: v = (q(c[0], 31) << 11) | (q(c[1], 63) << 5) | q(c[2], 31); break;
    case D3DFMT_X1R5G5B5: case D3DFMT_A1R5G5B5: v = (q(c[0], 31) << 10) | (q(c[1], 31) << 5) | q(c[2], 31) | ((f == D3DFMT_X1R5G5B5 || c[3] >= 0.5f) ? 0x8000u : 0); break;
    case D3DFMT_A4R4G4B4: v = (q(c[3], 15) << 12) | (q(c[0], 15) << 8) | (q(c[1], 15) << 4) | q(c[2], 15); break;
    case D3DFMT_A8: p[0] = (uint8_t)q(c[3], 255); return;
    case D3DFMT_L8: p[0] = (uint8_t)q(0.2125f * c[0] + 0.7154f * c[1] + 0.0721f * c[2], 255); return;
    case D3DFMT_A8L8: p[0] = (uint8_t)q(0.2125f * c[0] + 0.7154f * c[1] + 0.0721f * c[2], 255); p[1] = (uint8_t)q(c[3], 255); return;
    case D3DFMT_R32F: memcpy(p, &c[0], 4); return;
    case D3DFMT_A16B16G16R16F: for (int i = 0; i < 4; i++) { uint16_t h = f2h(c[i]); memcpy(p + 2 * i, &h, 2); } return;
    }
    memcpy(p, &v, bpp(f));
}

static bool is_dxt(uint32_t f) { return f == D3DFMT_DXT1 || f == D3DFMT_DXT2 || f == D3DFMT_DXT3 || f == D3DFMT_DXT4 || f == D3DFMT_DXT5; }
static uint32_t dxt_block_bytes(uint32_t f) { return f == D3DFMT_DXT1 ? 8 : 16; }

/* decode one 4x4 block to float RGBA (rows of 4) */
static void dxt_decode_block(uint32_t f, const uint8_t *b, float out[16][4])
{
    const uint8_t *cb = f == D3DFMT_DXT1 ? b : b + 8;
    uint16_t c0 = (uint16_t)(cb[0] | (cb[1] << 8)), c1 = (uint16_t)(cb[2] | (cb[3] << 8));
    float pal[4][4];
    for (int i = 0; i < 2; i++) {
        uint16_t c = i ? c1 : c0;
        pal[i][0] = ((c >> 11) & 31) / 31.f; pal[i][1] = ((c >> 5) & 63) / 63.f; pal[i][2] = (c & 31) / 31.f; pal[i][3] = 1;
    }
    bool four = f != D3DFMT_DXT1 || c0 > c1;
    for (int k = 0; k < 4; k++) {
        pal[2][k] = four ? (2 * pal[0][k] + pal[1][k]) / 3 : (pal[0][k] + pal[1][k]) / 2;
        pal[3][k] = four ? (pal[0][k] + 2 * pal[1][k]) / 3 : 0;
    }
    pal[2][3] = 1; pal[3][3] = four ? 1 : 0;
    uint32_t idx = (uint32_t)cb[4] | ((uint32_t)cb[5] << 8) | ((uint32_t)cb[6] << 16) | ((uint32_t)cb[7] << 24);
    for (int i = 0; i < 16; i++) memcpy(out[i], pal[(idx >> (2 * i)) & 3], 16);
    if (f == D3DFMT_DXT2 || f == D3DFMT_DXT3) {
        for (int i = 0; i < 16; i++) out[i][3] = ((b[i / 2] >> (4 * (i & 1))) & 15) / 15.f;
    } else if (f == D3DFMT_DXT4 || f == D3DFMT_DXT5) {
        float a[8]; a[0] = b[0] / 255.f; a[1] = b[1] / 255.f;
        if (b[0] > b[1]) for (int i = 1; i < 7; i++) a[i + 1] = ((7 - i) * a[0] + i * a[1]) / 7;
        else { for (int i = 1; i < 5; i++) a[i + 1] = ((5 - i) * a[0] + i * a[1]) / 5; a[6] = 0; a[7] = 1; }
        uint64_t bits = 0;
        for (int i = 0; i < 6; i++) bits |= (uint64_t)b[2 + i] << (8 * i);
        for (int i = 0; i < 16; i++) out[i][3] = a[(bits >> (3 * i)) & 7];
    }
}

typedef struct { int32_t l, t, r, b; } irect;
static irect read_rect(gaddr a, uint32_t w, uint32_t h)
{
    if (!a) return (irect){ 0, 0, (int32_t)w, (int32_t)h };
    return (irect){ (int32_t)rd32(a), (int32_t)rd32(a + 4), (int32_t)rd32(a + 8), (int32_t)rd32(a + 12) };
}

static uint32_t D3DXLoadSurfaceFromMemory_(gp_thread *t)
{
    /* (pDestSurface, pDestPalette, pDestRect, pSrcMemory, SrcFormat, SrcPitch, pSrcPalette, pSrcRect, Filter, ColorKey) */
    gaddr dst = A(0), src = A(3), srect_a = A(7);
    uint32_t sfmt = A(4), spitch = A(5), filter = A(8), key = A(9);
    if (!dst || !src || !srect_a) return D3DERR_INVALIDCALL;
    gaddr base; uint32_t dpitch, dw, dh, dfmt;
    if (!gp_d3d9_surface_mirror(dst, &base, &dpitch, &dw, &dh, &dfmt)) return D3DERR_INVALIDCALL;
    if (is_dxt(sfmt)) {
        irect sr = read_rect(srect_a, 0, 0), dr = read_rect(A(2), dw, dh);
        int32_t sw = sr.r - sr.l, sh = sr.b - sr.t;
        if (sw != dr.r - dr.l || sh != dr.b - dr.t || key) gp_fatal("D3DXLoadSurfaceFromMemory: scaled or colour-keyed DXT source");
        if (sfmt == dfmt || ((sfmt == D3DFMT_DXT2 || sfmt == D3DFMT_DXT3) && (dfmt == D3DFMT_DXT2 || dfmt == D3DFMT_DXT3))
                         || ((sfmt == D3DFMT_DXT4 || sfmt == D3DFMT_DXT5) && (dfmt == D3DFMT_DXT4 || dfmt == D3DFMT_DXT5))) {
            /* same encoding: copy whole blocks */
            uint32_t bb = dxt_block_bytes(sfmt), bw = ((uint32_t)sw + 3) / 4, bh = ((uint32_t)sh + 3) / 4;
            for (uint32_t y = 0; y < bh; y++)
                memcpy((uint8_t *)G(base) + (size_t)(dr.t / 4 + (int32_t)y) * dpitch + (size_t)(dr.l / 4) * bb,
                       (const uint8_t *)G(src) + (size_t)(sr.t / 4 + (int32_t)y) * spitch + (size_t)(sr.l / 4) * bb, bw * bb);
        } else if (decodable(dfmt)) {
            uint32_t bb = dxt_block_bytes(sfmt);
            for (int32_t by = 0; by < (sh + 3) / 4; by++)
                for (int32_t bx = 0; bx < (sw + 3) / 4; bx++) {
                    float px[16][4];
                    dxt_decode_block(sfmt, (const uint8_t *)G(src) + (size_t)(sr.t / 4 + by) * spitch + (size_t)(sr.l / 4 + bx) * bb, px);
                    for (int i = 0; i < 16; i++) {
                        int32_t x = bx * 4 + (i & 3), y = by * 4 + i / 4;
                        if (x >= sw || y >= sh) continue;
                        encode(dfmt, (uint8_t *)G(base) + (size_t)(dr.t + y) * dpitch + (size_t)(dr.l + x) * bpp(dfmt), px[i]);
                    }
                }
        } else gp_fatal("D3DXLoadSurfaceFromMemory: DXT format %08x into format %u", sfmt, dfmt);
        gp_d3d9_surface_commit(dst);
        return D3D_OK;
    }
    if (!decodable(sfmt)) gp_fatal("D3DXLoadSurfaceFromMemory from format %u", sfmt);
    if (!decodable(dfmt)) gp_fatal("D3DXLoadSurfaceFromMemory into format %u", dfmt);
    irect sr = read_rect(srect_a, 0, 0), dr = read_rect(A(2), dw, dh);
    int32_t sw = sr.r - sr.l, sh = sr.b - sr.t, ow = dr.r - dr.l, oh = dr.b - dr.t;
    if (sw <= 0 || sh <= 0 || ow <= 0 || oh <= 0 || dr.r > (int32_t)dw || dr.b > (int32_t)dh) { gp_d3d9_surface_commit(dst); return D3DERR_INVALIDCALL; }
    float kc[4] = {0};
    if (key) { kc[0] = ((key >> 16) & 255) / 255.f; kc[1] = ((key >> 8) & 255) / 255.f; kc[2] = (key & 255) / 255.f; kc[3] = (key >> 24) / 255.f; }
    bool point = (filter & 0xff) == 2 || (filter & 0xff) == 1 || (sw == ow && sh == oh);   /* D3DX_FILTER_NONE/POINT */
    for (int32_t y = 0; y < oh; y++) {
        uint8_t *drow = (uint8_t *)G(base) + (size_t)(dr.t + y) * dpitch + (size_t)dr.l * bpp(dfmt);
        for (int32_t x = 0; x < ow; x++) {
            float c[4] = {0};
            if (point) {
                int32_t sx = sr.l + (int32_t)((int64_t)x * sw / ow), sy = sr.t + (int32_t)((int64_t)y * sh / oh);
                decode(sfmt, (const uint8_t *)G(src) + (size_t)sy * spitch + (size_t)sx * bpp(sfmt), c);
            } else {                                                 /* box filter over the covered source area */
                int32_t x0 = sr.l + (int32_t)((int64_t)x * sw / ow), x1 = sr.l + (int32_t)((int64_t)(x + 1) * sw / ow);
                int32_t y0 = sr.t + (int32_t)((int64_t)y * sh / oh), y1 = sr.t + (int32_t)((int64_t)(y + 1) * sh / oh);
                if (x1 <= x0) x1 = x0 + 1;
                if (y1 <= y0) y1 = y0 + 1;
                int n = 0;
                for (int32_t yy = y0; yy < y1; yy++) for (int32_t xx = x0; xx < x1; xx++) {
                    float s[4];
                    decode(sfmt, (const uint8_t *)G(src) + (size_t)yy * spitch + (size_t)xx * bpp(sfmt), s);
                    for (int k = 0; k < 4; k++) c[k] += s[k];
                    n++;
                }
                for (int k = 0; k < 4; k++) c[k] /= (float)n;
            }
            if (key && fabsf(c[0] - kc[0]) < 0.5f / 255 && fabsf(c[1] - kc[1]) < 0.5f / 255 && fabsf(c[2] - kc[2]) < 0.5f / 255 && fabsf(c[3] - kc[3]) < 0.5f / 255)
                c[0] = c[1] = c[2] = c[3] = 0;                        /* colour key: transparent black */
            encode(dfmt, drow + (size_t)x * bpp(dfmt), c);
        }
    }
    gp_d3d9_surface_commit(dst);
    return D3D_OK;
}

static uint32_t D3DXPlaneTransform_(gp_thread *t)
{
    /* (pOut, pP, pM): row vector (a b c d) times M */
    float p[4], m[16], o[4];
    memcpy(p, G(A(1)), 16); memcpy(m, G(A(2)), 64);
    for (int j = 0; j < 4; j++) o[j] = p[0] * m[j] + p[1] * m[4 + j] + p[2] * m[8 + j] + p[3] * m[12 + j];
    memcpy(G(A(0)), o, 16);
    return A(0);
}

/* screenshots: the game's own "save screenshot" feature */
static uint32_t save_surface(gaddr path, uint32_t ifmt, gaddr surf)
{
    gaddr base; uint32_t pitch, w, h, fmt;
    gp_d3d9_flush_and_wait();
    if (!gp_d3d9_surface_mirror(surf, &base, &pitch, &w, &h, &fmt) || !decodable(fmt)) return D3DERR_INVALIDCALL;
    uint8_t *rgba = malloc((size_t)w * h * 4);
    for (uint32_t y = 0; y < h; y++) for (uint32_t x = 0; x < w; x++) {
        float c[4];
        decode(fmt, (const uint8_t *)G(base) + (size_t)y * pitch + (size_t)x * bpp(fmt), c);
        for (int k = 0; k < 3; k++) rgba[4 * ((size_t)y * w + x) + (size_t)k] = (uint8_t)q(c[k], 255);
        rgba[4 * ((size_t)y * w + x) + 3] = 255;
    }
    gp_d3d9_surface_commit(surf);
    char *host = gp_path_to_host(gstr(path));
    uint32_t hr = D3DERR_INVALIDCALL;
    if (host) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(rgba, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        CFStringRef type = ifmt == 1 ? (__bridge CFStringRef)UTTypeJPEG.identifier : ifmt == 3 ? (__bridge CFStringRef)UTTypePNG.identifier
                         : ifmt == 2 ? CFSTR("com.truevision.tga-image") : (__bridge CFStringRef)UTTypeBMP.identifier;
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)host, (CFIndex)strlen(host), false);
        CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, type, 1, NULL);
        if (d) { CGImageDestinationAddImage(d, img, NULL); if (CGImageDestinationFinalize(d)) hr = D3D_OK; CFRelease(d); }
        CFRelease(url); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
        free(host);
    }
    free(rgba);
    return hr;
}
static uint32_t D3DXSaveSurfaceToFileA_(gp_thread *t) { return save_surface(A(0), A(1), A(2)); }   /* (file, format, surface, palette, rect) */
static uint32_t D3DXSaveTextureToFileA_(gp_thread *t)
{
    /* (file, format, texture, palette): level 0 */
    gaddr tex = A(2);
    gaddr s = gp_d3d9_level0_surface(tex);
    uint32_t hr = save_surface(A(0), A(1), s);
    gp_d3d9_release(s);
    return hr;
}

#undef DLL
#define DLL "d3dx9_27.dll"
const gp_api gp_api_d3dx9_util[] = {
    API(D3DXLoadSurfaceFromMemory_, "D3DXLoadSurfaceFromMemory", 10), API(D3DXPlaneTransform_, "D3DXPlaneTransform", 3),
    API(D3DXSaveSurfaceToFileA_, "D3DXSaveSurfaceToFileA", 5), API(D3DXSaveTextureToFileA_, "D3DXSaveTextureToFileA", 4),
    { 0 }
};
