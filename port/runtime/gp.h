/* F.E.A.R. native runtime: shared definitions.
 *
 * Guest memory is one 4 GiB window. A guest address g lives at host
 * address gp_mem + g. Translated code reaches it through cpu->_pointer_offset.
 */
#ifndef GP_H
#define GP_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <pthread.h>

#define PTROFS_64BIT 1
#include "llasm_cpu.h"
#undef eax
#undef ebx
#undef ecx
#undef edx
#undef esi
#undef edi
#undef ebp
#undef esp
#undef eflags

typedef uint32_t gaddr;           /* guest address */

extern uint8_t *gp_mem;           /* host base of the guest window */

static inline void *G(gaddr a) { return gp_mem + a; }
static inline gaddr H(const void *p) { return (gaddr)((const uint8_t *)p - gp_mem); }
static inline uint32_t rd32(gaddr a) { uint32_t v; __builtin_memcpy(&v, G(a), 4); return v; }
static inline uint16_t rd16(gaddr a) { uint16_t v; __builtin_memcpy(&v, G(a), 2); return v; }
static inline uint8_t rd8(gaddr a) { return *(uint8_t *)G(a); }
static inline void wr32(gaddr a, uint32_t v) { __builtin_memcpy(G(a), &v, 4); }
static inline void wr16(gaddr a, uint16_t v) { __builtin_memcpy(G(a), &v, 2); }
static inline void wr8(gaddr a, uint8_t v) { *(uint8_t *)G(a) = v; }

/* Per guest thread state. The llasm CPU struct must stay first. */
typedef struct gp_thread {
    _cpu cpu;
    gaddr teb;                    /* guest TEB (FS base) */
    gaddr stack_base, stack_limit;
    uint32_t thread_id;
    uint32_t last_error;
    uint64_t tsc_base;
    uint64_t mm[8];               /* MMX registers (tc_mmx_*) */
} gp_thread;

static inline gp_thread *T(_cpu *cpu) { return (gp_thread *)cpu; }

/* fatal diagnostics: always name the guest address / API involved */
_Noreturn void gp_fatal(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void gp_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

/* vm */
void gp_vm_init(void);
gaddr gp_vm_reserve(gaddr want, uint32_t size);      /* 64 KiB granular; want=0: any */
bool gp_vm_release(gaddr base);
bool gp_vm_query(gaddr a, gaddr *base, uint32_t *size);

/* heap (guest memory) */
gaddr gp_heap_alloc(uint32_t size, bool zero);
bool gp_heap_free(gaddr p);
uint32_t gp_heap_size(gaddr p);
gaddr gp_heap_realloc(gaddr p, uint32_t size, bool zero);

/* threads */
gp_thread *gp_thread_create_state(uint32_t stack_size);   /* guest state only */
void gp_thread_attach(gp_thread *t);                        /* bind to the calling host thread */
gp_thread *gp_current(void);
uint32_t gp_main_thread_id(void);                           /* thread that runs WinMain */

/* calling guest code from native code (stdcall/cdecl args pushed right to left) */
uint32_t gp_call_guest(gp_thread *t, gaddr fn, int argc, const uint32_t *argv);
uint32_t gp_call_guest_this(gp_thread *t, gaddr fn, uint32_t this_ptr, int argc, const uint32_t *argv);   /* thiscall */
/* returns address of native thunk-dispatch target or traps */
void *tc_resolve_foreign(_cpu *cpu, uint32_t address);

/* modules */
typedef struct gp_module {
    const char *name;             /* e.g. "GameClient.dll" */
    const char *unit;             /* translated unit suffix */
    gaddr base;
    uint32_t size;
    gaddr entry;
    bool is_dll, initialized;
    uint8_t sha256[32];           /* of the original DLL file, to recognise extracted copies */
    void (*invoke)(_cpu *, uint32_t);
    void *(*lookup)(uint32_t);
} gp_module;

gp_module *gp_module_by_name(const char *name);
gp_module *gp_module_by_address(gaddr a);
gp_module *gp_module_by_file(const char *host_path);   /* by SHA-256 of the file */
gaddr gp_module_export(gp_module *m, const char *name);
bool gp_module_init(gp_module *m, gp_thread *t);     /* runs DllMain(PROCESS_ATTACH) once */
void gp_modules_load(const char *cache_dir);

/* strings in guest memory */
gaddr gp_strdup_guest(const char *s);
char *gp_path_to_host(const char *guest_path);       /* malloc'd; case-insensitive resolve */

extern char gp_game_dir[1024];

/* import thunks */
typedef uint32_t (*gp_api_fn)(gp_thread *t);         /* returns eax; reads args via gp_arg */
static inline uint32_t gp_arg(gp_thread *t, int i) { return rd32(t->cpu._esp + 4 + 4 * (uint32_t)i); }

#endif
