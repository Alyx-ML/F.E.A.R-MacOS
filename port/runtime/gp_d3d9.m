/* d3d9.dll: IDirect3D9 and device creation/presentation on Metal 4.
 * One adapter (the Mac's GPU); one device; frames in flight throttled by a
 * shared event. Unimplemented device methods trap with their names. */
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import <CoreServices/CoreServices.h>
#include "gp_d3d9.h"
#include "gp_d3d9_device.h"
#include "gp_win.h"
#include "gp_window.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

id<MTLDevice> gp_mtl;

/* ---------------------------------------------------------------- formats */
static const struct { uint32_t d3d; gp_format f; } formats[] = {
    { D3DFMT_A8R8G8B8, { .mtl = MTLPixelFormatBGRA8Unorm, .bytes_per_block = 4, .block = 1 } },
    { D3DFMT_X8R8G8B8, { .mtl = MTLPixelFormatBGRA8Unorm, .bytes_per_block = 4, .block = 1, .swizzle_bgrx = true } },
    { D3DFMT_A8B8G8R8, { .mtl = MTLPixelFormatRGBA8Unorm, .bytes_per_block = 4, .block = 1 } },
    { D3DFMT_X8B8G8R8, { .mtl = MTLPixelFormatRGBA8Unorm, .bytes_per_block = 4, .block = 1, .swizzle_bgrx = true } },
    { D3DFMT_A2R10G10B10, { .mtl = MTLPixelFormatBGR10A2Unorm, .bytes_per_block = 4, .block = 1 } },
    { D3DFMT_A2B10G10R10, { .mtl = MTLPixelFormatRGB10A2Unorm, .bytes_per_block = 4, .block = 1 } },
    { D3DFMT_R5G6B5, { .mtl = MTLPixelFormatBGRA8Unorm, .bytes_per_block = 2, .block = 1, .convert16 = true } },
    { D3DFMT_X1R5G5B5, { .mtl = MTLPixelFormatBGRA8Unorm, .bytes_per_block = 2, .block = 1, .convert16 = true } },
    { D3DFMT_A1R5G5B5, { .mtl = MTLPixelFormatBGRA8Unorm, .bytes_per_block = 2, .block = 1, .convert16 = true } },
    { D3DFMT_A4R4G4B4, { .mtl = MTLPixelFormatBGRA8Unorm, .bytes_per_block = 2, .block = 1, .convert16 = true } },
    { D3DFMT_A8, { .mtl = MTLPixelFormatA8Unorm, .bytes_per_block = 1, .block = 1 } },
    { D3DFMT_L8, { .mtl = MTLPixelFormatR8Unorm, .bytes_per_block = 1, .block = 1 } },
    { D3DFMT_A8L8, { .mtl = MTLPixelFormatRG8Unorm, .bytes_per_block = 2, .block = 1 } },
    { D3DFMT_L16, { .mtl = MTLPixelFormatR16Unorm, .bytes_per_block = 2, .block = 1 } },
    { D3DFMT_V8U8, { .mtl = MTLPixelFormatRG8Snorm, .bytes_per_block = 2, .block = 1 } },
    { D3DFMT_Q8W8V8U8, { .mtl = MTLPixelFormatRGBA8Snorm, .bytes_per_block = 4, .block = 1 } },
    { D3DFMT_G16R16, { .mtl = MTLPixelFormatRG16Unorm, .bytes_per_block = 4, .block = 1 } },
    { D3DFMT_A16B16G16R16, { .mtl = MTLPixelFormatRGBA16Unorm, .bytes_per_block = 8, .block = 1 } },
    { D3DFMT_R16F, { .mtl = MTLPixelFormatR16Float, .bytes_per_block = 2, .block = 1 } },
    { D3DFMT_G16R16F, { .mtl = MTLPixelFormatRG16Float, .bytes_per_block = 4, .block = 1 } },
    { D3DFMT_A16B16G16R16F, { .mtl = MTLPixelFormatRGBA16Float, .bytes_per_block = 8, .block = 1 } },
    { D3DFMT_R32F, { .mtl = MTLPixelFormatR32Float, .bytes_per_block = 4, .block = 1 } },
    { D3DFMT_G32R32F, { .mtl = MTLPixelFormatRG32Float, .bytes_per_block = 8, .block = 1 } },
    { D3DFMT_A32B32G32R32F, { .mtl = MTLPixelFormatRGBA32Float, .bytes_per_block = 16, .block = 1 } },
    { D3DFMT_DXT1, { .mtl = MTLPixelFormatBC1_RGBA, .bytes_per_block = 8, .block = 4 } },
    { D3DFMT_DXT2, { .mtl = MTLPixelFormatBC2_RGBA, .bytes_per_block = 16, .block = 4 } },
    { D3DFMT_DXT3, { .mtl = MTLPixelFormatBC2_RGBA, .bytes_per_block = 16, .block = 4 } },
    { D3DFMT_DXT4, { .mtl = MTLPixelFormatBC3_RGBA, .bytes_per_block = 16, .block = 4 } },
    { D3DFMT_DXT5, { .mtl = MTLPixelFormatBC3_RGBA, .bytes_per_block = 16, .block = 4 } },
    { D3DFMT_D24S8, { .mtl = MTLPixelFormatDepth32Float_Stencil8, .bytes_per_block = 4, .block = 1, .depth = true, .stencil = true } },
    { D3DFMT_D24X8, { .mtl = MTLPixelFormatDepth32Float_Stencil8, .bytes_per_block = 4, .block = 1, .depth = true } },
    { D3DFMT_D24FS8, { .mtl = MTLPixelFormatDepth32Float_Stencil8, .bytes_per_block = 4, .block = 1, .depth = true, .stencil = true } },
    { D3DFMT_D16, { .mtl = MTLPixelFormatDepth32Float_Stencil8, .bytes_per_block = 2, .block = 1, .depth = true } },
    { D3DFMT_D32, { .mtl = MTLPixelFormatDepth32Float_Stencil8, .bytes_per_block = 4, .block = 1, .depth = true } },
};

const gp_format *gp_format_info(uint32_t d3d)
{
    for (size_t i = 0; i < sizeof formats / sizeof *formats; i++) if (formats[i].d3d == d3d) return &formats[i].f;
    return NULL;
}

/* ---------------------------------------------------------- IDirect3D9 */
static const char *const d3d9_methods[] = { "QueryInterface", "AddRef", "Release", "RegisterSoftwareDevice",
    "GetAdapterCount", "GetAdapterIdentifier", "GetAdapterModeCount", "EnumAdapterModes", "GetAdapterDisplayMode",
    "CheckDeviceType", "CheckDeviceFormat", "CheckDeviceMultiSampleType", "CheckDepthStencilMatch",
    "CheckDeviceFormatConversion", "GetDeviceCaps", "GetAdapterMonitor", "CreateDevice" };
static gaddr d3d9_vt;

static bool init_metal(void)
{
    if (gp_mtl) return true;
    gp_mtl = MTLCreateSystemDefaultDevice();
    if (!gp_mtl) { gp_log("Metal: no GPU device is available to this process"); return false; }
    if (![gp_mtl supportsFamily:MTLGPUFamilyMetal4]) gp_fatal("Metal: %s does not support Metal 4", gp_mtl.name.UTF8String);
    return true;
}

static uint32_t Direct3DCreate9_(gp_thread *t)
{
    if (A(0) != 32) gp_log("Direct3DCreate9: SDK version %u (expected 32)", A(0));
    if (!init_metal()) return 0;          /* Windows returns NULL when D3D cannot be created */
    if (!d3d9_vt) d3d9_vt = gp_com_vtable("IDirect3D9", d3d9_methods, 17);
    return gp_com_new(d3d9_vt, 0);
}

static uint32_t AddRef_(gp_thread *t) { uint32_t r = rd32(A(0) + 4) + 1; wr32(A(0) + 4, r); return r; }
static uint32_t ReleaseD3D_(gp_thread *t)
{
    uint32_t r = rd32(A(0) + 4) - 1;
    wr32(A(0) + 4, r);
    if (!r) gp_heap_free(A(0));
    return r;
}

static uint32_t GetAdapterCount_(gp_thread *t) { (void)t; return 1; }

static uint32_t GetAdapterIdentifier_(gp_thread *t)
{
    /* D3DADAPTER_IDENTIFIER9 (1100 bytes): the real GPU name; Apple's PCI vendor id */
    gaddr p = A(3);
    if (A(1) != 0) return D3DERR_INVALIDCALL;
    memset(G(p), 0, 1100);
    strcpy((char *)G(p), "Metal");
    snprintf((char *)G(p + 512), 512, "%s", gp_mtl.name.UTF8String);
    wr32(p + 1024, 0x00070000u); wr32(p + 1028, 0);          /* DriverVersion 7.0 */
    wr32(p + 1032, 0x106B);                                  /* VendorId */
    wr32(p + 1036, (uint32_t)(gp_mtl.registryID & 0xffff));  /* DeviceId */
    uint64_t id = gp_mtl.registryID;
    memcpy(G(p + 1048), &id, 8);                             /* DeviceIdentifier GUID */
    wr32(p + 1064, 1);                                       /* WHQLLevel */
    return D3D_OK;
}

/* display modes: the classic 4:3/16:10/16:9 sizes up to the display, plus the display itself */
static int modes(uint32_t (*out)[2], int cap)
{
    uint32_t dw, dh;
    gp_display_size(&dw, &dh);
    static const uint32_t list[][2] = { {640,480},{800,600},{1024,768},{1152,864},{1280,720},{1280,768},{1280,800},
        {1280,960},{1280,1024},{1360,768},{1440,900},{1600,900},{1600,1200},{1680,1050},{1920,1080},{1920,1200},
        {2560,1440},{2560,1600},{3840,2160} };
    int n = 0;
    for (size_t i = 0; i < sizeof list / sizeof *list && n < cap; i++)
        if (list[i][0] <= dw && list[i][1] <= dh && !(list[i][0] == dw && list[i][1] == dh)) { out[n][0] = list[i][0]; out[n][1] = list[i][1]; n++; }
    if (n < cap) { out[n][0] = dw; out[n][1] = dh; n++; }
    return n;
}
static bool display_format(uint32_t f) { return f == D3DFMT_X8R8G8B8 || f == D3DFMT_A8R8G8B8; }

static uint32_t GetAdapterModeCount_(gp_thread *t)
{
    uint32_t m[32][2];
    return A(1) == 0 && display_format(A(2)) ? (uint32_t)modes(m, 32) : 0;
}
static uint32_t EnumAdapterModes_(gp_thread *t)
{
    /* (this, adapter, format, mode, D3DDISPLAYMODE*) */
    uint32_t m[32][2];
    int n = modes(m, 32);
    if (A(1) != 0 || !display_format(A(2)) || A(3) >= (uint32_t)n) return D3DERR_INVALIDCALL;
    gaddr p = A(4);
    wr32(p, m[A(3)][0]); wr32(p + 4, m[A(3)][1]); wr32(p + 8, 60); wr32(p + 12, A(2));
    return D3D_OK;
}
static uint32_t GetAdapterDisplayMode_(gp_thread *t)
{
    uint32_t w, h;
    gp_display_size(&w, &h);
    gaddr p = A(2);
    wr32(p, w); wr32(p + 4, h); wr32(p + 8, 60); wr32(p + 12, D3DFMT_X8R8G8B8);
    return D3D_OK;
}
static uint32_t CheckDeviceType_(gp_thread *t)
{
    /* (this, adapter, devtype, adapterFormat, backBufferFormat, windowed) */
    if (A(2) != 1) return D3DERR_NOTAVAILABLE;              /* only D3DDEVTYPE_HAL */
    if (!display_format(A(3))) return D3DERR_NOTAVAILABLE;
    if (A(4) && !display_format(A(4))) return D3DERR_NOTAVAILABLE;
    return D3D_OK;
}

enum { USAGE_RENDERTARGET = 1, USAGE_DEPTHSTENCIL = 2, USAGE_AUTOGENMIPMAP = 0x400, USAGE_QUERY_FILTER = 0x20000,
       USAGE_QUERY_POSTPIXELSHADER_BLENDING = 0x80000, USAGE_QUERY_VERTEXTEXTURE = 0x100000,
       USAGE_QUERY_SRGBREAD = 0x10000, USAGE_QUERY_SRGBWRITE = 0x40000 };

static uint32_t CheckDeviceFormat_(gp_thread *t)
{
    /* (this, adapter, devtype, adapterFormat, usage, rtype, checkFormat) */
    uint32_t usage = A(4), rtype = A(5), fmt = A(6);
    const gp_format *f = gp_format_info(fmt);
    if (!f) return D3DERR_NOTAVAILABLE;
    if (usage & USAGE_DEPTHSTENCIL) return f->depth ? D3D_OK : D3DERR_NOTAVAILABLE;
    if (f->depth) return (rtype == 3 /* texture: shadow maps */ || rtype == 1) ? D3D_OK : D3DERR_NOTAVAILABLE;
    if ((usage & USAGE_RENDERTARGET) && (f->block != 1 || f->convert16)) return D3DERR_NOTAVAILABLE;
    if ((usage & USAGE_QUERY_VERTEXTEXTURE) && fmt != D3DFMT_R32F && fmt != D3DFMT_A32B32G32R32F) return D3DERR_NOTAVAILABLE;
    if ((usage & USAGE_QUERY_POSTPIXELSHADER_BLENDING) && (fmt == D3DFMT_R32F || fmt == D3DFMT_G32R32F || fmt == D3DFMT_A32B32G32R32F))
        return D3D_OK;                                      /* Apple GPUs blend 32-bit float targets */
    return D3D_OK;
}
static uint32_t CheckDeviceMultiSampleType_(gp_thread *t)
{
    /* (this, adapter, devtype, surfaceFormat, windowed, msType, *quality) */
    uint32_t ms = A(5);
    bool ok = ms == 0 || ((ms == 2 || ms == 4) && [gp_mtl supportsTextureSampleCount:ms]);
    if (A(6)) wr32(A(6), 1);
    return ok ? D3D_OK : D3DERR_NOTAVAILABLE;
}
static uint32_t CheckDepthStencilMatch_(gp_thread *t)
{
    const gp_format *d = gp_format_info(A(5));
    return d && d->depth ? D3D_OK : D3DERR_NOTAVAILABLE;
}

void gp_d3d9_fill_caps(gaddr c)
{
    memset(G(c), 0, 304);
    float f;
    wr32(c + 0, 1);                                          /* D3DDEVTYPE_HAL */
    wr32(c + 8, 0x00020000);                                 /* Caps: READ_SCANLINE */
    wr32(c + 12, 0x20000000 | 0x40000000 | 0x00020000);      /* Caps2: CANAUTOGENMIPMAP, CANSHARERESOURCE, DYNAMICTEXTURES */
    wr32(c + 16, 0x00000020 | 0x00000080 | 0x00000100 | 0x00000200); /* Caps3: ALPHA_FULLSCREEN_FLIP_OR_DISCARD, LINEAR_TO_SRGB, COPY_TO_VIDMEM, COPY_TO_SYSTEMMEM */
    wr32(c + 20, 0x80000000u | 1 | 2);                       /* intervals: IMMEDIATE, ONE, TWO */
    wr32(c + 28, 0x001BBEF0);                                /* DevCaps: HW T&L, PUREDEVICE, DRAWPRIMITIVES2EX, ... */
    wr32(c + 32, 0x000FCFF2);                                /* PrimitiveMiscCaps: MASKZ, CULL*, COLORWRITEENABLE, CLIP*, TSSARGTEMP, BLENDOP, INDEPENDENTWRITEMASKS, PERSTAGECONSTANT, FOGANDSPECULARALPHA, SEPARATEALPHABLEND, MRTINDEPENDENTBITDEPTHS, MRTPOSTPIXELSHADERBLENDING */
    wr32(c + 36, 0x07732191);                                /* RasterCaps: DITHER, ZTEST, FOGTABLE, MIPMAPLODBIAS, SCISSORTEST, SLOPESCALEDEPTHBIAS, DEPTHBIAS, ANISOTROPY */
    wr32(c + 40, 0xff); wr32(c + 52, 0xff);                  /* Z/alpha compare: all */
    wr32(c + 44, 0x3fff); wr32(c + 48, 0x3fff);              /* blend factors */
    wr32(c + 56, 0x00084208);                                /* ShadeCaps */
    wr32(c + 60, 0x0001EC45);                                /* TextureCaps: PERSPECTIVE, ALPHA, PROJECTED, CUBEMAP, VOLUMEMAP, MIPMAP..., POW2 not required */
    wr32(c + 64, 0x07030700); wr32(c + 68, 0x07030700); wr32(c + 72, 0x07030700);
    wr32(c + 76, 0x3f); wr32(c + 80, 0x3f);                  /* address modes incl. border, mirroronce */
    wr32(c + 84, 0x1f);
    wr32(c + 88, 8192); wr32(c + 92, 8192); wr32(c + 96, 2048);
    wr32(c + 100, 8192); wr32(c + 104, 8192); wr32(c + 108, 16);
    f = 1e10f; memcpy(G(c + 112), &f, 4);
    f = -1e8f; memcpy(G(c + 116), &f, 4); memcpy(G(c + 120), &f, 4);
    f = 1e8f; memcpy(G(c + 124), &f, 4); memcpy(G(c + 128), &f, 4);
    wr32(c + 136, 0x1ff);                                    /* StencilCaps incl. TWOSIDED */
    wr32(c + 140, 0x00180008);                               /* FVFCaps: 8 tex coords, PSIZE */
    wr32(c + 144, 0x03FFFFFF);
    wr32(c + 148, 8); wr32(c + 152, 8);
    wr32(c + 156, 0x0000017B);                               /* VertexProcessingCaps */
    wr32(c + 160, 8); wr32(c + 164, 6); wr32(c + 168, 4); wr32(c + 172, 0);
    f = 8192.0f; memcpy(G(c + 176), &f, 4);
    wr32(c + 180, 0x00ffffff); wr32(c + 184, 0x00ffffff);
    wr32(c + 188, 16); wr32(c + 192, 255);
    wr32(c + 196, 0xFFFE0300);                               /* vs_3_0 */
    wr32(c + 200, 256);
    wr32(c + 204, 0xFFFF0300);                               /* ps_3_0 */
    f = 65504.0f; memcpy(G(c + 208), &f, 4);
    wr32(c + 212, 0x51);                                     /* DevCaps2: STREAMOFFSET, VERTEXELEMENTSCANSHARESTREAMOFFSET, CAN_STRETCHRECT_FROM_TEXTURES */
    wr32(c + 232, 1);
    wr32(c + 236, 0x30f);                                    /* DeclTypes: UBYTE4, UBYTE4N, SHORT2N, SHORT4N, FLOAT16_2/4 */
    wr32(c + 240, 4);                                        /* NumSimultaneousRTs */
    wr32(c + 244, 0x03000300);                               /* StretchRect point/linear min/mag */
    wr32(c + 248, 1); wr32(c + 252, 24); wr32(c + 256, 32); wr32(c + 260, 4);          /* VS20Caps */
    wr32(c + 264, 0x1f); wr32(c + 268, 24); wr32(c + 272, 32); wr32(c + 276, 4); wr32(c + 280, 512);  /* PS20Caps */
    wr32(c + 284, 0x03000300);
    wr32(c + 288, 0xffff); wr32(c + 292, 0xffff);
    wr32(c + 296, 32768); wr32(c + 300, 32768);
}
static uint32_t GetDeviceCaps_(gp_thread *t)
{
    if (A(1) != 0 || A(2) != 1) return D3DERR_INVALIDCALL;
    gp_d3d9_fill_caps(A(3));
    return D3D_OK;
}
static uint32_t GetAdapterMonitor_(gp_thread *t) { (void)t; return 0x00090001u; }
static uint32_t QueryInterfaceD3D_(gp_thread *t) { wr32(A(2), 0); return E_NOINTERFACE; }

static uint32_t CreateDevice_(gp_thread *t)
{
    /* (this, adapter, devtype, hFocusWindow, behaviorFlags, D3DPRESENT_PARAMETERS*, IDirect3DDevice9**) */
    if (A(1) != 0 || A(2) != 1) return D3DERR_INVALIDCALL;
    gaddr dev = gp_d3d9_create_device(t, A(0), A(3), A(4), A(5));
    if (!dev) return D3DERR_NOTAVAILABLE;
    wr32(A(6), dev);
    return D3D_OK;
}

#undef DLL
#define DLL "d3d9.dll"
const gp_api gp_api_d3d9[] = { API(Direct3DCreate9_, "Direct3DCreate9", 1), { 0 } };
#undef DLL
#define DLL "IDirect3D9"
const gp_api gp_api_idirect3d9[] = {
    API(QueryInterfaceD3D_, "QueryInterface", 3), API(AddRef_, "AddRef", 1), API(ReleaseD3D_, "Release", 1),
    API(GetAdapterCount_, "GetAdapterCount", 1), API(GetAdapterIdentifier_, "GetAdapterIdentifier", 4),
    API(GetAdapterModeCount_, "GetAdapterModeCount", 3), API(EnumAdapterModes_, "EnumAdapterModes", 5),
    API(GetAdapterDisplayMode_, "GetAdapterDisplayMode", 3), API(CheckDeviceType_, "CheckDeviceType", 6),
    API(CheckDeviceFormat_, "CheckDeviceFormat", 7), API(CheckDeviceMultiSampleType_, "CheckDeviceMultiSampleType", 7),
    API(CheckDepthStencilMatch_, "CheckDepthStencilMatch", 6), API(GetDeviceCaps_, "GetDeviceCaps", 4),
    API(GetAdapterMonitor_, "GetAdapterMonitor", 2), API(CreateDevice_, "CreateDevice", 7),
    { 0 }
};
