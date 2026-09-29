/* Guest module images, native import dispatch, native module handles. */
#include "gp.h"
#include "gp_api.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <CommonCrypto/CommonDigest.h>

#define MAX_MODULES 16
static gp_module modules[MAX_MODULES];
static int nmodules;

gp_module *gp_module_by_name(const char *name)
{
    const char *base = name;
    for (const char *p = name; *p; p++) if (*p == '\\' || *p == '/') base = p + 1;
    for (int i = 0; i < nmodules; i++) {
        size_t n = strlen(modules[i].name);
        if (!strcasecmp(base, modules[i].name)) return &modules[i];
        /* LoadLibrary("GameClient") without extension */
        if (!strchr(base, '.') && !strncasecmp(base, modules[i].name, strlen(base)) &&
            modules[i].name[strlen(base)] == '.' && strlen(base) < n) return &modules[i];
    }
    return NULL;
}

gp_module *gp_module_by_address(gaddr a)
{
    for (int i = 0; i < nmodules; i++)
        if (a >= modules[i].base && a - modules[i].base < modules[i].size) return &modules[i];
    return NULL;
}

gp_module *gp_module_by_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    CC_SHA256_CTX c;
    CC_SHA256_Init(&c);
    uint8_t buf[65536], d[32];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f))) CC_SHA256_Update(&c, buf, (CC_LONG)n);
    fclose(f);
    CC_SHA256_Final(d, &c);
    for (int i = 0; i < nmodules; i++) if (!memcmp(d, modules[i].sha256, 32)) return &modules[i];
    return NULL;
}

static void map_image(gp_module *m, const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) gp_fatal("cannot open cached image %s", path);
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *raw = malloc((size_t)len);
    if (!raw || fread(raw, 1, (size_t)len, f) != (size_t)len) gp_fatal("cannot read %s", path);
    fclose(f);
    uint32_t pe; memcpy(&pe, raw + 0x3c, 4);
    if ((long)pe + 0xf8 > len || memcmp(raw + pe, "PE\0\0", 4)) gp_fatal("%s: not a PE image", path);
    uint16_t nsec, optsize; memcpy(&nsec, raw + pe + 6, 2); memcpy(&optsize, raw + pe + 20, 2);
    uint32_t base, size, hdrs;
    memcpy(&base, raw + pe + 24 + 28, 4); memcpy(&size, raw + pe + 24 + 56, 4); memcpy(&hdrs, raw + pe + 24 + 60, 4);
    if (base != m->base || size != m->size) gp_fatal("%s: image base/size do not match the cache index", path);
    if (gp_vm_reserve(base, size) != base) gp_fatal("%s: guest range 0x%08x+0x%x is not free", m->name, base, size);
    if (hdrs > (uint32_t)len) gp_fatal("%s: bad header size", path);
    memcpy(G(base), raw, hdrs);
    const uint8_t *sec = raw + pe + 24 + optsize;
    for (int i = 0; i < nsec; i++, sec += 40) {
        uint32_t vsize, va, rsize, roff;
        memcpy(&vsize, sec + 8, 4); memcpy(&va, sec + 12, 4); memcpy(&rsize, sec + 16, 4); memcpy(&roff, sec + 20, 4);
        uint32_t n = rsize < vsize || !vsize ? rsize : vsize;
        if ((uint64_t)roff + n > (uint64_t)len || (uint64_t)va + (vsize > n ? vsize : n) > size)
            gp_fatal("%s: section %d outside file or image", path, i);
        memcpy(G(base + va), raw + roff, n);
    }
    free(raw);
}

gaddr gp_module_export(gp_module *m, const char *name)
{
    gaddr b = m->base;
    uint32_t pe = rd32(b + 0x3c), dir = rd32(b + pe + 0x78);
    if (!dir) return 0;
    gaddr e = b + dir;
    uint32_t nnames = rd32(e + 24), funcs = rd32(e + 28), names = rd32(e + 32), ords = rd32(e + 36);
    if ((uintptr_t)name < 0x10000) {   /* by ordinal */
        uint32_t idx = (uint32_t)(uintptr_t)name - rd32(e + 16);
        return idx < rd32(e + 20) ? b + rd32(b + funcs + 4 * idx) : 0;
    }
    for (uint32_t i = 0; i < nnames; i++)
        if (!strcmp((const char *)G(b + rd32(b + names + 4 * i)), name))
            return b + rd32(b + funcs + 4 * rd16(b + ords + 2 * i));
    return 0;
}

bool gp_module_init(gp_module *m, gp_thread *t)
{
    if (m->initialized || !m->is_dll || !m->entry) { m->initialized = true; return true; }
    m->initialized = true;
    uint32_t args[3] = { m->base, 1 /* DLL_PROCESS_ATTACH */, 0 };
    gp_log("init %s (DllMain 0x%08x)", m->name, m->entry);
    return gp_call_guest(t, m->entry, 3, args) != 0;
}

void gp_modules_load(const char *cache)
{
    char path[1400];
    snprintf(path, sizeof path, "%s/modules.txt", cache);
    FILE *f = fopen(path, "r");
    if (!f) gp_fatal("cannot open %s", path);
    char name[128], unit[128], hex[65];
    unsigned base, size, entry, dll, stack;
    while (fscanf(f, "%127s %127s %x %x %x %u %x %64s", name, unit, &base, &size, &entry, &dll, &stack, hex) == 8) {
        if (nmodules == MAX_MODULES) gp_fatal("too many modules");
        gp_module *m = &modules[nmodules++];
        m->name = strdup(name); m->unit = strdup(unit);
        m->base = base; m->size = size; m->entry = entry; m->is_dll = dll;
        for (int i = 0; i < 32; i++) { unsigned b; sscanf(hex + 2 * i, "%2x", &b); m->sha256[i] = (uint8_t)b; }
        char sym[200];
        snprintf(sym, sizeof sym, "tc_guest_invoke_%s", unit);
        m->invoke = (void (*)(_cpu *, uint32_t))dlsym(RTLD_DEFAULT, sym);
        snprintf(sym, sizeof sym, "tc_guest_lookup_%s", unit);
        m->lookup = (void *(*)(uint32_t))dlsym(RTLD_DEFAULT, sym);
        if (!m->invoke || !m->lookup) gp_fatal("translated code for %s is missing (%s)", name, dlerror());
        snprintf(path, sizeof path, "%s/images/%s.bound.pe", cache, name);
        map_image(m, path);
    }
    fclose(f);
    if (!nmodules) gp_fatal("%s lists no modules", path);
    gp_imports_load(cache);
}

/* ------------------------------------------------------------ native imports */
typedef struct { const char *dll, *name; const gp_api *api; } slot;
#define DYN_BASE 0x10000u
#define DYN_COUNT 512u
#define DYN_ADDR 0xE8000000u
static slot *slots;
static uint32_t nslots;
static slot dyn[DYN_COUNT];
static uint32_t ndyn;
static pthread_mutex_t dyn_lock = PTHREAD_MUTEX_INITIALIZER;

static const gp_api *find_api(const char *dll, const char *name)
{
    for (const gp_api *const *table = gp_api_tables; *table; table++)
        for (const gp_api *a = *table; a->name; a++)
            if (!strcasecmp(a->dll, dll) && !strcmp(a->name, name)) return a;
    return NULL;
}

void gp_imports_load(const char *cache)
{
    char path[1200];
    snprintf(path, sizeof path, "%s/imports.txt", cache);
    FILE *f = fopen(path, "r");
    if (!f) gp_fatal("cannot open %s", path);
    unsigned idx; char dll[64], name[256];
    while (fscanf(f, "%u %63s %255s", &idx, dll, name) == 3) {
        if (idx >= nslots) {
            slots = realloc(slots, sizeof(slot) * (idx + 1));
            memset(slots + nslots, 0, sizeof(slot) * (idx + 1 - nslots));
            nslots = idx + 1;
        }
        slots[idx].dll = strdup(dll); slots[idx].name = strdup(name);
        slots[idx].api = find_api(dll, name);
    }
    fclose(f);
}

/* GetProcAddress on a native DLL: a thunk address from the static table or the spare pool. */
gaddr gp_native_proc(const char *dll, const char *name)
{
    for (uint32_t i = 0; i < nslots; i++)
        if (slots[i].dll && !strcasecmp(slots[i].dll, dll) && !strcmp(slots[i].name, name))
            return 0xE0000000u + 8 * i;
    const gp_api *a = find_api(dll, name);
    if (!a) return 0;                      /* Windows: function not exported -> NULL */
    return gp_native_thunk(dll, name);
}

/* Thunk address for a native function or COM method. A name without a handler
   still gets a thunk; calling it traps with the name. */
gaddr gp_native_thunk(const char *dll, const char *name)
{
    const gp_api *a = find_api(dll, name);
    pthread_mutex_lock(&dyn_lock);
    for (uint32_t i = 0; i < ndyn; i++)
        if (!strcasecmp(dyn[i].dll, dll) && !strcmp(dyn[i].name, name)) { pthread_mutex_unlock(&dyn_lock); return DYN_ADDR + 8 * i; }
    if (ndyn == DYN_COUNT) gp_fatal("dynamic import pool exhausted at %s!%s", dll, name);
    dyn[ndyn] = (slot){ strdup(dll), strdup(name), a };
    gaddr r = DYN_ADDR + 8 * ndyn++;
    pthread_mutex_unlock(&dyn_lock);
    return r;
}

volatile bool gp_trace_frame_active;   /* set by the device for GP_TRACE_FRAME */

uint32_t gp_import(_cpu *cpu, uint32_t index)
{
    gp_thread *t = T(cpu);
    slot *s = index >= DYN_BASE ? (index - DYN_BASE < ndyn ? &dyn[index - DYN_BASE] : NULL)
                                : (index < nslots ? &slots[index] : NULL);
    if (!s) gp_fatal("import thunk %u has no table entry", index);
    if (!s->api)
        gp_fatal("unimplemented import %s!%s called from 0x%08x", s->dll, s->name, rd32(cpu->_esp));
    uint32_t ret = rd32(cpu->_esp);
    static int trace = -1;
    if (trace < 0) trace = getenv("GP_TRACE_API") ? atoi(getenv("GP_TRACE_API")) : 0;
    bool tr = trace || gp_trace_frame_active;
    if (tr) gp_log("api %s!%s from 0x%08x", s->dll, s->name, ret);
    cpu->_eax = s->api->fn(t);
    if (tr && trace > 1) gp_log("  -> 0x%08x", cpu->_eax);
    static const char *fail_filter = (const char *)1;
    if (fail_filter == (const char *)1) fail_filter = getenv("GP_TRACE_FAIL");
    bool fail_hit = false;
    if (fail_filter && cpu->_eax) {                    /* comma-separated substrings of the DLL/interface name */
        char list[128]; snprintf(list, sizeof list, "%s", fail_filter);
        for (char *save = NULL, *tok = strtok_r(list, ",", &save); tok; tok = strtok_r(NULL, ",", &save))
            if (strstr(s->dll, tok)) fail_hit = true;
    }
    if (fail_hit) gp_log("fail %s!%s -> 0x%08x from 0x%08x", s->dll, s->name, cpu->_eax, ret);
    static int fxcheck = -1;
    if (fxcheck < 0) fxcheck = getenv("GP_FX_CHECK") != NULL;
    if (fxcheck) { extern void gp_fx_debug_check(const char *, uint32_t); gp_fx_debug_check(s->name, ret); }
    cpu->_esp += 4 + s->api->argbytes;
    return ret;
}
