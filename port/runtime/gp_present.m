/* Presentation of the Direct3D back buffer to the window.
   Plain:   copy the back buffer into a same-sized drawable.
   MetalFX: spatial upscale of the back buffer to the window's pixel size (Apple's MetalFX, Metal 4).
   HDR:     F.E.A.R. renders standard-dynamic-range colour only, so this is an inverse tone map ("expanded SDR"): the
            drawable is extended-range linear and bright parts are stretched into the display's extra headroom.
   Settings: the launcher's preferences (NSUserDefaults "MetalFX", "HDR"), or GP_METALFX / GP_HDR = 0 or 1. */
#import <AppKit/AppKit.h>
#import <MetalFX/MetalFX.h>
#include "gp_present.h"
#include "gp_d3d9_state.h"
#include "gp_window.h"

static bool want_hdr, want_metalfx, use_pass;
static id<MTL4Compiler> compiler;
static id<MTL4FXSpatialScaler> scaler;
static id<MTLTexture> scaled;
static NSUInteger scaler_in_w, scaler_in_h, scaler_out_w, scaler_out_h;
static id<MTLRenderPipelineState> pipeline;
static MTLPixelFormat pipeline_format;
static id<MTL4ArgumentTable> table;
static id<MTLSamplerState> sampler;

static bool setting(const char *env, NSString *key)
{
    const char *e = getenv(env);
    if (e) return e[0] == '1';
    return [NSUserDefaults.standardUserDefaults boolForKey:key];
}

void gp_present_setup(CAMetalLayer *layer, uint32_t game_w, uint32_t game_h)
{
    want_hdr = setting("GP_HDR", @"HDR");
    want_metalfx = setting("GP_METALFX", @"MetalFX");
    use_pass = want_hdr || want_metalfx;
    uint32_t out_w = game_w, out_h = game_h;
    if (want_metalfx) {
        gp_window_pixel_size(gp_game_hwnd(), &out_w, &out_h);            /* the window's size in real pixels */
        if (out_w < game_w || out_h < game_h) { out_w = game_w; out_h = game_h; }
    }
    layer.pixelFormat = want_hdr ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
    layer.drawableSize = CGSizeMake(out_w, out_h);
    if (want_hdr) {
        layer.wantsExtendedDynamicRangeContent = YES;
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
        layer.colorspace = cs;
        CGColorSpaceRelease(cs);
        CGFloat headroom = NSScreen.mainScreen.maximumExtendedDynamicRangeColorComponentValue;
        gp_log("HDR (expanded SDR) on; display headroom %.2fx%s", headroom, headroom <= 1.05 ? " (this display has no HDR headroom: no visible effect)" : "");
    }
    if (want_metalfx) gp_log("MetalFX spatial upscaling %ux%u -> %ux%u", game_w, game_h, out_w, out_h);
}

static const char *present_msl =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 pos [[position]]; float2 uv; };\n"
    "struct U { float peak; float hdr; };\n"
    "vertex V present_vs(uint vid [[vertex_id]]) {\n"
    "    float2 p = float2((vid << 1) & 2, vid & 2);\n"                       /* fullscreen triangle */
    "    V o; o.pos = float4(p * 2.0f - 1.0f, 0.0f, 1.0f); o.uv = float2(p.x, 1.0f - p.y); return o; }\n"
    "float3 srgb_to_linear(float3 c) { return select(pow((c + 0.055f) / 1.055f, 2.4f), c / 12.92f, c <= 0.04045f); }\n"
    "fragment float4 present_fs(V in [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "    float3 c = tex.sample(s, in.uv).rgb;\n"
    "    if (u.hdr < 0.5f) return float4(c, 1.0f);\n"
    "    float3 lin = srgb_to_linear(saturate(c));\n"
    "    float l = dot(lin, float3(0.2126f, 0.7152f, 0.0722f));\n"
    "    float k = smoothstep(0.35f, 1.0f, l);\n"                             /* only the bright parts are stretched */
    "    float gain = 1.0f + (u.peak - 1.0f) * k * k;\n"
    "    return float4(lin * gain, 1.0f); }\n";

static void ensure_pipeline(MTLPixelFormat format)
{
    if (pipeline && pipeline_format == format) return;
    NSError *e = nil;
    id<MTLLibrary> lib = [gp_mtl newLibraryWithSource:@(present_msl) options:nil error:&e];
    if (!lib) gp_fatal("present shader compile failed: %s", e.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"present_vs"];
    d.fragmentFunction = [lib newFunctionWithName:@"present_fs"];
    d.colorAttachments[0].pixelFormat = format;
    pipeline = [gp_mtl newRenderPipelineStateWithDescriptor:d error:&e];
    if (!pipeline) gp_fatal("present pipeline creation failed: %s", e.localizedDescription.UTF8String);
    pipeline_format = format;
    if (!table) {
        MTL4ArgumentTableDescriptor *td = [MTL4ArgumentTableDescriptor new];
        td.maxBufferBindCount = 1; td.maxTextureBindCount = 1; td.maxSamplerStateBindCount = 1;
        table = [gp_mtl newArgumentTableWithDescriptor:td error:&e];
        if (!table) gp_fatal("present argument table failed: %s", e.localizedDescription.UTF8String);
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.supportArgumentBuffers = YES;
        sampler = [gp_mtl newSamplerStateWithDescriptor:sd];
    }
}

/* create the MetalFX scaler (and its output texture) for these sizes; recreated when they change */
static void ensure_scaler(NSUInteger in_w, NSUInteger in_h, NSUInteger out_w, NSUInteger out_h)
{
    if (scaler && scaler_in_w == in_w && scaler_in_h == in_h && scaler_out_w == out_w && scaler_out_h == out_h) return;
    if (scaled) { gp_residency_remove(scaled); scaled = nil; }
    NSError *e = nil;
    if (!compiler) {
        compiler = [gp_mtl newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&e];
        if (!compiler) gp_fatal("Metal compiler for MetalFX failed: %s", e.localizedDescription.UTF8String);
    }
    MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
    d.colorTextureFormat = MTLPixelFormatBGRA8Unorm;
    d.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
    d.inputWidth = in_w; d.inputHeight = in_h; d.outputWidth = out_w; d.outputHeight = out_h;
    d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;    /* the back buffer is gamma encoded */
    scaler = [d newSpatialScalerWithDevice:gp_mtl compiler:compiler];
    if (!scaler) gp_fatal("MetalFX spatial scaler %lux%lu -> %lux%lu is not supported", (unsigned long)in_w, (unsigned long)in_h, (unsigned long)out_w, (unsigned long)out_h);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:out_w height:out_h mipmapped:NO];
    td.usage = scaler.outputTextureUsage | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    scaled = [gp_mtl newTextureWithDescriptor:td];
    if (!scaled) gp_fatal("cannot create the MetalFX output texture");
    gp_residency_add(scaled);
    scaler_in_w = in_w; scaler_in_h = in_h; scaler_out_w = out_w; scaler_out_h = out_h;
}

void gp_present_encode(id<MTL4CommandBuffer> cmd, id<MTLTexture> bb, id<CAMetalDrawable> drawable)
{
    if (!use_pass) {
        id<MTL4ComputeCommandEncoder> ce = [cmd computeCommandEncoder];
        GP_SYNC_BARRIER(ce);
        [ce copyFromTexture:bb toTexture:drawable.texture];
        [ce endEncoding];
        return;
    }
    id<MTLTexture> src = bb;
    NSUInteger ow = drawable.texture.width, oh = drawable.texture.height;
    double k = fmin((double)ow / bb.width, (double)oh / bb.height);      /* keep the game's aspect ratio */
    double vw = floor(bb.width * k), vh = floor(bb.height * k);
    if (want_metalfx && (vw > bb.width || vh > bb.height)) {
        ensure_scaler(bb.width, bb.height, (NSUInteger)vw, (NSUInteger)vh);
        id<MTL4ComputeCommandEncoder> fence = [cmd computeCommandEncoder];    /* the scaler must see the finished back buffer */
        GP_SYNC_BARRIER(fence);
        [fence endEncoding];
        scaler.colorTexture = bb;
        scaler.outputTexture = scaled;
        scaler.inputContentWidth = bb.width; scaler.inputContentHeight = bb.height;
        [scaler encodeToCommandBuffer:cmd];
        src = scaled;
    }
    ensure_pipeline(drawable.texture.pixelFormat);
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = drawable.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;      /* black bars */
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTL4RenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rp];
    if (!enc) gp_fatal("Metal: cannot open the present pass");
    GP_SYNC_BARRIER(enc);
    [enc setViewport:(MTLViewport){ floor((ow - vw) / 2), floor((oh - vh) / 2), vw, vh, 0, 1 }];
    [enc setRenderPipelineState:pipeline];
    struct { float peak, hdr; } u = { (float)fmin(NSScreen.mainScreen.maximumExtendedDynamicRangeColorComponentValue, 4.0), want_hdr ? 1.0f : 0.0f };
    if (u.peak < 1.0f) u.peak = 1.0f;
    [table setAddress:gp_transient(&u, sizeof u, 256, NULL) atIndex:0];
    [table setTexture:src.gpuResourceID atIndex:0];
    [table setSamplerState:sampler.gpuResourceID atIndex:0];
    [enc setArgumentTable:table atStages:MTLRenderStageFragment];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
}
