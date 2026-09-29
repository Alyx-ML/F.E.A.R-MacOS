/* Direct3D 9 device internals shared by the device, resource and shader files. */
#ifndef GP_D3D9_DEVICE_H
#define GP_D3D9_DEVICE_H
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "gp_d3d9.h"

/* Host-side resources. Guest COM objects are {vtable, refs, host index, device}. */
enum { R_SURFACE = 1, R_TEXTURE, R_CUBE, R_VOLUME, R_VB, R_IB, R_VDECL, R_VS, R_PS, R_QUERY, R_STATEBLOCK };

typedef struct gp_res {
    int kind;
    gaddr obj;                     /* guest COM object */
    uint32_t format, usage, pool, width, height, depth, levels;
    const gp_format *fmt;
    id<MTLTexture> tex;            /* textures, render targets, depth surfaces */
    id<MTLBuffer> buf;             /* vertex/index buffers (shared storage, guest-visible copy below) */
    gaddr sysmem;                  /* guest memory mirror for Lock (buffers, lockable surfaces, textures) */
    uint32_t size;
    /* surface: which texture level/face it views; owner resource index (0 = standalone) */
    uint32_t owner, level, face;
    gaddr level_surfaces;          /* texture: guest array of surface objects per (face, level), created lazily */
    bool dirty_upload;             /* sysmem changed; upload before GPU use */
    bool locked;
    uint32_t lock_level, lock_face, lock_flags;
    void *priv;                    /* shader / decl / query payload */
} gp_res;

gp_res *gp_res_get(gaddr obj, int kind);       /* kind 0: any; traps on invalid objects */
uint32_t gp_res_new(gp_res r);                  /* returns index */
gp_res *gp_res_at(uint32_t index);
gaddr gp_d3d9_new_object(const char *iface, uint32_t index);
gaddr gp_d3d9_vtable(const char *iface);

gaddr gp_d3d9_create_device(gp_thread *t, gaddr d3d, uint32_t hwnd, uint32_t behavior, gaddr pp);
void gp_d3d9_fill_caps(gaddr caps);

/* device-wide Metal objects */
extern id<MTLResidencySet> gp_residency;
void gp_residency_add(id<MTLAllocation> a);
void gp_residency_remove(id<MTLAllocation> a);

#endif
