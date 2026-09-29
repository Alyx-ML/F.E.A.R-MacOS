/* Direct3D 9 shader objects and vertex declarations. */
#import <Metal/Metal.h>
#include "gp_d3d9_state.h"
#include "gp_d3d9_shader.h"
#include <stdlib.h>
#include <string.h>

static uint32_t shader_words(const uint32_t *code)
{
    uint32_t n = 1;
    while (n < 1u << 20) {
        uint32_t t = code[n];
        if (t == 0x0000ffffu) return n + 1;
        if ((t & 0xffff) == 0xfffe) { n += 1 + (t >> 16); continue; }
        n++;
    }
    gp_fatal("shader without end token");
}

gaddr gp_dev_create_shader(bool pixel, const uint32_t *code, uint32_t words)
{
    uint32_t v = code[0];
    if (pixel ? (v >> 16) != 0xffff : (v >> 16) != 0xfffe) return 0;
    gp_shader *sh = calloc(1, sizeof *sh);
    sh->pixel = pixel;
    sh->words = words;
    sh->code = malloc(4 * words);
    memcpy(sh->code, code, 4 * words);
    sh->version = v & 0xffff;
    gp_res r = { .kind = pixel ? R_PS : R_VS, .priv = sh };
    uint32_t idx = gp_res_new(r);
    return gp_d3d9_new_object(pixel ? "IDirect3DPixelShader9" : "IDirect3DVertexShader9", idx);
}

static uint32_t CreateVertexShader_(gp_thread *t)
{
    const uint32_t *code = G(A(1));
    gaddr o = gp_dev_create_shader(false, code, shader_words(code));
    if (!o) return D3DERR_INVALIDCALL;
    wr32(A(2), o);
    return D3D_OK;
}
static uint32_t CreatePixelShader_(gp_thread *t)
{
    const uint32_t *code = G(A(1));
    gaddr o = gp_dev_create_shader(true, code, shader_words(code));
    if (!o) return D3DERR_INVALIDCALL;
    wr32(A(2), o);
    return D3D_OK;
}

uint32_t gp_dev_set_shader(bool pixel, gaddr obj)
{
    if (obj) gp_res_get(obj, pixel ? R_PS : R_VS);
    gp_d3d9_bind(pixel ? &D.ps : &D.vs, obj ? rd32(obj + 8) : 0);
    return D3D_OK;
}
static uint32_t SetVertexShader_(gp_thread *t) { return gp_dev_set_shader(false, A(1)); }
static uint32_t SetPixelShader_(gp_thread *t) { return gp_dev_set_shader(true, A(1)); }
static uint32_t get_shader(uint32_t idx, gaddr out)
{
    gp_res *r = gp_res_at(idx);
    if (r) gp_d3d9_addref(r->obj);
    wr32(out, r ? r->obj : 0);
    return D3D_OK;
}
static uint32_t GetVertexShader_(gp_thread *t) { return get_shader(D.vs, A(1)); }
static uint32_t GetPixelShader_(gp_thread *t) { return get_shader(D.ps, A(1)); }
static uint32_t GetFunction_(gp_thread *t)
{
    gp_shader *sh = gp_res_get(A(0), 0)->priv;
    if (A(1)) memcpy(G(A(1)), sh->code, 4 * sh->words);
    wr32(A(2), 4 * sh->words);
    return D3D_OK;
}

/* ------------------------------------------------------- declarations */
static uint32_t CreateVertexDeclaration_(gp_thread *t)
{
    gaddr e = A(1);
    gp_vdecl *d = calloc(1, sizeof *d);
    for (uint32_t i = 0;; i++, e += 8) {
        if (rd16(e) == 0xff) break;
        if (i == 64) { free(d); return D3DERR_INVALIDCALL; }
        gp_velem *v = &d->e[d->n++];
        v->stream = rd16(e); v->offset = rd16(e + 2); v->type = rd8(e + 4); v->method = rd8(e + 5);
        v->usage = rd8(e + 6); v->index = rd8(e + 7);
        if (v->method != 0) gp_fatal("vertex element method %u (tessellation) is not supported", v->method);
    }
    gp_res r = { .kind = R_VDECL, .priv = d };
    uint32_t idx = gp_res_new(r);
    wr32(A(2), gp_d3d9_new_object("IDirect3DVertexDeclaration9", idx));
    return D3D_OK;
}
static uint32_t SetVertexDeclaration_(gp_thread *t)
{
    if (A(1)) gp_res_get(A(1), R_VDECL);
    gp_d3d9_bind(&D.vdecl, A(1) ? rd32(A(1) + 8) : 0);
    D.fvf = 0;
    return D3D_OK;
}
static uint32_t GetVertexDeclaration_(gp_thread *t) { return get_shader(D.vdecl, A(1)); }
static uint32_t GetDeclaration_(gp_thread *t)
{
    gp_vdecl *d = gp_res_get(A(0), R_VDECL)->priv;
    if (A(1)) {
        gaddr e = A(1);
        for (uint32_t i = 0; i < d->n; i++, e += 8) {
            wr16(e, d->e[i].stream); wr16(e + 2, d->e[i].offset); wr8(e + 4, d->e[i].type); wr8(e + 5, d->e[i].method);
            wr8(e + 6, d->e[i].usage); wr8(e + 7, d->e[i].index);
        }
        wr16(e, 0xff); wr16(e + 2, 0); wr8(e + 4, 17); wr8(e + 5, 0); wr8(e + 6, 0); wr8(e + 7, 0);
    }
    wr32(A(2), d->n + 1);
    return D3D_OK;
}

/* FVF: converted to an equivalent declaration when drawing */
static uint32_t SetFVF_(gp_thread *t)
{
    D.fvf = A(1);
    if (A(1)) gp_d3d9_bind(&D.vdecl, 0);
    return D3D_OK;
}
static uint32_t GetFVF_(gp_thread *t) { wr32(A(1), D.fvf); return D3D_OK; }

void gp_fvf_to_decl(uint32_t fvf, gp_vdecl *d)
{
    uint16_t off = 0;
    d->n = 0;
#define ADD(type_, usage_, index_, size_) do { d->e[d->n++] = (gp_velem){ 0, off, type_, 0, usage_, index_ }; off += size_; } while (0)
    switch (fvf & 0x400e) {
    case 0x002: ADD(2, 0, 0, 12); break;                         /* XYZ: FLOAT3 POSITION */
    case 0x004: ADD(3, 9, 0, 16); break;                         /* XYZRHW: FLOAT4 POSITIONT */
    case 0x4002: ADD(3, 0, 0, 16); break;                        /* XYZW */
    default: if (fvf & 0x400e) {
        uint32_t nb = ((fvf & 0xe) - 4) / 2;                      /* XYZB1..5 */
        ADD(2, 0, 0, 12);
        uint32_t weights = nb - ((fvf & 0x1000) ? 1 : 0);          /* LASTBETA_UBYTE4/D3DCOLOR carries indices */
        if (weights) ADD((uint8_t)(weights - 1), 1, 0, (uint16_t)(4 * weights));
        if (fvf & 0x1000) ADD(5, 2, 0, 4);
        else if (fvf & 0x8000) ADD(4, 2, 0, 4);
    } }
    if (fvf & 0x010) ADD(2, 3, 0, 12);                            /* NORMAL */
    if (fvf & 0x020) ADD(0, 4, 0, 4);                             /* PSIZE */
    if (fvf & 0x040) ADD(4, 10, 0, 4);                            /* DIFFUSE: D3DCOLOR COLOR0 */
    if (fvf & 0x080) ADD(4, 10, 1, 4);                            /* SPECULAR: COLOR1 */
    uint32_t ntex = (fvf >> 8) & 0xf;
    for (uint32_t i = 0; i < ntex; i++) {
        uint32_t f = (fvf >> (16 + 2 * i)) & 3;                    /* 0: 2 floats, 1: 3, 2: 4, 3: 1 */
        static const uint8_t type[4] = { 1, 2, 3, 0 }, size[4] = { 8, 12, 16, 4 };
        ADD(type[f], 5, (uint8_t)i, size[f]);
    }
#undef ADD
}

#undef DLL
#define DLL "IDirect3DDevice9"
const gp_api gp_api_idirect3ddevice9_shader[] = {
    API(CreateVertexShader_, "CreateVertexShader", 3), API(CreatePixelShader_, "CreatePixelShader", 3),
    API(SetVertexShader_, "SetVertexShader", 2), API(SetPixelShader_, "SetPixelShader", 2),
    API(GetVertexShader_, "GetVertexShader", 2), API(GetPixelShader_, "GetPixelShader", 2),
    API(CreateVertexDeclaration_, "CreateVertexDeclaration", 3), API(SetVertexDeclaration_, "SetVertexDeclaration", 2),
    API(GetVertexDeclaration_, "GetVertexDeclaration", 2), API(SetFVF_, "SetFVF", 2), API(GetFVF_, "GetFVF", 2),
    { 0 }
};
static uint32_t ShAddRef_(gp_thread *t) { return gp_d3d9_addref(A(0)); }
static uint32_t ShRelease_(gp_thread *t) { return gp_d3d9_release(A(0)); }
static uint32_t ShGetDevice_(gp_thread *t) { gaddr d = rd32(A(0) + 12); gp_d3d9_addref(d); wr32(A(1), d); return D3D_OK; }
#undef DLL
#define DLL "IDirect3DVertexShader9"
const gp_api gp_api_idirect3dvertexshader9[] = { API(ShAddRef_, "AddRef", 1), API(ShRelease_, "Release", 1),
    API(ShGetDevice_, "GetDevice", 2), API(GetFunction_, "GetFunction", 3), { 0 } };
#undef DLL
#define DLL "IDirect3DPixelShader9"
const gp_api gp_api_idirect3dpixelshader9[] = { API(ShAddRef_, "AddRef", 1), API(ShRelease_, "Release", 1),
    API(ShGetDevice_, "GetDevice", 2), API(GetFunction_, "GetFunction", 3), { 0 } };
#undef DLL
#define DLL "IDirect3DVertexDeclaration9"
const gp_api gp_api_idirect3dvertexdeclaration9[] = { API(ShAddRef_, "AddRef", 1), API(ShRelease_, "Release", 1),
    API(ShGetDevice_, "GetDevice", 2), API(GetDeclaration_, "GetDeclaration", 3), { 0 } };
