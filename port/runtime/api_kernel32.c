/* kernel32.dll: process, memory, TLS, synchronisation primitives, strings, time. */
#include "gp_api.h"
#include "gp_win.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <sys/time.h>
#include <unistd.h>
#include <sched.h>
#include <mach/mach_time.h>

#define DLL "kernel32.dll"

/* ---------------------------------------------------------------- errors */
static uint32_t GetLastError_(gp_thread *t) { return t->last_error; }
static uint32_t SetLastError_(gp_thread *t) { t->last_error = A(0); return 0; }

/* ---------------------------------------------------------------- process */
static gaddr cmdline_a, cmdline_w, env_a, env_w;

static void build_strings(void)
{
    const char *cmd = "\"" GUEST_GAME_DIR "\\FEAR.exe\"";
    cmdline_a = gp_strdup_guest(cmd);
    cmdline_w = gp_wstrdup_guest(cmd);
    /* double-NUL-terminated environment block */
    static const char envs[] = "PATH=" GUEST_GAME_DIR "\0\0";
    env_a = gp_heap_alloc(sizeof envs, false);
    memcpy(G(env_a), envs, sizeof envs);
    env_w = gp_heap_alloc(2 * sizeof envs, false);
    for (size_t i = 0; i < sizeof envs; i++) wr16(env_w + 2 * i, (uint8_t)envs[i]);
}

static void init_strings(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, build_strings);
}

static uint32_t GetCommandLineA_(gp_thread *t) { (void)t; init_strings(); return cmdline_a; }
static uint32_t GetCommandLineW_(gp_thread *t) { (void)t; init_strings(); return cmdline_w; }
static uint32_t GetEnvironmentStrings_(gp_thread *t) { (void)t; init_strings(); return env_a; }
static uint32_t GetEnvironmentStringsW_(gp_thread *t) { (void)t; init_strings(); return env_w; }
static uint32_t FreeEnvironmentStrings_(gp_thread *t) { (void)t; return 1; }

static uint32_t GetEnvironmentVariableA_(gp_thread *t)
{
    /* The process has only PATH; everything else is "not found" like on Windows. */
    const char *name = gstr(A(0));
    if (strcasecmp(name, "PATH")) { set_error(t, ERROR_ENVVAR_NOT_FOUND); return 0; }
    const char *v = GUEST_GAME_DIR;
    uint32_t n = (uint32_t)strlen(v);
    if (A(2) <= n) return n + 1;
    memcpy(G(A(1)), v, n + 1);
    return n;
}

static uint32_t GetVersion_(gp_thread *t) { (void)t; return 0x0a280105; }   /* Windows XP SP2 5.1.2600 */

static uint32_t GetVersionExA_(gp_thread *t)
{
    gaddr p = A(0);
    uint32_t size = rd32(p);
    if (size != 148 && size != 156) { set_error(t, ERROR_INSUFFICIENT_BUFFER); return 0; }
    memset(G(p + 4), 0, size - 4);
    wr32(p + 4, 5); wr32(p + 8, 1); wr32(p + 12, 2600); wr32(p + 16, 2);   /* VER_PLATFORM_WIN32_NT */
    strcpy((char *)G(p + 20), "Service Pack 2");
    if (size == 156) { wr16(p + 148, 2); wr16(p + 150, 0); wr16(p + 152, 0x100); wr8(p + 154, 1); }
    return 1;
}

static uint32_t GetStartupInfoA_(gp_thread *t)
{
    gaddr p = A(0);
    memset(G(p), 0, 68);
    wr32(p, 68);
    return 0;
}

static uint32_t GetCurrentProcess_(gp_thread *t) { (void)t; return 0xffffffffu; }
static uint32_t GetCurrentThread_(gp_thread *t) { (void)t; return 0xfffffffeu; }
static uint32_t GetCurrentProcessId_(gp_thread *t) { (void)t; return (uint32_t)getpid(); }
static uint32_t GetCurrentThreadId_(gp_thread *t) { return t->thread_id; }

static uint32_t ExitProcess_(gp_thread *t)
{
    gp_log("ExitProcess(%u)", A(0));
    fflush(NULL);
    _exit((int)A(0));
}

static uint32_t TerminateProcess_(gp_thread *t)
{
    if (A(0) != 0xffffffffu) gp_fatal("TerminateProcess on another process");
    gp_log("TerminateProcess(%u)", A(1));
    fflush(NULL);
    _exit((int)A(1));
}

static uint32_t SetErrorMode_(gp_thread *t) { static uint32_t mode; uint32_t o = mode; mode = A(0); (void)t; return o; }
static uint32_t SetUnhandledExceptionFilter_(gp_thread *t) { static uint32_t f; uint32_t o = f; f = A(0); (void)t; return o; }
static uint32_t SetHandleCount_(gp_thread *t) { return A(0); }
static uint32_t DisableThreadLibraryCalls_(gp_thread *t) { (void)t; return 1; }

static uint32_t OutputDebugStringA_(gp_thread *t) { gp_log("debug: %s", gstr(A(0))); return 0; }
static uint32_t DebugBreak_(gp_thread *t) { gp_fatal("DebugBreak called from 0x%08x", rd32(t->cpu._esp)); }

/* ---------------------------------------------------------------- memory */
static uint32_t HeapCreate_(gp_thread *t) { (void)t; return 0x00150000u; }  /* all heaps share one allocator */
static uint32_t HeapDestroy_(gp_thread *t) { (void)t; return 1; }
static uint32_t GetProcessHeap_(gp_thread *t) { (void)t; return 0x00140000u; }

static uint32_t HeapAlloc_(gp_thread *t)
{
    gaddr p = gp_heap_alloc(A(2), (A(1) & HEAP_ZERO_MEMORY) != 0);
    if (!p) set_error(t, ERROR_NOT_ENOUGH_MEMORY);
    return p;
}
static uint32_t HeapFree_(gp_thread *t) { return gp_heap_free(A(2)); }
static uint32_t HeapSize_(gp_thread *t) { return A(2) ? gp_heap_size(A(2)) : 0xffffffffu; }
static uint32_t HeapReAlloc_(gp_thread *t)
{
    if (A(1) & HEAP_REALLOC_IN_PLACE_ONLY) {
        if (A(3) <= gp_heap_size(A(2))) return A(2);
        set_error(t, ERROR_NOT_ENOUGH_MEMORY);
        return 0;
    }
    gaddr p = gp_heap_realloc(A(2), A(3), (A(1) & HEAP_ZERO_MEMORY) != 0);
    if (!p) set_error(t, ERROR_NOT_ENOUGH_MEMORY);
    return p;
}
static uint32_t HeapValidate_(gp_thread *t) { (void)t; return 1; }
static uint32_t HeapCompact_(gp_thread *t) { (void)t; return 0x100000; }

static uint32_t VirtualAlloc_(gp_thread *t)
{
    gaddr want = A(0);
    uint32_t size = A(1), type = A(2);
    if (want && (type & MEM_COMMIT) && !(type & MEM_RESERVE)) {
        gaddr b; uint32_t s;
        if (gp_vm_query(want, &b, &s)) return want & ~0xfffu;   /* commit inside a reservation */
        set_error(t, ERROR_INVALID_ADDRESS);
        return 0;
    }
    gaddr p = gp_vm_reserve(want & ~0xffffu, size + (want & 0xffffu));
    if (!p) { set_error(t, ERROR_NOT_ENOUGH_MEMORY); return 0; }
    return want ? want : p;
}
static uint32_t VirtualFree_(gp_thread *t)
{
    if (A(2) & MEM_RELEASE) {
        if (gp_vm_release(A(0))) return 1;
        set_error(t, ERROR_INVALID_PARAMETER);
        return 0;
    }
    return 1;   /* MEM_DECOMMIT: pages stay valid; the next commit sees their old contents like a reused page */
}
static uint32_t VirtualProtect_(gp_thread *t)
{
    if (A(3)) wr32(A(3), PAGE_READWRITE);
    return 1;   /* the guest window is readable/writable; protection changes do not affect correct programs */
}
static uint32_t VirtualQuery_(gp_thread *t)
{
    gaddr a = A(0), info = A(1), b; uint32_t s;
    if (A(2) < 28) { set_error(t, ERROR_BAD_LENGTH); return 0; }
    memset(G(info), 0, 28);
    wr32(info, a & ~0xfffu);
    if (gp_vm_query(a, &b, &s)) {
        wr32(info + 4, b); wr32(info + 8, PAGE_READWRITE);
        wr32(info + 12, b + s - (a & ~0xfffu));
        wr32(info + 16, MEM_COMMIT); wr32(info + 20, PAGE_READWRITE); wr32(info + 24, MEM_PRIVATE);
    } else {
        wr32(info + 12, 0x1000); wr32(info + 16, MEM_FREE); wr32(info + 20, PAGE_NOACCESS);
    }
    return 28;
}

static bool readable(gaddr a, uint32_t n)
{
    if (!n) return true;
    if (a < 0x10000 || (uint64_t)a + n > 0xE0000000ull) return false;
    gaddr b; uint32_t s;
    if (gp_module_by_address(a)) return true;
    return gp_vm_query(a, &b, &s) && (uint64_t)a + n <= (uint64_t)b + s;
}
static uint32_t IsBadReadPtr_(gp_thread *t) { return !readable(A(0), A(1)); }
static uint32_t IsBadWritePtr_(gp_thread *t) { return !readable(A(0), A(1)); }
static uint32_t IsBadCodePtr_(gp_thread *t) { gaddr a = A(0); return !(gp_module_by_address(a) || a >= 0xE0000000u); }

static uint32_t GlobalMemoryStatus_(gp_thread *t)
{
    gaddr p = A(0);
    wr32(p, 32); wr32(p + 4, 30);
    wr32(p + 8, 0x7fff0000u); wr32(p + 12, 0x60000000u);     /* 2 GiB physical, 1.5 GiB free */
    wr32(p + 16, 0x7fff0000u); wr32(p + 20, 0x60000000u);
    wr32(p + 24, 0x7ffe0000u); wr32(p + 28, 0x60000000u);
    return 0;
}

/* The guest sees a fixed Windows layout; nothing is ever read from these directories. */
static uint32_t copy_dir(gp_thread *t, const char *dir)
{
    uint32_t len = (uint32_t)strlen(dir);
    if (!A(0) || A(1) < len + 1) return len + 1;                    /* too small: the size needed with the terminator */
    memcpy(G(A(0)), dir, len + 1);
    (void)t;
    return len;
}
static uint32_t GetWindowsDirectoryA_(gp_thread *t) { return copy_dir(t, "C:\\WINDOWS"); }
static uint32_t GetSystemDirectoryA_(gp_thread *t) { return copy_dir(t, "C:\\WINDOWS\\system32"); }

static uint32_t GetSystemInfo_(gp_thread *t)
{
    gaddr p = A(0);
    memset(G(p), 0, 36);
    wr32(p + 4, 0x1000);                      /* page size */
    wr32(p + 8, 0x10000); wr32(p + 12, 0x7ffeffff);
    wr32(p + 16, 1); wr32(p + 20, 1);         /* one processor: guest threads are few and scheduling is native */
    wr32(p + 24, 586); wr32(p + 28, 0x10000);
    wr16(p + 32, 6);
    return 0;
}

/* ---------------------------------------------------------------- TLS */
static pthread_mutex_t tls_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t tls_used;
static uint32_t TlsAlloc_(gp_thread *t)
{
    pthread_mutex_lock(&tls_lock);
    for (uint32_t i = 0; i < 64; i++)
        if (!(tls_used & (1ull << i))) { tls_used |= 1ull << i; pthread_mutex_unlock(&tls_lock); return i; }
    pthread_mutex_unlock(&tls_lock);
    set_error(t, ERROR_NO_MORE_ITEMS);
    return 0xffffffffu;
}
static uint32_t TlsFree_(gp_thread *t)
{
    if (A(0) >= 64) { set_error(t, ERROR_INVALID_PARAMETER); return 0; }
    pthread_mutex_lock(&tls_lock); tls_used &= ~(1ull << A(0)); pthread_mutex_unlock(&tls_lock);
    return 1;
}
static uint32_t TlsGetValue_(gp_thread *t)
{
    if (A(0) >= 64) { set_error(t, ERROR_INVALID_PARAMETER); return 0; }
    set_error(t, 0);
    return rd32(t->teb + 0xe10 + 4 * A(0));
}
static uint32_t TlsSetValue_(gp_thread *t)
{
    if (A(0) >= 64) { set_error(t, ERROR_INVALID_PARAMETER); return 0; }
    wr32(t->teb + 0xe10 + 4 * A(0), A(1));
    return 1;
}

/* ------------------------------------------------------ critical sections
   CRITICAL_SECTION (24 bytes): the LockSemaphore field (+16) holds an index
   into a host table of recursive mutexes. */
#define MAX_CS 4096
static pthread_mutex_t cs_table[MAX_CS];
static uint32_t cs_count;
static pthread_mutex_t cs_alloc = PTHREAD_MUTEX_INITIALIZER;

static pthread_mutex_t *cs_get(gaddr cs, bool create)
{
    uint32_t id = rd32(cs + 16);
    if (id >= 0x80000000u && id - 0x80000000u < cs_count) return &cs_table[id - 0x80000000u];
    if (!create) gp_fatal("critical section 0x%08x used before InitializeCriticalSection", cs);
    pthread_mutex_lock(&cs_alloc);
    if (cs_count == MAX_CS) gp_fatal("too many critical sections");
    pthread_mutexattr_t at;
    pthread_mutexattr_init(&at);
    pthread_mutexattr_settype(&at, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&cs_table[cs_count], &at);
    id = 0x80000000u + cs_count++;
    pthread_mutex_unlock(&cs_alloc);
    memset(G(cs), 0, 24);
    wr32(cs + 4, 0xffffffffu);   /* LockCount */
    wr32(cs + 16, id);
    return &cs_table[id - 0x80000000u];
}
static uint32_t InitializeCriticalSection_(gp_thread *t) { cs_get(A(0), true); return 0; }
static uint32_t InitializeCriticalSectionAndSpinCount_(gp_thread *t) { cs_get(A(0), true); return 1; }
static uint32_t DeleteCriticalSection_(gp_thread *t) { (void)t; return 0; }   /* slot reuse is not needed: sections live for the process */
static uint32_t EnterCriticalSection_(gp_thread *t)
{
    gaddr cs = A(0);
    pthread_mutex_lock(cs_get(cs, false));
    wr32(cs + 12, t->thread_id);                  /* OwningThread */
    wr32(cs + 8, rd32(cs + 8) + 1);               /* RecursionCount */
    return 0;
}
static uint32_t LeaveCriticalSection_(gp_thread *t)
{
    gaddr cs = A(0);
    uint32_t n = rd32(cs + 8) - 1;
    wr32(cs + 8, n);
    if (!n) wr32(cs + 12, 0);
    pthread_mutex_unlock(cs_get(cs, false));
    (void)t;
    return 0;
}

static uint32_t InterlockedIncrement_(gp_thread *t) { return __atomic_add_fetch((uint32_t *)G(A(0)), 1, __ATOMIC_SEQ_CST); }
static uint32_t InterlockedDecrement_(gp_thread *t) { return __atomic_sub_fetch((uint32_t *)G(A(0)), 1, __ATOMIC_SEQ_CST); }
static uint32_t InterlockedExchange_(gp_thread *t) { return __atomic_exchange_n((uint32_t *)G(A(0)), A(1), __ATOMIC_SEQ_CST); }

/* ---------------------------------------------------------------- time */
static uint32_t GetTickCount_(gp_thread *t) { (void)t; return (uint32_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000); }
static uint32_t QueryPerformanceFrequency_(gp_thread *t) { wr32(A(0), 1000000000u); wr32(A(0) + 4, 0); return 1; }
static uint32_t QueryPerformanceCounter_(gp_thread *t)
{
    uint64_t ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    wr32(A(0), (uint32_t)ns); wr32(A(0) + 4, (uint32_t)(ns >> 32));
    return 1;
}
static uint64_t filetime_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return ((uint64_t)ts.tv_sec + 11644473600ull) * 10000000ull + (uint64_t)ts.tv_nsec / 100;
}
static uint32_t GetSystemTimeAsFileTime_(gp_thread *t)
{
    uint64_t ft = filetime_now();
    wr32(A(0), (uint32_t)ft); wr32(A(0) + 4, (uint32_t)(ft >> 32));
    return 0;
}
static void write_systemtime(gaddr p, const struct tm *tm, uint32_t ms)
{
    wr16(p, (uint16_t)(tm->tm_year + 1900)); wr16(p + 2, (uint16_t)(tm->tm_mon + 1));
    wr16(p + 4, (uint16_t)tm->tm_wday); wr16(p + 6, (uint16_t)tm->tm_mday);
    wr16(p + 8, (uint16_t)tm->tm_hour); wr16(p + 10, (uint16_t)tm->tm_min);
    wr16(p + 12, (uint16_t)tm->tm_sec); wr16(p + 14, (uint16_t)ms);
}
static uint32_t GetLocalTime_(gp_thread *t)
{
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tm; time_t s = tv.tv_sec; localtime_r(&s, &tm);
    write_systemtime(A(0), &tm, (uint32_t)(tv.tv_usec / 1000));
    return 0;
}
static uint64_t rd64(gaddr a) { return (uint64_t)rd32(a) | ((uint64_t)rd32(a + 4) << 32); }
static void wr64k(gaddr a, uint64_t v) { wr32(a, (uint32_t)v); wr32(a + 4, (uint32_t)(v >> 32)); }
#define FT_EPOCH 11644473600ll                     /* seconds from 1601-01-01 to 1970-01-01 */

static int64_t utc_offset_seconds(time_t at)
{
    struct tm lt;
    localtime_r(&at, &lt);
    return lt.tm_gmtoff;
}
static uint32_t FileTimeToLocalFileTime_(gp_thread *t)
{
    uint64_t ft = rd64(A(0));
    time_t at = (time_t)((int64_t)(ft / 10000000ull) - FT_EPOCH);
    wr64k(A(1), (uint64_t)((int64_t)ft + utc_offset_seconds(at) * 10000000ll));
    return 1;
}
static uint32_t LocalFileTimeToFileTime_(gp_thread *t)
{
    uint64_t ft = rd64(A(0));
    time_t at = (time_t)((int64_t)(ft / 10000000ull) - FT_EPOCH);
    wr64k(A(1), (uint64_t)((int64_t)ft - utc_offset_seconds(at) * 10000000ll));
    return 1;
}
static uint32_t FileTimeToSystemTime_(gp_thread *t)
{
    uint64_t ft = rd64(A(0));
    if (ft >> 63) { set_error(t, ERROR_INVALID_PARAMETER); return 0; }
    time_t s = (time_t)((int64_t)(ft / 10000000ull) - FT_EPOCH);
    struct tm tm;
    gmtime_r(&s, &tm);
    write_systemtime(A(1), &tm, (uint32_t)((ft / 10000) % 1000));
    return 1;
}
static uint32_t SystemTimeToFileTime_(gp_thread *t)
{
    gaddr st = A(0);
    struct tm tm = { .tm_year = rd16(st) - 1900, .tm_mon = rd16(st + 2) - 1, .tm_mday = rd16(st + 6),
                     .tm_hour = rd16(st + 8), .tm_min = rd16(st + 10), .tm_sec = rd16(st + 12) };
    if (tm.tm_mon < 0 || tm.tm_mon > 11 || tm.tm_mday < 1 || tm.tm_mday > 31 || tm.tm_hour > 23 || tm.tm_min > 59 || tm.tm_sec > 59) {
        set_error(t, ERROR_INVALID_PARAMETER); return 0;
    }
    int64_t s = (int64_t)timegm(&tm) + FT_EPOCH;
    wr64k(A(1), (uint64_t)s * 10000000ull + (uint64_t)rd16(st + 14) * 10000ull);
    return 1;
}
static uint32_t GetTimeZoneInformation_(gp_thread *t)
{
    /* Bias and names from the host zone; daylight rules are not expressed (TIME_ZONE_ID_UNKNOWN) */
    gaddr p = A(0);
    memset(G(p), 0, 172);
    time_t now = time(NULL);
    struct tm lt;
    localtime_r(&now, &lt);
    int32_t bias = (int32_t)(-lt.tm_gmtoff / 60);
    wr32(p, (uint32_t)(lt.tm_isdst ? bias + 60 : bias));
    const char *name = lt.tm_zone ? lt.tm_zone : "UTC";
    for (int i = 0; name[i] && i < 31; i++) { wr16(p + 4 + 2 * (uint32_t)i, (uint8_t)name[i]); wr16(p + 88 + 2 * (uint32_t)i, (uint8_t)name[i]); }
    if (lt.tm_isdst) wr32(p + 168, (uint32_t)-60);
    return 0;
}

static uint32_t Sleep_(gp_thread *t)
{
    uint32_t ms = A(0);
    if (ms == 0) sched_yield();
    else if (ms != 0xffffffffu) { struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L }; nanosleep(&ts, NULL); }
    else for (;;) pause();
    return 0;
}

/* ----------------------------------------------------------- codepages
   ANSI code page 1252 (Western European) as on an English Windows install. */
static const uint16_t cp1252_hi[32] = {
    0x20ac,0x0081,0x201a,0x0192,0x201e,0x2026,0x2020,0x2021,0x02c6,0x2030,0x0160,0x2039,0x0152,0x008d,0x017d,0x008f,
    0x0090,0x2018,0x2019,0x201c,0x201d,0x2022,0x2013,0x2014,0x02dc,0x2122,0x0161,0x203a,0x0153,0x009d,0x017e,0x0178 };
uint16_t gp_cp1252_to_wc(uint8_t c) { return c >= 0x80 && c < 0xa0 ? cp1252_hi[c - 0x80] : c; }
int gp_wc_to_cp1252(uint16_t w)
{
    if (w < 0x80 || (w >= 0xa0 && w < 0x100)) return w;
    for (int i = 0; i < 32; i++) if (cp1252_hi[i] == w) return 0x80 + i;
    return -1;
}

static uint32_t GetACP_(gp_thread *t) { (void)t; return 1252; }
static uint32_t GetOEMCP_(gp_thread *t) { (void)t; return 437; }
static uint32_t IsValidCodePage_(gp_thread *t) { uint32_t cp = A(0); return cp == 1252 || cp == 437 || cp == 65001; }
static uint32_t GetCPInfo_(gp_thread *t)
{
    gaddr p = A(1);
    memset(G(p), 0, 20);
    wr32(p, 1);                 /* MaxCharSize: single-byte code pages only */
    wr8(p + 4, '?');
    return A(0) == 0 || A(0) == 1252 || A(0) == 437 || A(0) == 1;
}
static uint32_t IsDBCSLeadByteEx_(gp_thread *t) { (void)t; return 0; }

static bool ansi_cp(uint32_t cp) { return cp == 0 || cp == 1 || cp == 3 || cp == 1252; }

static uint32_t MultiByteToWideChar_(gp_thread *t)
{
    uint32_t cp = A(0); gaddr src = A(2); int32_t n = (int32_t)A(3); gaddr dst = A(4); uint32_t cap = A(5);
    if (!ansi_cp(cp) && cp != 437) gp_fatal("MultiByteToWideChar code page %u", cp);
    uint32_t len = n < 0 ? (uint32_t)strlen(gstr(src)) + 1 : (uint32_t)n;
    if (!cap) return len;
    if (cap < len) { set_error(t, ERROR_INSUFFICIENT_BUFFER); return 0; }
    for (uint32_t i = 0; i < len; i++) wr16(dst + 2 * i, gp_cp1252_to_wc(rd8(src + i)));
    return len;
}
static uint32_t WideCharToMultiByte_(gp_thread *t)
{
    uint32_t cp = A(0); gaddr src = A(2); int32_t n = (int32_t)A(3); gaddr dst = A(4); uint32_t cap = A(5);
    gaddr defchar = A(6), used = A(7);
    if (!ansi_cp(cp) && cp != 437) gp_fatal("WideCharToMultiByte code page %u", cp);
    uint32_t len = 0;
    if (n < 0) { while (rd16(src + 2 * len)) len++; len++; } else len = (uint32_t)n;
    if (!cap) return len;
    if (cap < len) { set_error(t, ERROR_INSUFFICIENT_BUFFER); return 0; }
    bool any = false;
    for (uint32_t i = 0; i < len; i++) {
        int c = gp_wc_to_cp1252(rd16(src + 2 * i));
        if (c < 0) { c = defchar ? rd8(defchar) : '?'; any = true; }
        wr8(dst + i, (uint8_t)c);
    }
    if (used) wr32(used, any);
    return len;
}

/* LCMapString / GetStringType / CompareString for the "C"/English locale */
static uint32_t LCMapStringA_(gp_thread *t)
{
    uint32_t flags = A(1); gaddr src = A(2); int32_t n = (int32_t)A(3); gaddr dst = A(4); uint32_t cap = A(5);
    uint32_t len = n < 0 ? (uint32_t)strlen(gstr(src)) + 1 : (uint32_t)n;
    if (flags & ~(LCMAP_LOWERCASE | LCMAP_UPPERCASE)) gp_fatal("LCMapStringA flags 0x%x", flags);
    if (!cap) return len;
    if (cap < len) { set_error(t, ERROR_INSUFFICIENT_BUFFER); return 0; }
    for (uint32_t i = 0; i < len; i++) {
        uint8_t c = rd8(src + i);
        if (flags & LCMAP_UPPERCASE) c = (uint8_t)gp_upper1252(c);
        if (flags & LCMAP_LOWERCASE) c = (uint8_t)gp_lower1252(c);
        wr8(dst + i, c);
    }
    return len;
}
static uint32_t LCMapStringW_(gp_thread *t)
{
    uint32_t flags = A(1); gaddr src = A(2); int32_t n = (int32_t)A(3); gaddr dst = A(4); uint32_t cap = A(5);
    uint32_t len = 0;
    if (n < 0) { while (rd16(src + 2 * len)) len++; len++; } else len = (uint32_t)n;
    if (flags & ~(LCMAP_LOWERCASE | LCMAP_UPPERCASE)) gp_fatal("LCMapStringW flags 0x%x", flags);
    if (!cap) return len;
    if (cap < len) { set_error(t, ERROR_INSUFFICIENT_BUFFER); return 0; }
    for (uint32_t i = 0; i < len; i++) {
        uint16_t c = rd16(src + 2 * i);
        if (flags & LCMAP_UPPERCASE) c = gp_upperw(c);
        if (flags & LCMAP_LOWERCASE) c = gp_lowerw(c);
        wr16(dst + 2 * i, c);
    }
    return len;
}
static uint16_t ctype1(uint16_t c)
{
    uint16_t r = 0;
    if (gp_upperw(c) != c || (c >= 'a' && c <= 'z')) r |= 0x002;          /* C1_LOWER */
    if (gp_lowerw(c) != c || (c >= 'A' && c <= 'Z')) r |= 0x001;          /* C1_UPPER */
    if (c >= '0' && c <= '9') r |= 0x004;                                  /* C1_DIGIT */
    if (c == ' ' || (c >= 9 && c <= 13)) r |= 0x008;                       /* C1_SPACE */
    if (c < 0x20 || c == 0x7f) r |= 0x020;                                 /* C1_CNTRL */
    if (c == ' ' || c == 9) r |= 0x040;                                    /* C1_BLANK */
    if ((c >= '0' && c <= '9') || ((c | 0x20) >= 'a' && (c | 0x20) <= 'f')) r |= 0x080; /* C1_XDIGIT */
    if ((r & 3) || (c >= 0xc0 && c <= 0xff && c != 0xd7 && c != 0xf7)) r |= 0x100;     /* C1_ALPHA */
    if (c > 0x20 && c < 0x7f && !(r & (0x100 | 0x004))) r |= 0x010;       /* C1_PUNCT */
    return r;
}
static uint32_t GetStringTypeA_(gp_thread *t)
{
    /* (LCID, dwInfoType, lpSrcStr, cchSrc, lpCharType) */
    if (A(1) != 1) gp_fatal("GetStringTypeA info type %u", A(1));
    gaddr src = A(2); int32_t n = (int32_t)A(3); gaddr out = A(4);
    uint32_t len = n < 0 ? (uint32_t)strlen(gstr(src)) + 1 : (uint32_t)n;
    for (uint32_t i = 0; i < len; i++) wr16(out + 2 * i, ctype1(gp_cp1252_to_wc(rd8(src + i))));
    return 1;
}
static uint32_t GetStringTypeW_(gp_thread *t)
{
    if (A(0) != 1) gp_fatal("GetStringTypeW info type %u", A(0));
    gaddr src = A(1); int32_t n = (int32_t)A(2); gaddr out = A(3);
    uint32_t len = 0;
    if (n < 0) { while (rd16(src + 2 * len)) len++; len++; } else len = (uint32_t)n;
    for (uint32_t i = 0; i < len; i++) wr16(out + 2 * i, ctype1(rd16(src + 2 * i)));
    return 1;
}
static uint32_t GetUserDefaultLCID_(gp_thread *t) { (void)t; return 0x0409; }

/* -------------------------------------------------------------- modules */
static uint32_t GetModuleHandleA_(gp_thread *t)
{
    const char *n = gstr(A(0));
    if (!n) return 0x00400000u;
    gp_module *m = gp_module_by_name(n);
    if (m) return m->base;
    gaddr h = gp_native_module(n);
    if (!h) set_error(t, ERROR_MOD_NOT_FOUND);
    return h;
}
static uint32_t module_path(gaddr h, char *out, size_t cap)
{
    gp_module *m = h ? gp_module_by_address(h) : gp_module_by_name("FEAR.exe");
    if (!m || (h && m->base != h)) return 0;
    snprintf(out, cap, GUEST_GAME_DIR "\\%s", m->name);
    return (uint32_t)strlen(out);
}
static uint32_t GetModuleFileNameA_(gp_thread *t)
{
    char buf[300];
    uint32_t n = module_path(A(0), buf, sizeof buf), cap = A(2);
    if (!n) { set_error(t, ERROR_MOD_NOT_FOUND); return 0; }
    if (!cap) return 0;
    if (n >= cap) { memcpy(G(A(1)), buf, cap - 1); wr8(A(1) + cap - 1, 0); set_error(t, ERROR_INSUFFICIENT_BUFFER); return cap; }
    memcpy(G(A(1)), buf, n + 1);
    return n;
}
static uint32_t GetModuleFileNameW_(gp_thread *t)
{
    char buf[300];
    uint32_t n = module_path(A(0), buf, sizeof buf), cap = A(2);
    if (!n) { set_error(t, ERROR_MOD_NOT_FOUND); return 0; }
    if (!cap) return 0;
    uint32_t k = n < cap ? n : cap - 1;
    for (uint32_t i = 0; i < k; i++) wr16(A(1) + 2 * i, (uint8_t)buf[i]);
    wr16(A(1) + 2 * k, 0);
    if (n >= cap) { set_error(t, ERROR_INSUFFICIENT_BUFFER); return cap; }
    return n;
}
static uint32_t LoadLibraryA_(gp_thread *t)
{
    const char *n = gstr(A(0));
    gp_module *m = gp_module_by_name(n);
    if (!m) {
        /* the engine extracts game DLLs from its archives to temporary files */
        char *host = gp_path_to_host(n);
        if (host) { m = gp_module_by_file(host); free(host); }
        if (m) gp_log("LoadLibraryA(\"%s\") is %s", n, m->name);
    }
    if (m) {
        if (!gp_module_init(m, t)) { set_error(t, ERROR_DLL_INIT_FAILED); return 0; }
        return m->base;
    }
    gaddr h = gp_native_module(n);
    if (h) return h;
    gp_log("LoadLibraryA(\"%s\"): not available", n);
    set_error(t, ERROR_MOD_NOT_FOUND);
    return 0;
}
static uint32_t FreeLibrary_(gp_thread *t) { (void)t; return 1; }  /* modules stay mapped: their code is static */
static uint32_t GetProcAddress_(gp_thread *t)
{
    gaddr h = A(0), name = A(1);
    const char *sym = name < 0x10000 ? (const char *)(uintptr_t)name : gstr(name);
    gp_module *m = gp_module_by_address(h);
    gaddr r = 0;
    if (m && m->base == h) r = gp_module_export(m, sym);
    else {
        const char *dll = gp_native_module_name(h);
        if (!dll) gp_fatal("GetProcAddress on unknown module handle 0x%08x", h);
        if (name < 0x10000) gp_fatal("GetProcAddress(%s, #%u) by ordinal", dll, name);
        r = gp_native_proc(dll, sym);
    }
    if (getenv("GP_TRACE_PROCS")) gp_log("GetProcAddress(0x%08x, \"%s\") -> 0x%08x", h, name < 0x10000 ? "(ordinal)" : sym, r);
    if (!r) set_error(t, ERROR_PROC_NOT_FOUND);
    return r;
}

/* ------------------------------------------------------------ resources
   Resource handles are the guest address of the IMAGE_RESOURCE_DATA_ENTRY. */
static bool rsrc_name_matches(gaddr root, uint32_t entry_name, gaddr want)
{
    if (want < 0x10000) return !(entry_name & 0x80000000u) && (entry_name & 0xffff) == want;
    if (!(entry_name & 0x80000000u)) {
        const char *w = gstr(want);
        return w[0] == '#' && (uint32_t)strtoul(w + 1, NULL, 10) == (entry_name & 0xffff);
    }
    gaddr s = root + (entry_name & 0x7fffffffu);
    uint16_t n = rd16(s);
    const char *w = gstr(want);
    if (strlen(w) != n) return false;
    for (uint16_t i = 0; i < n; i++) if (gp_upperw(rd16(s + 2 + 2 * i)) != gp_upperw(gp_cp1252_to_wc((uint8_t)w[i]))) return false;
    return true;
}
static gaddr rsrc_find(gaddr root, gaddr dir, gaddr name, bool any)
{
    uint16_t named = rd16(dir + 12), ids = rd16(dir + 14);
    for (uint32_t i = 0; i < (uint32_t)named + ids; i++) {
        gaddr e = dir + 16 + 8 * i;
        if (any || rsrc_name_matches(root, rd32(e), name)) return rd32(e + 4);
    }
    return 0xffffffffu;
}
static uint32_t FindResourceA_(gp_thread *t)
{
    gaddr h = A(0) ? A(0) : 0x00400000u;
    gp_module *m = gp_module_by_address(h);
    if (!m || m->base != h) { set_error(t, ERROR_MOD_NOT_FOUND); return 0; }
    uint32_t pe = rd32(h + 0x3c), rva = rd32(h + pe + 0x88);
    if (!rva) { set_error(t, 1813); return 0; }            /* ERROR_RESOURCE_TYPE_NOT_FOUND */
    gaddr root = h + rva;
    uint32_t off = rsrc_find(root, root, A(2), false);       /* type */
    if (off == 0xffffffffu || !(off & 0x80000000u)) { set_error(t, 1813); return 0; }
    off = rsrc_find(root, root + (off & 0x7fffffffu), A(1), false);   /* name */
    if (off == 0xffffffffu || !(off & 0x80000000u)) { set_error(t, 1814); return 0; }
    off = rsrc_find(root, root + (off & 0x7fffffffu), 0, true);       /* first language */
    if (off == 0xffffffffu || (off & 0x80000000u)) { set_error(t, 1814); return 0; }
    return root + off;
}
static uint32_t LoadResource_(gp_thread *t)
{
    gaddr entry = A(1);
    if (!entry) { set_error(t, ERROR_INVALID_HANDLE); return 0; }
    gp_module *m = gp_module_by_address(entry);
    return m->base + rd32(entry);
}
static uint32_t LockResource_(gp_thread *t) { return A(0); }
static uint32_t SizeofResource_(gp_thread *t) { return A(1) ? rd32(A(1) + 4) : 0; }

/* ------------------------------------------------------------ misc math */
static uint32_t MulDiv_(gp_thread *t)
{
    int64_t d = (int32_t)A(2);
    if (!d) return 0xffffffffu;
    int64_t p = (int64_t)(int32_t)A(0) * (int32_t)A(1);
    int64_t q = p / d, r = p % d;
    if (2 * (r < 0 ? -r : r) >= (d < 0 ? -d : d)) q += ((p < 0) != (d < 0)) ? -1 : 1;   /* round half away from zero */
    if (q > INT32_MAX || q < INT32_MIN) return 0xffffffffu;
    return (uint32_t)(int32_t)q;
}

const gp_api gp_api_kernel32_core[] = {
    API(GetLastError_, "GetLastError", 0), API(SetLastError_, "SetLastError", 1),
    API(GetCommandLineA_, "GetCommandLineA", 0), API(GetCommandLineW_, "GetCommandLineW", 0),
    API(GetEnvironmentStrings_, "GetEnvironmentStrings", 0), API(GetEnvironmentStringsW_, "GetEnvironmentStringsW", 0),
    API(FreeEnvironmentStrings_, "FreeEnvironmentStringsA", 1), API(FreeEnvironmentStrings_, "FreeEnvironmentStringsW", 1),
    API(GetEnvironmentVariableA_, "GetEnvironmentVariableA", 3),
    API(GetWindowsDirectoryA_, "GetWindowsDirectoryA", 2), API(GetSystemDirectoryA_, "GetSystemDirectoryA", 2),
    API(GetVersion_, "GetVersion", 0), API(GetVersionExA_, "GetVersionExA", 1),
    API(GetStartupInfoA_, "GetStartupInfoA", 1),
    API(GetCurrentProcess_, "GetCurrentProcess", 0), API(GetCurrentThread_, "GetCurrentThread", 0),
    API(GetCurrentProcessId_, "GetCurrentProcessId", 0), API(GetCurrentThreadId_, "GetCurrentThreadId", 0),
    API(ExitProcess_, "ExitProcess", 1), API(TerminateProcess_, "TerminateProcess", 2),
    API(SetErrorMode_, "SetErrorMode", 1), API(SetUnhandledExceptionFilter_, "SetUnhandledExceptionFilter", 1),
    API(SetHandleCount_, "SetHandleCount", 1), API(DisableThreadLibraryCalls_, "DisableThreadLibraryCalls", 1),
    API(OutputDebugStringA_, "OutputDebugStringA", 1), API(DebugBreak_, "DebugBreak", 0),
    API(HeapCreate_, "HeapCreate", 3), API(HeapDestroy_, "HeapDestroy", 1), API(GetProcessHeap_, "GetProcessHeap", 0),
    API(HeapAlloc_, "HeapAlloc", 3), API(HeapFree_, "HeapFree", 3), API(HeapSize_, "HeapSize", 3),
    API(HeapReAlloc_, "HeapReAlloc", 4), API(HeapValidate_, "HeapValidate", 3), API(HeapCompact_, "HeapCompact", 2),
    API(VirtualAlloc_, "VirtualAlloc", 4), API(VirtualFree_, "VirtualFree", 3),
    API(VirtualProtect_, "VirtualProtect", 4), API(VirtualQuery_, "VirtualQuery", 3),
    API(IsBadReadPtr_, "IsBadReadPtr", 2), API(IsBadWritePtr_, "IsBadWritePtr", 2), API(IsBadCodePtr_, "IsBadCodePtr", 1),
    API(GlobalMemoryStatus_, "GlobalMemoryStatus", 1), API(GetSystemInfo_, "GetSystemInfo", 1),
    API(TlsAlloc_, "TlsAlloc", 0), API(TlsFree_, "TlsFree", 1), API(TlsGetValue_, "TlsGetValue", 1), API(TlsSetValue_, "TlsSetValue", 2),
    API(InitializeCriticalSection_, "InitializeCriticalSection", 1),
    API(InitializeCriticalSectionAndSpinCount_, "InitializeCriticalSectionAndSpinCount", 2),
    API(DeleteCriticalSection_, "DeleteCriticalSection", 1),
    API(EnterCriticalSection_, "EnterCriticalSection", 1), API(LeaveCriticalSection_, "LeaveCriticalSection", 1),
    API(InterlockedIncrement_, "InterlockedIncrement", 1), API(InterlockedDecrement_, "InterlockedDecrement", 1),
    API(InterlockedExchange_, "InterlockedExchange", 2),
    API(GetTickCount_, "GetTickCount", 0), API(QueryPerformanceFrequency_, "QueryPerformanceFrequency", 1),
    API(QueryPerformanceCounter_, "QueryPerformanceCounter", 1), API(GetSystemTimeAsFileTime_, "GetSystemTimeAsFileTime", 1),
    API(GetLocalTime_, "GetLocalTime", 1),
    API(FileTimeToLocalFileTime_, "FileTimeToLocalFileTime", 2), API(LocalFileTimeToFileTime_, "LocalFileTimeToFileTime", 2),
    API(FileTimeToSystemTime_, "FileTimeToSystemTime", 2), API(SystemTimeToFileTime_, "SystemTimeToFileTime", 2),
    API(GetTimeZoneInformation_, "GetTimeZoneInformation", 1), API(Sleep_, "Sleep", 1),
    API(GetACP_, "GetACP", 0), API(GetOEMCP_, "GetOEMCP", 0), API(IsValidCodePage_, "IsValidCodePage", 1),
    API(GetCPInfo_, "GetCPInfo", 2), API(IsDBCSLeadByteEx_, "IsDBCSLeadByteEx", 2),
    API(MultiByteToWideChar_, "MultiByteToWideChar", 6), API(WideCharToMultiByte_, "WideCharToMultiByte", 8),
    API(LCMapStringA_, "LCMapStringA", 6), API(LCMapStringW_, "LCMapStringW", 6),
    API(GetStringTypeA_, "GetStringTypeA", 5), API(GetStringTypeW_, "GetStringTypeW", 4),
    API(GetUserDefaultLCID_, "GetUserDefaultLCID", 0),
    API(GetModuleHandleA_, "GetModuleHandleA", 1), API(GetModuleFileNameA_, "GetModuleFileNameA", 3),
    API(GetModuleFileNameW_, "GetModuleFileNameW", 3), API(LoadLibraryA_, "LoadLibraryA", 1),
    API(FreeLibrary_, "FreeLibrary", 1), API(GetProcAddress_, "GetProcAddress", 2),
    API(MulDiv_, "MulDiv", 3),
    API(FindResourceA_, "FindResourceA", 3), API(LoadResource_, "LoadResource", 2),
    API(LockResource_, "LockResource", 1), API(SizeofResource_, "SizeofResource", 2),
    { 0 }
};
