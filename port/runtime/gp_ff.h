/* Direct3D 9 fixed-function vertex and pixel processing as generated MSL. */
#ifndef GP_FF_H
#define GP_FF_H
#import <Metal/Metal.h>
#include "gp_d3d9_shader.h"

id<MTLFunction> gp_ff_vertex_function(const gp_vdecl *decl, uint16_t *attr_mask, MTLVertexFormat *fmt,
                                      uint8_t *stream, uint16_t *offset, uint32_t *streams_used);
id<MTLFunction> gp_ff_fragment_function(uint16_t *sampler_mask);
void gp_ff_bind_vertex(id<MTL4ArgumentTable> t, float vx, float vy, float vw, float vh);
void gp_ff_bind_fragment(id<MTL4ArgumentTable> t);

#endif
