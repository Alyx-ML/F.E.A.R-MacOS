/* IDirect3DDevice9 core: creation, frames, render targets, Clear, Present, state storage. */
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include "gp_d3d9_device.h"
#include "gp_d3d9_state.h"
#include "gp_window.h"
#include "gp_present.h"
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------ resources */
#define MAX_RES 65536
static gp_res res[MAX_RES];
static uint32_t res_hint = 1;
static pthread_mutex_t res_lock = PTHREAD_MUTEX_INITIALIZER;

uint32_t gp_res_new(gp_res r)
{
    pthread_mutex_lock(&res_lock);
    for (uint32_t n = 0; n < MAX_RES - 1; n++) {
        uint32_t i = 1 + (res_hint - 1 + n) % (MAX_RES - 1);
        if (!res[i].kind) { res[i] = r; res_hint = i + 1; pthread_mutex_unlock(&res_lock); return i; }
    }
    pthread_mutex_unlock(&res_lock);
    gp_fatal("Direct3D resource table full");
}
gp_res *gp_res_at(uint32_t i) { return i && i < MAX_RES && res[i].kind ? &res[i] : NULL; }
gp_res *gp_res_get(gaddr obj, int kind)
{
    if (!obj) return NULL;
    gp_res *r = gp_res_at(rd32(obj + 8));
    if (!r || r->obj != obj || (kind && r->kind != kind)) gp_fatal("invalid Direct3D object 0x%08x (expected kind %d)", obj, kind);
    return r;
}

static gaddr dev_obj;               /* the guest device object */
static gaddr d3d_obj;

gaddr gp_d3d9_new_object(const char *iface, uint32_t index)
{
    gaddr o = gp_com_new(gp_d3d9_vtable(iface), 8);
    wr32(o + 8, index);
    wr32(o + 12, dev_obj);
    res[index].obj = o;
    return o;
}

/* ------------------------------------------------------------ residency */
id<MTLResidencySet> gp_residency;
static bool residency_dirty;
void gp_residency_add(id<MTLAllocation> a) { [gp_residency addAllocation:a]; residency_dirty = true; }
void gp_residency_remove(id<MTLAllocation> a) { [gp_residency removeAllocation:a]; residency_dirty = true; }

/* ---------------------------------------------------------------- device */
gp_dev D;

static id<MTLTexture> new_texture(MTLPixelFormat f, uint32_t w, uint32_t h, MTLTextureUsage usage, MTLStorageMode storage)
{
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    d.usage = usage;
    d.storageMode = storage;
    id<MTLTexture> t = [gp_mtl newTextureWithDescriptor:d];
    if (!t) gp_fatal("Metal: cannot create %ux%u texture (format %lu)", w, h, (unsigned long)f);
    gp_residency_add(t);
    return t;
}

uint32_t gp_d3d9_new_surface(uint32_t format, uint32_t w, uint32_t h, uint32_t usage, bool rt)
{
    const gp_format *f = gp_format_info(format);
    if (!f) gp_fatal("surface format %u is not supported", format);
    MTLTextureUsage u = MTLTextureUsageShaderRead | (rt || f->depth ? MTLTextureUsageRenderTarget : 0);
    gp_res r = { .kind = R_SURFACE, .format = format, .usage = usage, .width = w, .height = h, .levels = 1, .fmt = f };
    r.tex = new_texture(f->mtl, w, h, u, MTLStorageModePrivate);
    return gp_res_new(r);
}

static void make_backbuffers(void)
{
    D.backbuffer = gp_d3d9_new_surface(D.bb_format, D.width, D.height, 1, true);
    gp_d3d9_new_object("IDirect3DSurface9", D.backbuffer);
    D.auto_depth = 0;
    if (D.auto_depth_format) {
        D.auto_depth = gp_d3d9_new_surface(D.auto_depth_format, D.width, D.height, 2, true);
        gp_d3d9_new_object("IDirect3DSurface9", D.auto_depth);
    }
    memset(D.rt, 0, sizeof D.rt);
    D.rt[0] = D.backbuffer;
    D.ds = D.auto_depth;
    D.viewport = (d3d_viewport){ 0, 0, D.width, D.height, 0.0f, 1.0f };
    D.scissor = (d3d_rect){ 0, 0, (int32_t)D.width, (int32_t)D.height };
}

static void read_present_parameters(gaddr pp)
{
    uint32_t w = rd32(pp), h = rd32(pp + 4);
    uint32_t hwnd = rd32(pp + 28) ? rd32(pp + 28) : D.focus_hwnd;
    if (!w || !h) gp_window_client_size(hwnd, &w, &h);
    D.width = w; D.height = h;
    D.bb_format = rd32(pp + 8) ? rd32(pp + 8) : D3DFMT_X8R8G8B8;
    if (!gp_format_info(D.bb_format) || gp_format_info(D.bb_format)->mtl != MTLPixelFormatBGRA8Unorm)
        gp_fatal("back buffer format %u", D.bb_format);
    if (rd32(pp + 12) > 1) gp_log("D3D: %u back buffers requested; presentation is double buffered by the layer", rd32(pp + 12));
    if (rd32(pp + 16)) gp_fatal("multisampled back buffer (type %u)", rd32(pp + 16));
    D.hwnd = hwnd;
    D.windowed = rd32(pp + 32);
    D.auto_depth_format = rd32(pp + 36) ? rd32(pp + 40) : 0;
    D.interval = rd32(pp + 52);
    /* the Windows runtime writes back the chosen sizes */
    wr32(pp, w); wr32(pp + 4, h); wr32(pp + 8, D.bb_format);
    if (!rd32(pp + 12)) wr32(pp + 12, 1);
}

static void setup_layer(void)
{
    CAMetalLayer *layer = (__bridge CAMetalLayer *)gp_window_metal_layer(D.hwnd);
    D.layer = layer;
    if (!layer) return;                                     /* headless: offscreen only */
    layer.device = gp_mtl;
    layer.framebufferOnly = NO;                             /* the back buffer is copied into the drawable */
    gp_present_setup(layer, D.width, D.height);             /* pixel format and drawable size follow the MetalFX / HDR settings */
    layer.displaySyncEnabled = D.interval != 0x80000000u;   /* D3DPRESENT_INTERVAL_IMMEDIATE */
    layer.maximumDrawableCount = 3;
}

gaddr gp_d3d9_create_device(gp_thread *t, gaddr d3d, uint32_t hwnd, uint32_t behavior, gaddr pp)
{
    if (dev_obj) gp_fatal("a second Direct3D device was created");
    (void)t;
    d3d_obj = d3d;
    D.focus_hwnd = hwnd;
    D.behavior = behavior;
    read_present_parameters(pp);
    D.queue = [gp_mtl newMTL4CommandQueue];
    for (int i = 0; i < FRAMES; i++) D.alloc[i] = [gp_mtl newCommandAllocator];
    D.cmd = [gp_mtl newCommandBuffer];
    D.frame_event = [gp_mtl newSharedEvent];
    MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new];
    rd.initialCapacity = 4096;
    NSError *err = nil;
    gp_residency = [gp_mtl newResidencySetWithDescriptor:rd error:&err];
    if (!D.queue || !D.cmd || !D.frame_event || !gp_residency) gp_fatal("Metal 4 queue setup failed: %s", err.localizedDescription.UTF8String);
    [D.queue addResidencySet:gp_residency];
    dev_obj = gp_com_new(gp_d3d9_vtable("IDirect3DDevice9"), 8);
    make_backbuffers();
    setup_layer();
    gp_d3d9_state_defaults();
    gp_log("D3D device %ux%u %s, back buffer format %u, depth format %u", D.width, D.height,
           D.windowed ? "windowed" : "fullscreen", D.bb_format, D.auto_depth_format);
    extern void gp_d3d9_selftest(gp_thread *t);
    gp_d3d9_selftest(t);
    return dev_obj;
}

/* --------------------------------------------------------------- frames */
void gp_d3d9_begin_frame(void)
{
    if (D.recording) return;
    /* wait until the GPU finished the frame that last used this allocator */
    uint64_t done_needed = D.frame_serial >= FRAMES ? D.frame_serial - FRAMES + 1 : 0;
    if (done_needed && ![D.frame_event waitUntilSignaledValue:done_needed timeoutMS:10000])
        gp_fatal("GPU did not finish frame %llu within 10 s", (unsigned long long)done_needed);
    id<MTL4CommandAllocator> a = D.alloc[D.frame_serial % FRAMES];
    [a reset];
    [D.cmd beginCommandBufferWithAllocator:a];
    D.recording = true;
    gp_d3d9_frame_begin();
}

void gp_d3d9_end_pass(void)
{
    if (D.enc) { [D.enc endEncoding]; D.enc = nil; }
}

/* Opens a render pass on the current targets. load: per-target clear or keep. */
void gp_d3d9_begin_pass(bool clear_color, uint32_t color, bool clear_depth, float z, bool clear_stencil, uint32_t stencil)
{
    gp_d3d9_begin_frame();
    gp_d3d9_end_pass();
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    uint32_t w = 0, h = 0;
    for (int i = 0; i < 4; i++) {
        gp_res *r = gp_res_at(D.rt[i]);
        if (!r) continue;
        MTLRenderPassColorAttachmentDescriptor *ca = rp.colorAttachments[i];
        ca.texture = r->tex;
        ca.level = r->owner ? r->level : 0;
        ca.slice = r->owner ? r->face : 0;
        ca.loadAction = clear_color ? MTLLoadActionClear : MTLLoadActionLoad;
        ca.storeAction = MTLStoreActionStore;
        ca.clearColor = MTLClearColorMake(((color >> 16) & 0xff) / 255.0, ((color >> 8) & 0xff) / 255.0, (color & 0xff) / 255.0, (color >> 24) / 255.0);
        /* the pass covers the area every attachment has (D3D9 tolerates a smaller depth buffer) */
        if (!w || r->width < w) w = r->width;
        if (!h || r->height < h) h = r->height;
    }
    gp_res *ds = gp_res_at(D.ds);
    if (ds) {
        rp.depthAttachment.texture = ds->tex;
        rp.depthAttachment.loadAction = clear_depth ? MTLLoadActionClear : MTLLoadActionLoad;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        rp.depthAttachment.clearDepth = z;
        rp.stencilAttachment.texture = ds->tex;
        rp.stencilAttachment.loadAction = clear_stencil ? MTLLoadActionClear : MTLLoadActionLoad;
        rp.stencilAttachment.storeAction = MTLStoreActionStore;
        rp.stencilAttachment.clearStencil = stencil & 0xff;
        if (!w || ds->width < w) w = ds->width;
        if (!h || ds->height < h) h = ds->height;
    }
    if (!w) gp_fatal("render pass without render targets");
    rp.renderTargetWidth = w; rp.renderTargetHeight = h;
    D.pass_w = w; D.pass_h = h;
    D.enc = [D.cmd renderCommandEncoderWithDescriptor:rp];
    if (!D.enc) gp_fatal("Metal: cannot open render pass");
    GP_SYNC_BARRIER(D.enc);
    D.pass_draws = 0;
    gp_d3d9_pass_opened();
}

/* ------------------------------------------------------------- methods */
static uint32_t TestCooperativeLevel_(gp_thread *t) { (void)t; return D3D_OK; }
static uint32_t GetAvailableTextureMem_(gp_thread *t) { (void)t; return 0x7ff00000u; }   /* ~2 GiB: unified memory */
static uint32_t GetDirect3D_(gp_thread *t) { wr32(d3d_obj + 4, rd32(d3d_obj + 4) + 1); wr32(A(1), d3d_obj); return D3D_OK; }
static uint32_t GetDeviceCaps9_(gp_thread *t) { gp_d3d9_fill_caps(A(1)); return D3D_OK; }
static uint32_t GetDisplayMode_(gp_thread *t)
{
    gaddr p = A(2);
    wr32(p, D.width); wr32(p + 4, D.height); wr32(p + 8, 60); wr32(p + 12, D.bb_format);
    return D3D_OK;
}
static uint32_t GetCreationParameters_(gp_thread *t)
{
    gaddr p = A(1);
    wr32(p, 0); wr32(p + 4, 1); wr32(p + 8, D.focus_hwnd); wr32(p + 12, D.behavior);
    return D3D_OK;
}
static uint32_t AddRefDev_(gp_thread *t) { uint32_t r = rd32(A(0) + 4) + 1; wr32(A(0) + 4, r); return r; }
static void destroy_device(void)
{
    gp_d3d9_flush_and_wait();
    /* every resource belongs to the device; D3D releases them with it */
    for (uint32_t i = 1; i < MAX_RES; i++) {
        if (!res[i].kind) continue;
        if (res[i].tex) gp_residency_remove(res[i].tex);
        if (res[i].buf) gp_residency_remove(res[i].buf);
        if (res[i].sysmem) gp_heap_free(res[i].sysmem);
        free(res[i].priv);
        res[i] = (gp_res){0};
    }
    gp_heap_free(dev_obj);
    dev_obj = 0;
    D.layer = nil; D.enc = nil; D.cmd = nil; D.queue = nil; D.frame_event = nil;
    for (int i = 0; i < FRAMES; i++) D.alloc[i] = nil;
    D.recording = false; D.frame_serial = 0;
    gp_d3d9_state_release();
    gp_residency = nil;
    gp_log("D3D device destroyed");
}

static uint32_t ReleaseDev_(gp_thread *t)
{
    uint32_t r = rd32(A(0) + 4) - 1;
    wr32(A(0) + 4, r);
    if (!r) destroy_device();
    return r;
}

static gaddr addref_obj(gaddr o) { if (o) gp_d3d9_addref(o); return o; }

static uint32_t GetBackBuffer_(gp_thread *t)
{
    /* (this, swapchain, index, type, IDirect3DSurface9**) */
    if (A(1) != 0 || A(2) != 0) return D3DERR_INVALIDCALL;
    wr32(A(4), addref_obj(gp_res_at(D.backbuffer)->obj));
    return D3D_OK;
}
static uint32_t GetRenderTarget_(gp_thread *t)
{
    if (A(1) >= 4) return D3DERR_INVALIDCALL;
    gp_res *r = gp_res_at(D.rt[A(1)]);
    wr32(A(2), r ? addref_obj(r->obj) : 0);
    return r ? D3D_OK : 0x88760866u;                       /* D3DERR_NOTFOUND */
}
static uint32_t GetDepthStencilSurface_(gp_thread *t)
{
    gp_res *r = gp_res_at(D.ds);
    wr32(A(1), r ? addref_obj(r->obj) : 0);
    return r ? D3D_OK : 0x88760866u;
}
static uint32_t SetRenderTarget_(gp_thread *t)
{
    uint32_t i = A(1);
    if (i >= 4 || (i == 0 && !A(2))) return D3DERR_INVALIDCALL;
    uint32_t idx = A(2) ? rd32(A(2) + 8) : 0;
    if (A(2)) gp_res_get(A(2), R_SURFACE);
    if (D.rt[i] == idx) return D3D_OK;
    gp_d3d9_end_pass();
    gp_d3d9_bind(&D.rt[i], idx);
    D.pass_invalid = true;
    if (i == 0) {                                          /* D3D9 resets viewport and scissor to the new target */
        gp_res *r = gp_res_at(idx);
        D.viewport = (d3d_viewport){ 0, 0, r->width, r->height, 0.0f, 1.0f };
        D.scissor = (d3d_rect){ 0, 0, (int32_t)r->width, (int32_t)r->height };
    }
    return D3D_OK;
}
static uint32_t SetDepthStencilSurface_(gp_thread *t)
{
    uint32_t idx = A(1) ? rd32(A(1) + 8) : 0;
    if (A(1)) gp_res_get(A(1), R_SURFACE);
    if (D.ds == idx) return D3D_OK;
    gp_d3d9_end_pass();
    gp_d3d9_bind(&D.ds, idx);
    D.pass_invalid = true;
    return D3D_OK;
}

static uint32_t BeginScene_(gp_thread *t) { (void)t; D.in_scene = true; gp_d3d9_begin_frame(); return D3D_OK; }
static uint32_t EndScene_(gp_thread *t) { (void)t; D.in_scene = false; return D3D_OK; }

static uint32_t Clear_(gp_thread *t)
{
    /* (this, count, rects, flags, color, z, stencil) */
    uint32_t count = A(1), flags = A(3), color = A(4), stencil = A(6);
    float z; uint32_t zb = A(5); memcpy(&z, &zb, 4);
    bool c = flags & 1, d = flags & 2, s = flags & 4;
    gp_res *tgt = gp_res_at(D.rt[0]);
    if (getenv("GP_TRACE_CLEAR") && c)
        gp_log("Clear color 0x%08x flags 0x%x count %u on rt %u (%ux%u fmt %u usage 0x%x)", color, flags, count, D.rt[0],
               tgt ? tgt->width : 0, tgt ? tgt->height : 0, tgt ? tgt->format : 0, tgt ? tgt->usage : 0);
    if (!tgt) tgt = gp_res_at(D.ds);
    bool full = !count && tgt && D.viewport.x == 0 && D.viewport.y == 0 && D.viewport.w == tgt->width && D.viewport.h == tgt->height
                && !(D.rs[174] /* SCISSORTESTENABLE */);
    if (full && (!c || D.rs[168] /* COLORWRITEENABLE */ == 0xf)) {
        /* whole-target clear: a fresh pass with clear load actions (free on tile GPUs) */
        gp_d3d9_begin_pass(c, color, d, z, s, stencil);
        return D3D_OK;
    }
    return gp_d3d9_clear_rects(count, A(2), flags, color, z, stencil);
}

static volatile sig_atomic_t usr1;
static void usr1_handler(int sig) { (void)sig; usr1 = 1; }

static void frame_stats(void)
{
    extern volatile bool gp_trace_frame_active;
    static long trace_frame = -2;
    if (trace_frame == -2) trace_frame = getenv("GP_TRACE_FRAME") ? atol(getenv("GP_TRACE_FRAME")) : -1;
    /* kill -USR1 <pid> traces exactly the next frame (stand at the problem, then send it) */
    static int one;
    static bool armed;
    if (!armed) { armed = true; signal(SIGUSR1, (void (*)(int))usr1_handler); }
    if (usr1) { usr1 = 0; one = 1; } else if (one == 1) one = 2; else if (one == 2) one = 0;
    gp_trace_frame_active = one == 1 || (trace_frame >= 0 && D.frame_serial == (uint64_t)trace_frame);
    static int every = -1;
    if (every < 0) every = getenv("GP_FRAME_STATS") ? atoi(getenv("GP_FRAME_STATS")) : 0;
    if (!every || D.frame_serial % (uint64_t)every) return;
    extern uint64_t gp_d3d9_draws_total;
    static uint64_t last;
    gp_log("frame %llu: %llu draws since the last report", (unsigned long long)D.frame_serial, (unsigned long long)(gp_d3d9_draws_total - last));
    last = gp_d3d9_draws_total;
    gp_d3d9_log_backbuffer_stats(D.frame_serial);
}

static uint32_t Present_(gp_thread *t)
{
    (void)t;
    gp_d3d9_begin_frame();
    gp_d3d9_end_pass();
    gp_res *bb = gp_res_at(D.backbuffer);
    id<CAMetalDrawable> drawable = nil;
    if (D.layer) {
        uint32_t cw, ch;
        gp_window_client_size(D.hwnd, &cw, &ch);
        drawable = [D.layer nextDrawable];
        if (!drawable) gp_log("Present: no drawable available");
    }
    if (drawable) gp_present_encode(D.cmd, bb->tex, drawable);
    gp_d3d9_frame_end();
    [D.cmd endCommandBuffer];
    if (residency_dirty) { [gp_residency commit]; residency_dirty = false; }
    if (drawable) [D.queue waitForDrawable:drawable];
    id<MTL4CommandBuffer> list[1] = { D.cmd };
    [D.queue commit:list count:1];
    D.frame_serial++;
    [D.queue signalEvent:D.frame_event value:D.frame_serial];
    if (drawable) { [D.queue signalDrawable:drawable]; [drawable present]; }
    D.recording = false;
    if (!D.layer && D.interval != 0x80000000u) {
        /* headless: no display link, so pace presentation like a 60 Hz vsync */
        static uint64_t next;
        uint64_t period = 1000000000ull / 60 * (D.interval >= 1 && D.interval <= 4 ? D.interval : 1);
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        next = next && now < next + period ? next + period : now + period;
        if (next > now) {
            struct timespec ts = { (time_t)((next - now) / 1000000000ull), (long)((next - now) % 1000000000ull) };
            while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {}
        }
    }
    frame_stats();
    gp_pump_events();
    return D3D_OK;
}

/* Run pending GPU work now and wait for it (resource read-back, locks of GPU-written data). */
void gp_d3d9_flush_and_wait(void)
{
    if (!D.recording) {
        if (D.frame_serial && ![D.frame_event waitUntilSignaledValue:D.frame_serial timeoutMS:10000]) gp_fatal("GPU timeout");
        return;
    }
    gp_d3d9_end_pass();
    gp_d3d9_frame_end();
    [D.cmd endCommandBuffer];
    if (residency_dirty) { [gp_residency commit]; residency_dirty = false; }
    id<MTL4CommandBuffer> list[1] = { D.cmd };
    [D.queue commit:list count:1];
    D.frame_serial++;
    [D.queue signalEvent:D.frame_event value:D.frame_serial];
    D.recording = false;
    if (![D.frame_event waitUntilSignaledValue:D.frame_serial timeoutMS:10000]) gp_fatal("GPU timeout");
    D.pass_invalid = true;
}

/* Metal work inside the frame that is not a render pass (uploads, copies). */
id<MTL4ComputeCommandEncoder> gp_d3d9_blit_encoder(void)
{
    gp_d3d9_begin_frame();
    gp_d3d9_end_pass();
    D.pass_invalid = true;
    id<MTL4ComputeCommandEncoder> ce = [D.cmd computeCommandEncoder];
    GP_SYNC_BARRIER(ce);
    return ce;
}

static uint32_t Reset_(gp_thread *t)
{
    gp_d3d9_flush_and_wait();
    read_present_parameters(A(1));
    make_backbuffers();
    setup_layer();
    gp_d3d9_state_defaults();
    gp_log("D3D Reset %ux%u", D.width, D.height);
    return D3D_OK;
}

static uint32_t SetGammaRamp_(gp_thread *t) { memcpy(D.gamma, G(A(3)), sizeof D.gamma); D.gamma_set = true; return 0; }
static uint32_t GetGammaRamp_(gp_thread *t) { memcpy(G(A(2)), D.gamma, sizeof D.gamma); return 0; }
static uint32_t GetRasterStatus_(gp_thread *t) { memset(G(A(2)), 0, 8); wr32(A(2), 1); return D3D_OK; }   /* in vblank */
static uint32_t SetDialogBoxMode_(gp_thread *t) { (void)t; return D3D_OK; }
static uint32_t EvictManagedResources_(gp_thread *t) { (void)t; return D3D_OK; }
static uint32_t ShowCursorDev_(gp_thread *t) { static uint32_t shown; uint32_t o = shown; shown = A(1); return o; }
static uint32_t SetCursorPositionDev_(gp_thread *t) { (void)t; return 0; }
static uint32_t GetNumberOfSwapChains_(gp_thread *t) { (void)t; return 1; }
static uint32_t QueryInterfaceDev_(gp_thread *t) { wr32(A(2), 0); return E_NOINTERFACE; }

#undef DLL
#define DLL "IDirect3DDevice9"
const gp_api gp_api_idirect3ddevice9_core[] = {
    API(QueryInterfaceDev_, "QueryInterface", 3), API(AddRefDev_, "AddRef", 1), API(ReleaseDev_, "Release", 1),
    API(TestCooperativeLevel_, "TestCooperativeLevel", 1), API(GetAvailableTextureMem_, "GetAvailableTextureMem", 1),
    API(EvictManagedResources_, "EvictManagedResources", 1), API(GetDirect3D_, "GetDirect3D", 2),
    API(GetDeviceCaps9_, "GetDeviceCaps", 2), API(GetDisplayMode_, "GetDisplayMode", 3),
    API(GetCreationParameters_, "GetCreationParameters", 2), API(ShowCursorDev_, "ShowCursor", 2),
    API(SetCursorPositionDev_, "SetCursorPosition", 4), API(GetNumberOfSwapChains_, "GetNumberOfSwapChains", 1),
    API(Reset_, "Reset", 2), API(Present_, "Present", 5), API(GetBackBuffer_, "GetBackBuffer", 5),
    API(GetRasterStatus_, "GetRasterStatus", 3), API(SetDialogBoxMode_, "SetDialogBoxMode", 2),
    API(SetGammaRamp_, "SetGammaRamp", 4), API(GetGammaRamp_, "GetGammaRamp", 3),
    API(SetRenderTarget_, "SetRenderTarget", 3), API(GetRenderTarget_, "GetRenderTarget", 3),
    API(SetDepthStencilSurface_, "SetDepthStencilSurface", 2), API(GetDepthStencilSurface_, "GetDepthStencilSurface", 2),
    API(BeginScene_, "BeginScene", 1), API(EndScene_, "EndScene", 1), API(Clear_, "Clear", 7),
    { 0 }
};
