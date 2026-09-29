/* Direct3D 9 on Metal 4: shared device state. */
#ifndef GP_D3D9_H
#define GP_D3D9_H
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "gp_api.h"

#define D3D_OK 0
#define D3DERR_INVALIDCALL 0x8876086Cu
#define D3DERR_NOTAVAILABLE 0x8876086Au
#define D3DERR_OUTOFVIDEOMEMORY 0x8876017Cu
#define E_NOINTERFACE 0x80004002u

/* D3DFORMAT values used by the game */
enum {
    D3DFMT_UNKNOWN = 0, D3DFMT_R8G8B8 = 20, D3DFMT_A8R8G8B8 = 21, D3DFMT_X8R8G8B8 = 22, D3DFMT_R5G6B5 = 23,
    D3DFMT_X1R5G5B5 = 24, D3DFMT_A1R5G5B5 = 25, D3DFMT_A4R4G4B4 = 26, D3DFMT_A8 = 28, D3DFMT_A2B10G10R10 = 31,
    D3DFMT_A8B8G8R8 = 32, D3DFMT_X8B8G8R8 = 33, D3DFMT_G16R16 = 34, D3DFMT_A2R10G10B10 = 35, D3DFMT_A16B16G16R16 = 36,
    D3DFMT_L8 = 50, D3DFMT_A8L8 = 51, D3DFMT_V8U8 = 60, D3DFMT_Q8W8V8U8 = 63, D3DFMT_L16 = 81,
    D3DFMT_D16_LOCKABLE = 70, D3DFMT_D32 = 71, D3DFMT_D24S8 = 75, D3DFMT_D24X8 = 77, D3DFMT_D16 = 80,
    D3DFMT_D32F_LOCKABLE = 82, D3DFMT_D24FS8 = 83,
    D3DFMT_INDEX16 = 101, D3DFMT_INDEX32 = 102, D3DFMT_VERTEXDATA = 100,
    D3DFMT_R16F = 111, D3DFMT_G16R16F = 112, D3DFMT_A16B16G16R16F = 113, D3DFMT_R32F = 114, D3DFMT_G32R32F = 115,
    D3DFMT_A32B32G32R32F = 116,
};
#define FOURCC(a, b, c, d) ((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24))
#define D3DFMT_DXT1 FOURCC('D', 'X', 'T', '1')
#define D3DFMT_DXT2 FOURCC('D', 'X', 'T', '2')
#define D3DFMT_DXT3 FOURCC('D', 'X', 'T', '3')
#define D3DFMT_DXT4 FOURCC('D', 'X', 'T', '4')
#define D3DFMT_DXT5 FOURCC('D', 'X', 'T', '5')

typedef struct {
    MTLPixelFormat mtl;
    uint32_t bytes_per_block, block;    /* block = 1 for linear formats, 4 for DXT */
    bool depth, stencil, swizzle_bgrx;  /* swizzle: X8 formats read alpha as 1 */
    bool convert16;                     /* 16-bit formats unpacked to BGRA8 on upload */
} gp_format;

const gp_format *gp_format_info(uint32_t d3dfmt);   /* NULL if unsupported */

extern id<MTLDevice> gp_mtl;

#endif
