/* Direct3D 9 shaders, vertex declarations and their Metal translations. */
#ifndef GP_D3D9_SHADER_H
#define GP_D3D9_SHADER_H
#import <Metal/Metal.h>
#include "gp_d3d9_device.h"

typedef struct { uint16_t stream, offset; uint8_t type, method, usage, index; } gp_velem;
typedef struct { gp_velem e[64]; uint32_t n; } gp_vdecl;

/* translation of one D3D9 shader for one variant key */
typedef struct gp_shader_variant {
    uint64_t key;
    id<MTLFunction> fn;
    struct gp_shader_variant *next;
} gp_shader_variant;

typedef struct {
    uint32_t *code, words, version;
    bool pixel;
    /* vertex shaders: input register -> (usage, index) from dcl; pixel shaders: input semantics */
    uint8_t in_usage[16], in_index[16];
    uint16_t in_mask;
    gp_shader_variant *variants;
} gp_shader;

void gp_fvf_to_decl(uint32_t fvf, gp_vdecl *d);

#endif
