/* Shared Win32 helpers: native module handles, character tables, API table registry. */
#include "gp_api.h"
#include "gp_win.h"
#include <string.h>
#include <strings.h>

gaddr gp_wstrdup_guest(const char *s)
{
    size_t n = strlen(s) + 1;
    gaddr g = gp_heap_alloc((uint32_t)(2 * n), false);
    if (!g) gp_fatal("guest heap exhausted");
    for (size_t i = 0; i < n; i++) wr16(g + 2 * (uint32_t)i, gp_cp1252_to_wc((uint8_t)s[i]));
    return g;
}

/* Native DLLs the runtime implements. Handles point into the reserved thunk
 * region, so a guest that reads them as memory faults with a clear message. */
static const char *const native_dlls[] = {
    "kernel32.dll", "user32.dll", "gdi32.dll", "advapi32.dll", "winmm.dll", "ole32.dll", "oleaut32.dll",
    "wsock32.dll", "ws2_32.dll", "shell32.dll", "shlwapi.dll", "msacm32.dll", "d3d9.dll", "d3dx9_27.dll",
    "dinput8.dll", "eax.dll", "dsound.dll",
};
#define NATIVE_BASE 0xF0000000u

gaddr gp_native_module(const char *name)
{
    const char *base = name;
    for (const char *p = name; *p; p++) if (*p == '\\' || *p == '/') base = p + 1;
    for (size_t i = 0; i < sizeof native_dlls / sizeof *native_dlls; i++) {
        size_t n = strlen(native_dlls[i]) - 4;       /* without ".dll" */
        if (!strcasecmp(base, native_dlls[i]) || (strlen(base) == n && !strncasecmp(base, native_dlls[i], n)))
            return NATIVE_BASE + 0x10000u * (uint32_t)i;
    }
    return 0;
}

const char *gp_native_module_name(gaddr h)
{
    uint32_t i = (h - NATIVE_BASE) / 0x10000u;
    if (h < NATIVE_BASE || (h & 0xffff) || i >= sizeof native_dlls / sizeof *native_dlls) return NULL;
    return native_dlls[i];
}

int gp_upper1252(int c)
{
    if ((c >= 'a' && c <= 'z') || (c >= 0xe0 && c <= 0xfe && c != 0xf7)) return c - 0x20;
    if (c == 0x9a || c == 0x9c || c == 0x9e) return c - 0x10;
    if (c == 0xff) return 0x9f;
    return c;
}
int gp_lower1252(int c)
{
    if ((c >= 'A' && c <= 'Z') || (c >= 0xc0 && c <= 0xde && c != 0xd7)) return c + 0x20;
    if (c == 0x8a || c == 0x8c || c == 0x8e) return c + 0x10;
    if (c == 0x9f) return 0xff;
    return c;
}
uint16_t gp_upperw(uint16_t c)
{
    if ((c >= 'a' && c <= 'z') || (c >= 0xe0 && c <= 0xfe && c != 0xf7)) return c - 0x20;
    if (c == 0xff) return 0x178;
    if (c < 0x100) return c;
    /* Latin Extended-A: upper/lower pairs; parity flips in 0x139..0x148 */
    if (c >= 0x139 && c <= 0x148) return (c & 1) ? c : c - 1;
    if (c >= 0x100 && c <= 0x177 && c != 0x131 && c != 0x138 && c != 0x149) return (c & 1) ? c - 1 : c;
    if (c == 0x17a || c == 0x17c || c == 0x17e) return c - 1;
    if (c >= 0x3b1 && c <= 0x3c9 && c != 0x3c2) return c - 0x20;   /* Greek */
    if (c >= 0x430 && c <= 0x44f) return c - 0x20;                   /* Cyrillic */
    if (c >= 0x450 && c <= 0x45f) return c - 0x50;
    return c;
}
uint16_t gp_lowerw(uint16_t c)
{
    if ((c >= 'A' && c <= 'Z') || (c >= 0xc0 && c <= 0xde && c != 0xd7)) return c + 0x20;
    if (c < 0x100) return c;
    if (c >= 0x139 && c <= 0x148) return (c & 1) ? c + 1 : c;
    if (c >= 0x100 && c <= 0x177 && c != 0x130 && c != 0x138 && c != 0x149) return (c & 1) ? c : c + 1;
    if (c == 0x178) return 0xff;
    if (c == 0x179 || c == 0x17b || c == 0x17d) return c + 1;
    if (c >= 0x391 && c <= 0x3a9 && c != 0x3a2) return c + 0x20;
    if (c >= 0x410 && c <= 0x42f) return c + 0x20;
    if (c >= 0x400 && c <= 0x40f) return c + 0x50;
    return c;
}

extern const gp_api gp_api_kernel32_core[], gp_api_kernel32_io[], gp_api_winmm[], gp_api_advapi32[],
    gp_api_shell32[], gp_api_ole32[], gp_api_oleaut32[], gp_api_user32[], gp_api_gdi32[], gp_api_kernel32_profile[],
    gp_api_dinput8[], gp_api_idirectinput8[], gp_api_idirectinputdevice8[],
    gp_api_d3d9[], gp_api_idirect3d9[], gp_api_idirect3ddevice9_core[], gp_api_idirect3ddevice9_state[],
    gp_api_idirect3ddevice9_res[], gp_api_idirect3dtexture9[], gp_api_idirect3dcubetexture9[], gp_api_idirect3dsurface9[],
    gp_api_idirect3dvertexbuffer9[], gp_api_idirect3dindexbuffer9[],
    gp_api_idirect3ddevice9_shader[], gp_api_idirect3ddevice9_draw[], gp_api_idirect3dvertexshader9[], gp_api_idirect3dpixelshader9[],
    gp_api_idirect3dvertexdeclaration9[], gp_api_d3dx9_fx[], gp_api_id3dxeffectpool[], gp_api_id3dxeffect[], gp_api_d3dx9_util[], gp_api_idirect3dvolumetexture9[],
    gp_api_eax[], gp_api_idirectsound8[], gp_api_idirectsoundbuffer8[], gp_api_idirectsound3dbuffer[],
    gp_api_idirectsound3dlistener[], gp_api_ikspropertyset[], gp_api_idirectsoundnotify[], gp_api_msacm32[], gp_api_wsock32[], gp_api_ws2_32[], gp_api_dsound[], gp_api_idirect3dquery9[];

const gp_api *const gp_api_tables[] = {
    gp_api_kernel32_core,
    gp_api_kernel32_io,
    gp_api_winmm, gp_api_advapi32, gp_api_shell32, gp_api_ole32, gp_api_oleaut32, gp_api_user32, gp_api_gdi32, gp_api_kernel32_profile,
    gp_api_dinput8, gp_api_idirectinput8, gp_api_idirectinputdevice8,
    gp_api_d3d9, gp_api_idirect3d9, gp_api_idirect3ddevice9_core, gp_api_idirect3ddevice9_state,
    gp_api_idirect3ddevice9_res, gp_api_idirect3dtexture9, gp_api_idirect3dcubetexture9, gp_api_idirect3dsurface9,
    gp_api_idirect3dvertexbuffer9, gp_api_idirect3dindexbuffer9,
    gp_api_idirect3ddevice9_shader, gp_api_idirect3ddevice9_draw, gp_api_idirect3dvertexshader9, gp_api_idirect3dpixelshader9,
    gp_api_idirect3dvertexdeclaration9, gp_api_d3dx9_fx, gp_api_id3dxeffectpool, gp_api_id3dxeffect, gp_api_d3dx9_util, gp_api_idirect3dvolumetexture9,
    gp_api_eax, gp_api_idirectsound8, gp_api_idirectsoundbuffer8, gp_api_idirectsound3dbuffer,
    gp_api_idirectsound3dlistener, gp_api_ikspropertyset, gp_api_idirectsoundnotify, gp_api_msacm32, gp_api_wsock32, gp_api_ws2_32, gp_api_dsound, gp_api_idirect3dquery9,
    NULL
};
