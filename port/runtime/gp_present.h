/* Presentation of the Direct3D back buffer to the window: plain copy, MetalFX upscale, expanded-SDR "HDR". */
#ifndef GP_PRESENT_H
#define GP_PRESENT_H
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

/* configure the layer for the chosen mode; game_w/h is the back buffer size */
void gp_present_setup(CAMetalLayer *layer, uint32_t game_w, uint32_t game_h);
/* encode back buffer -> drawable into the frame's command buffer */
void gp_present_encode(id<MTL4CommandBuffer> cmd, id<MTLTexture> back_buffer, id<CAMetalDrawable> drawable);

#endif
