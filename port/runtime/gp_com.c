/* COM object support for native implementations of DirectX interfaces. */
#include "gp_api.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

gaddr gp_com_vtable(const char *iface, const char *const *methods, int n)
{
    gaddr vt = gp_heap_alloc(4 * (uint32_t)n, false);
    if (!vt) gp_fatal("guest heap exhausted");
    for (int i = 0; i < n; i++) wr32(vt + 4 * (uint32_t)i, gp_native_thunk(iface, methods[i]));
    return vt;
}

gaddr gp_com_new(gaddr vtable, uint32_t extra)
{
    gaddr o = gp_heap_alloc(8 + extra, true);
    if (!o) gp_fatal("guest heap exhausted");
    wr32(o, vtable);
    wr32(o + 4, 1);
    return o;
}

bool gp_guid_eq(gaddr g, const char *text)
{
    unsigned d1, d2, d3, b[8];
    if (sscanf(text, "%8x-%4x-%4x-%2x%2x-%2x%2x%2x%2x%2x%2x", &d1, &d2, &d3, &b[0], &b[1], &b[2], &b[3], &b[4], &b[5], &b[6], &b[7]) != 11)
        gp_fatal("bad GUID literal %s", text);
    if (rd32(g) != d1 || rd16(g + 4) != d2 || rd16(g + 6) != d3) return false;
    for (int i = 0; i < 8; i++) if (rd8(g + 8 + (uint32_t)i) != b[i]) return false;
    return true;
}
