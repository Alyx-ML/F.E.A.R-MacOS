/* Native Win32/COM API handlers reachable from guest import thunks. */
#ifndef GP_API_H
#define GP_API_H
#include "gp.h"

typedef struct {
    const char *dll;          /* lower-case, e.g. "kernel32.dll" */
    const char *name;
    uint16_t argbytes;        /* bytes the callee pops (stdcall); 0 for cdecl */
    gp_api_fn fn;
} gp_api;

extern const gp_api *const gp_api_tables[];   /* NULL-terminated */

void gp_imports_load(const char *cache);
gaddr gp_native_proc(const char *dll, const char *name);
gaddr gp_native_thunk(const char *dll, const char *name);

/* COM: a guest vtable whose entries are native thunks "iface"!"method" (built once) */
gaddr gp_com_vtable(const char *iface, const char *const *methods, int n);
/* new COM object: guest block {vtable, refcount, extra...}; returns guest pointer */
gaddr gp_com_new(gaddr vtable, uint32_t extra_bytes);
/* guid helpers */
bool gp_guid_eq(gaddr g, const char *text);   /* text: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" */

/* argument helpers */
#define A(i) gp_arg(t, (i))
static inline const char *gstr(gaddr a) { return a ? (const char *)G(a) : NULL; }

/* thread-local Windows last error */
static inline void set_error(gp_thread *t, uint32_t e) { t->last_error = e; }

/* one table entry: API(fn, "Name", argument count) */
#define API(fn, name, nargs) { DLL, name, (nargs) * 4, fn }
#define API_CDECL(fn, name) { DLL, name, 0, fn }

#endif
