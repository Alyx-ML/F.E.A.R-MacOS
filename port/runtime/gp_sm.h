/* Direct3D 9 shader bytecode (vs_1_1..vs_2_x, ps_1_1..ps_2_x) to Metal Shading Language. */
#ifndef GP_SM_H
#define GP_SM_H
#include <stdbool.h>
#include <stdint.h>

/* Binding layout shared with the draw code:
 *   vertex:   buffer(0..7) streams (stage_in), buffer(16) float4 c[256], buffer(17) sm_vs_misc,
 *             buffer(18) int4 i[16] + uint b[16]; texture/sampler(0..3) vertex textures
 *   fragment: buffer(0) float4 c[224], buffer(1) sm_ps_misc, buffer(2) int4 i[16] + uint b[16];
 *             texture/sampler(0..15)
 * Stage interface: [[position]], user(d0), user(d1), user(t0..t7), user(fog), [[point_size]] */

enum { SM_TEX_2D, SM_TEX_CUBE, SM_TEX_3D, SM_TEX_SHADOW2D };   /* per sampler, 2 bits in the key */

typedef struct {
    /* vertex shaders: per input register, which vertex format class feeds it:
       0 absent (reads 0,0,0,1), 1 float, 2 unsigned integer, 3 signed integer */
    uint8_t input_class[16];
    /* pixel shaders: sampler types (ps_1_x has no dcl; ps_2_x overrides from dcl) */
    uint8_t sampler_type[16];
    bool point_size;                  /* the vertex shader writes oPts / point sprites are drawn */
    uint8_t clip_planes;              /* D3DRS_CLIPPLANEENABLE bits for vertex shaders */
    bool ps_texcoord_projected[8];    /* ps_1_x "tex" honours D3DTTFF_PROJECTED */
} sm_key;

typedef struct {
    float pos_fixup[4];               /* xy: added * w to the clip position (half-pixel), zw unused */
    float clip_planes[6][4];
} sm_vs_misc;

typedef struct {
    float alpha_ref;                  /* 0..1 */
    uint32_t alpha_func;              /* D3DCMPFUNC; 8 = always (no test) */
    uint32_t fog_mode;                /* 0 off, 1 exp, 2 exp2, 3 linear (table fog), 4 vertex fog factor */
    float fog_start, fog_end, fog_density;
    float fog_color[4];
    float lod_bias[16];
    float bumpenv[8][4];              /* ps_1_x texbem matrices (00 01 10 11) */
} sm_ps_misc;

/* usage/index of each vertex shader input register (from dcl), filled by sm_translate */
typedef struct {
    uint16_t input_mask;
    uint8_t usage[16], usage_index[16];
    uint16_t sampler_mask;            /* samplers the shader samples */
    uint8_t sampler_dcl[16];          /* ps_2 dcl texture types (SM_TEX_*), 255 = not declared */
    uint8_t outputs;                  /* bit0 oD0 bit1 oD1 bit2 fog bit3 point size; texcoords in out_tex */
    uint8_t out_tex;
    uint8_t ps_inputs_tex, ps_inputs_color;
    uint8_t color_outputs;            /* pixel shader render target outputs */
    bool writes_depth;
} sm_info;

/* returns malloc'd MSL source (entry point "gp_main"), NULL with err on failure */
char *sm_translate(const uint32_t *code, uint32_t words, const sm_key *key, sm_info *info, char *err, uint32_t errlen);
/* inspect without generating code (inputs, samplers) */
bool sm_scan(const uint32_t *code, uint32_t words, sm_info *info, char *err, uint32_t errlen);

#endif
