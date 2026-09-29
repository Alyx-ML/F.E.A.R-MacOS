/* Direct3D 9 device state. */
#ifndef GP_D3D9_STATE_H
#define GP_D3D9_STATE_H
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "gp_d3d9_device.h"

#define FRAMES 3

/* Metal 4 tracks no hazards: everything an earlier encoder wrote (render targets, uploads, copies) must be
   made visible to each new encoder. Emitted first on every encoder; narrow it once rendering is verified. */
#define GP_SYNC_BARRIER(enc) [(enc) barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice]

typedef struct { uint32_t x, y, w, h; float minz, maxz; } d3d_viewport;
typedef struct { int32_t l, t, r, b; } d3d_rect;

typedef struct {
    /* Metal */
    id<MTL4CommandQueue> queue;
    id<MTL4CommandAllocator> alloc[FRAMES];
    id<MTL4CommandBuffer> cmd;
    id<MTLSharedEvent> frame_event;
    uint64_t frame_serial;
    bool recording;
    id<MTL4RenderCommandEncoder> enc;
    uint32_t pass_w, pass_h, pass_draws;
    bool pass_invalid;
    CAMetalLayer *layer;
    /* presentation */
    uint32_t focus_hwnd, hwnd, behavior, width, height, bb_format, auto_depth_format, interval;
    bool windowed, in_scene;
    uint32_t backbuffer, auto_depth;
    uint16_t gamma[768];
    bool gamma_set;
    /* bindings */
    uint32_t rt[4], ds;
    d3d_viewport viewport;
    d3d_rect scissor;
    uint32_t rs[256];                 /* D3DRENDERSTATETYPE */
    uint32_t ss[21][14];              /* samplers 0..15, 16 = D3DDMAPSAMPLER, 17..20 = VERTEXTEXTURESAMPLER0..3 */
    uint32_t tss[8][33];
    uint32_t textures[21];            /* resource indices, same slots as ss */
    float transforms[512][16];
    float clip_planes[6][4];
    uint8_t material[68];
    float vs_const[256][4], ps_const[224][4];
    int32_t vs_const_i[16][4], ps_const_i[16][4];
    uint32_t vs_const_b[16], ps_const_b[16];
    uint32_t vs, ps, vdecl, fvf, indices;
    struct { uint32_t vb, offset, stride, freq; } streams[16];
} gp_dev;
extern gp_dev D;

void gp_d3d9_state_defaults(void);
void gp_d3d9_frame_begin(void);
void gp_d3d9_begin_frame(void);   /* opens the frame's command buffer if none is recording */
void gp_d3d9_frame_end(void);
void gp_d3d9_state_release(void);
void gp_d3d9_pass_opened(void);
void gp_d3d9_begin_pass(bool clear_color, uint32_t color, bool clear_depth, float z, bool clear_stencil, uint32_t stencil);
void gp_d3d9_end_pass(void);
void gp_d3d9_flush_and_wait(void);
id<MTL4ComputeCommandEncoder> gp_d3d9_blit_encoder(void);
uint32_t gp_d3d9_clear_rects(uint32_t count, gaddr rects, uint32_t flags, uint32_t color, float z, uint32_t stencil);
void gp_d3d9_log_backbuffer_stats(uint64_t frame);
uint32_t gp_d3d9_new_surface(uint32_t format, uint32_t w, uint32_t h, uint32_t usage, bool rt);

/* per-frame transient GPU memory (constants, user-pointer vertices) */
uint64_t gp_transient(const void *data, uint32_t size, uint32_t align, void **cpu);
id<MTLBuffer> gp_transient_buffer(const void *cpu, uint32_t *offset);
void gp_d3d9_release_texture_later(id<MTLTexture> tex);
uint64_t gp_d3d9_buffer_gpu(gp_res *r);
uint32_t gp_d3d9_release(gaddr obj);
uint32_t gp_d3d9_addref(gaddr obj);
void gp_d3d9_bind(uint32_t *slot, uint32_t new_index);   /* AddRef new, Release old */


/* internal device API (used by the effect runtime; guest methods call the same code) */
uint32_t gp_dev_set_rs(uint32_t state, uint32_t value);
uint32_t gp_dev_set_ss(uint32_t sampler, uint32_t type, uint32_t value);
uint32_t gp_dev_get_ss(uint32_t sampler, uint32_t type);
uint32_t gp_dev_set_tss(uint32_t stage, uint32_t type, uint32_t value);
uint32_t gp_dev_set_texture(uint32_t sampler, gaddr texture_obj);
uint32_t gp_dev_set_shader(bool pixel, gaddr shader_obj);
uint32_t gp_dev_set_const(bool pixel, int kind /* 0 f, 1 i, 2 b */, uint32_t start, const void *data, uint32_t count);
uint32_t gp_dev_set_transform(uint32_t state, const float *m);
gaddr gp_dev_create_shader(bool pixel, const uint32_t *code, uint32_t words);
gaddr gp_dev_object(void);
bool gp_d3d9_surface_mirror(gaddr surf, gaddr *base, uint32_t *pitch, uint32_t *w, uint32_t *h, uint32_t *format);
void gp_d3d9_surface_commit(gaddr surf);
gaddr gp_d3d9_level0_surface(gaddr tex);   /* adds a reference */
#endif
