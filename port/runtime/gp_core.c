/* Guest address space, guest heap, guest threads and control transfer. */
#include <dlfcn.h>
#include <sys/ucontext.h>
#include "gp.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <signal.h>
#include <unistd.h>
#include <execinfo.h>

uint8_t *gp_mem;

#define GUEST_SPACE (UINT64_C(1) << 32)
#define GRAN 0x10000u                 /* VirtualAlloc reservation granularity */
#define NGRAN (uint32_t)(GUEST_SPACE / GRAN)
#define LOW_GUARD 0x10000u            /* guest NULL page region stays unmapped */

static pthread_mutex_t vm_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t region_len[NGRAN];    /* granules in the region starting here; 0 = not a start */
static uint8_t used[NGRAN];

static pthread_key_t thread_key;

void gp_log(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static void dump_thread(void)
{
    gp_thread *t = pthread_getspecific(thread_key);
    if (!t) return;
    _cpu *c = &t->cpu;
    fprintf(stderr, "guest: eax=%08x ecx=%08x edx=%08x ebx=%08x esp=%08x ebp=%08x esi=%08x edi=%08x eflags=%08x\n",
            c->_eax, c->_ecx, c->_edx, c->_ebx, c->_esp, c->_ebp, c->_esi, c->_edi, c->_eflags);
    if (c->_esp >= LOW_GUARD) {
        fprintf(stderr, "guest stack:");
        for (int i = 0; i < 12; i++) fprintf(stderr, " %08x", rd32(c->_esp + 4 * i));
        fputc('\n', stderr);
    }
}

_Noreturn void gp_fatal(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fputs("FATAL: ", stderr);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    dump_thread();
    void *frames[32];
    int n = backtrace(frames, 32);
    backtrace_symbols_fd(frames, n, 2);
    fflush(stderr);
    _exit(70);
}

static void on_fault(int sig, siginfo_t *si, void *uc)
{
    uint8_t *a = si->si_addr;
    /* the faulting host instruction and the translated function that contains it */
    uint64_t pc = ((ucontext_t *)uc)->uc_mcontext->__ss.__pc;
    Dl_info di;
    if (dladdr((void *)pc, &di) && di.dli_sname)
        fprintf(stderr, "fault at host pc %#llx: %s + %#llx\n", (unsigned long long)pc, di.dli_sname,
                (unsigned long long)(pc - (uint64_t)di.dli_saddr));
    else fprintf(stderr, "fault at host pc %#llx\n", (unsigned long long)pc);
    if (gp_mem && a >= gp_mem && a < gp_mem + GUEST_SPACE)
        gp_fatal("signal %d: guest memory fault at guest address 0x%08x", sig, (unsigned)(a - gp_mem));
    gp_fatal("signal %d: host fault at %p", sig, si->si_addr);
}

void gp_vm_init(void)
{
    /* Reserve the whole 4 GiB window readable/writable; pages are materialised
       on first touch. The low guard stays inaccessible so guest NULL
       dereferences fault with a clear diagnostic. */
    void *p = mmap(NULL, GUEST_SPACE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    if (p == MAP_FAILED) gp_fatal("cannot reserve 4 GiB guest address space");
    gp_mem = p;
    if (mprotect(gp_mem, LOW_GUARD, PROT_NONE)) gp_fatal("cannot protect guest NULL page");
    for (uint32_t i = 0; i < LOW_GUARD / GRAN; i++) used[i] = 1;
    /* the top 512 MiB hold native thunk addresses and are never guest data */
    for (uint32_t i = 0xE0000000u / GRAN; i < NGRAN; i++) used[i] = 1;
    pthread_key_create(&thread_key, NULL);
    struct sigaction sa = {0};
    sa.sa_sigaction = on_fault;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
}

gaddr gp_vm_reserve(gaddr want, uint32_t size)
{
    uint32_t n = (uint32_t)(((uint64_t)size + GRAN - 1) / GRAN);
    if (n == 0) return 0;
    pthread_mutex_lock(&vm_lock);
    uint32_t start = 0;
    if (want) {
        start = want / GRAN;
        if ((uint64_t)start + n > NGRAN) goto fail;
        for (uint32_t i = start; i < start + n; i++) if (used[i]) goto fail;
    } else {
        /* first fit above the images; allocations grow upward from 0x20000000 */
        uint32_t run = 0;
        for (uint32_t i = 0x20000000u / GRAN; i < NGRAN; i++) {
            run = used[i] ? 0 : run + 1;
            if (run == n) { start = i + 1 - n; break; }
        }
        if (!start) goto fail;
    }
    for (uint32_t i = start; i < start + n; i++) used[i] = 1;
    region_len[start] = n;
    pthread_mutex_unlock(&vm_lock);
    /* never-used and released regions are fresh zero pages (see gp_vm_release) */
    return start * GRAN;
fail:
    pthread_mutex_unlock(&vm_lock);
    return 0;
}

bool gp_vm_release(gaddr base)
{
    if (base % GRAN) return false;
    pthread_mutex_lock(&vm_lock);
    uint32_t s = base / GRAN, n = region_len[s];
    if (!n) { pthread_mutex_unlock(&vm_lock); return false; }
    for (uint32_t i = s; i < s + n; i++) used[i] = 0;
    region_len[s] = 0;
    /* replace with fresh zero pages: returns memory to the host and keeps the
       "new reservations are zeroed" guarantee */
    if (mmap(G(base), (size_t)n * GRAN, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0) == MAP_FAILED)
        gp_fatal("cannot recycle guest region 0x%08x", base);
    pthread_mutex_unlock(&vm_lock);
    return true;
}

bool gp_vm_query(gaddr a, gaddr *base, uint32_t *size)
{
    pthread_mutex_lock(&vm_lock);
    for (int64_t i = a / GRAN; i >= 0; i--) {
        if (region_len[i]) {
            bool in = (uint64_t)a < ((uint64_t)i + region_len[i]) * GRAN;
            if (in) { *base = (gaddr)(i * GRAN); *size = region_len[i] * GRAN; }
            pthread_mutex_unlock(&vm_lock);
            return in;
        }
        if (!used[i]) break;
    }
    pthread_mutex_unlock(&vm_lock);
    return false;
}

/* ------------------------------------------------------------------ heap
   Size classes of 16..2048 bytes with free lists; larger blocks get their own
   VM region. Every block has an 8-byte header {requested size, class}. Blocks are 8-byte
   aligned like the Windows heap. One lock: the game allocates mostly on one thread.
   ponytail: global lock; per-thread caches if profiling shows contention. */
#define NCLASS 128                   /* class c holds (c+1)*16 bytes */
#define CHUNK (1u << 20)
static pthread_mutex_t heap_lock = PTHREAD_MUTEX_INITIALIZER;
static gaddr free_list[NCLASS];
static gaddr chunk_cur, chunk_end;

gaddr gp_heap_alloc(uint32_t size, bool zero)
{
    if (size > 0x7ff00000u) return 0;
    uint32_t need = (size + 15u) & ~15u;
    if (need == 0) need = 16;
    gaddr p;
    if (need <= NCLASS * 16) {
        uint32_t c = need / 16 - 1;
        pthread_mutex_lock(&heap_lock);
        p = free_list[c];
        if (p) {
            free_list[c] = rd32(p);
        } else {
            if (chunk_cur + need + 8 > chunk_end) {
                gaddr ch = gp_vm_reserve(0, CHUNK);
                if (!ch) { pthread_mutex_unlock(&heap_lock); return 0; }
                chunk_cur = ch; chunk_end = ch + CHUNK;
            }
            wr32(chunk_cur + 4, c + 1);
            p = chunk_cur + 8;
            chunk_cur += need + 8;
        }
        wr32(p - 8, size);
        pthread_mutex_unlock(&heap_lock);
        if (zero) memset(G(p), 0, need);
        return p;
    }
    gaddr r = gp_vm_reserve(0, need + 8);   /* already zeroed */
    if (!r) return 0;
    wr32(r, size);
    wr32(r + 4, 0);
    return r + 8;
}

bool gp_heap_free(gaddr p)
{
    if (!p) return true;
    uint32_t c = rd32(p - 4);
    if (c == 0) return gp_vm_release(p - 8);
    if (c > NCLASS) gp_fatal("heap free of invalid block 0x%08x", p);
    pthread_mutex_lock(&heap_lock);
    wr32(p, free_list[c - 1]);
    free_list[c - 1] = p;
    pthread_mutex_unlock(&heap_lock);
    return true;
}

uint32_t gp_heap_size(gaddr p) { return rd32(p - 8); }

static uint32_t heap_capacity(gaddr p)
{
    uint32_t c = rd32(p - 4);
    if (c) return c * 16;
    gaddr base; uint32_t len;
    if (!gp_vm_query(p, &base, &len)) gp_fatal("heap block 0x%08x has no region", p);
    return len - 8;
}

gaddr gp_heap_realloc(gaddr p, uint32_t size, bool zero)
{
    if (!p) return gp_heap_alloc(size, zero);
    uint32_t old = gp_heap_size(p);
    if (size <= heap_capacity(p)) {
        if (zero && size > old) memset(G(p + old), 0, size - old);
        wr32(p - 8, size);
        return p;
    }
    gaddr n = gp_heap_alloc(size, zero);
    if (!n) return 0;
    memcpy(G(n), G(p), old < size ? old : size);
    gp_heap_free(p);
    return n;
}

gaddr gp_strdup_guest(const char *s)
{
    size_t n = strlen(s) + 1;
    gaddr g = gp_heap_alloc((uint32_t)n, false);
    if (!g) gp_fatal("guest heap exhausted");
    memcpy(G(g), s, n);
    return g;
}

/* --------------------------------------------------------------- threads */
static uint32_t next_tid = 0x100;
static pthread_mutex_t tid_lock = PTHREAD_MUTEX_INITIALIZER;

gp_thread *gp_current(void) { return pthread_getspecific(thread_key); }

static uint32_t main_tid;
uint32_t gp_main_thread_id(void) { return main_tid; }

gp_thread *gp_thread_create_state(uint32_t stack_size)
{
    /* The thread state lives in guest memory: llasm x87 helpers return guest
       pointers into the CPU struct (PTR2REG). */
    gaddr st = gp_vm_reserve(0, GRAN);
    gaddr stack = gp_vm_reserve(0, stack_size);
    if (!st || !stack) gp_fatal("cannot allocate guest thread (stack %u bytes)", stack_size);
    gp_thread *t = G(st);
    memset(t, 0, sizeof *t);
    t->cpu._pointer_offset = (uint64_t)(uintptr_t)gp_mem;
    t->cpu._st_cw = 0x027f;            /* Windows default: 53-bit precision, all masked */
    t->stack_limit = stack;
    t->stack_base = stack + stack_size;
    t->cpu._esp = t->stack_base - 16;
    t->teb = st + 0x1000;              /* TEB occupies the rest of the state region */
    pthread_mutex_lock(&tid_lock);
    t->thread_id = next_tid += 4;
    if (!main_tid) main_tid = t->thread_id;                    /* the first guest thread runs WinMain */
    pthread_mutex_unlock(&tid_lock);
    wr32(t->teb + 0x00, 0xffffffff);   /* SEH chain end */
    wr32(t->teb + 0x04, t->stack_base);
    wr32(t->teb + 0x08, t->stack_limit);
    wr32(t->teb + 0x18, t->teb);       /* self */
    wr32(t->teb + 0x20, (uint32_t)getpid());
    wr32(t->teb + 0x24, t->thread_id);
    wr32(t->teb + 0x2c, t->teb + 0xe10);  /* TLS slot array (TlsAlloc slots 0..63) */
    return t;
}

void gp_thread_attach(gp_thread *t) { pthread_setspecific(thread_key, t); }

/* -------------------------------------------------------- control transfer */
void *tc_resolve_foreign(_cpu *cpu, uint32_t address)
{
    gp_module *m = gp_module_by_address(address);
    if (m) {
        static const char *trace_module = (const char *)1;
        if (trace_module == (const char *)1) trace_module = getenv("GP_TRACE_CALLS_INTO");
        if (trace_module && !strcasecmp(trace_module, m->name)) gp_log("call into %s at 0x%08x from 0x%08x", m->name, address, rd32(cpu->_esp));
        void *f = m->lookup(address);
        if (f) return f;
        gp_fatal("jump to 0x%08x inside %s: no translated code at that address "
                 "(add it as a recovery seed); return address [esp]=0x%08x",
                 address, m->name, rd32(cpu->_esp));
    }
    static void *(*lookup_imports)(uint32_t);
    if (!lookup_imports) {
        lookup_imports = (void *(*)(uint32_t))dlsym(RTLD_DEFAULT, "tc_guest_lookup_imports");
        if (!lookup_imports) gp_fatal("the converted system-call unit is missing (%s)", dlerror());
    }
    void *f = lookup_imports(address);
    if (f) return f;
    gp_fatal("jump to unmapped guest address 0x%08x; [esp]=0x%08x", address, rd32(cpu->_esp));
}

static uint32_t call_guest(gp_thread *t, gaddr fn, bool set_this, uint32_t this_ptr, int argc, const uint32_t *argv);
uint32_t gp_call_guest(gp_thread *t, gaddr fn, int argc, const uint32_t *argv) { return call_guest(t, fn, false, 0, argc, argv); }
/* thiscall: ECX carries the object pointer */
uint32_t gp_call_guest_this(gp_thread *t, gaddr fn, uint32_t this_ptr, int argc, const uint32_t *argv) { return call_guest(t, fn, true, this_ptr, argc, argv); }

static uint32_t call_guest(gp_thread *t, gaddr fn, bool set_this, uint32_t this_ptr, int argc, const uint32_t *argv)
{
    _cpu saved = t->cpu;
    if (set_this) t->cpu._ecx = this_ptr;
    for (int i = argc - 1; i >= 0; i--) { t->cpu._esp -= 4; wr32(t->cpu._esp, argv[i]); }
    t->cpu._esp -= 4;
    wr32(t->cpu._esp, 0xffffffffu);    /* host-return sentinel */
    gp_module *m = gp_module_by_address(fn);
    if (!m) gp_fatal("native code called unmapped guest function 0x%08x", fn);
    m->invoke(&t->cpu, fn);
    uint32_t r = t->cpu._eax;
    uint32_t edx = t->cpu._edx;
    /* callee-saved registers and the stack pointer are restored for the native caller */
    uint32_t top = t->cpu._st_top;
    double st[8];
    memcpy(st, t->cpu._st, sizeof st);
    t->cpu = saved;
    t->cpu._eax = r;
    t->cpu._edx = edx;
    /* the callee may return a float in ST0 */
    t->cpu._st_top = top;
    memcpy(t->cpu._st, st, sizeof st);
    return r;
}
