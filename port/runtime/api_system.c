/* winmm timers, advapi32 registry, shell32 folders, ole32/oleaut32 basics. */
#include "gp_api.h"
#include "gp_win.h"
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <sys/random.h>
#include <sys/stat.h>

/* ------------------------------------------------------------------ winmm */
#undef DLL
#define DLL "winmm.dll"
static uint32_t timeGetTime_(gp_thread *t) { (void)t; return (uint32_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000); }
static uint32_t timeBeginPeriod_(gp_thread *t) { (void)t; return 0; }   /* host timers already have 1 ms resolution */
static uint32_t timeEndPeriod_(gp_thread *t) { (void)t; return 0; }


/* mmio: read-only buffered file I/O with RIFF chunk navigation. The MMIOINFO
   lives in guest memory so mmioGetInfo/mmioAdvance/mmioSetInfo can expose the
   buffer pointers directly, as winmm does.
   MMIOINFO (72 bytes): 0 dwFlags, 4 fccIOProc, 8 pIOProc, 12 wErrorRet, 16 htask, 20 cchBuffer,
   24 pchBuffer, 28 pchNext, 32 pchEndRead, 36 pchEndWrite, 40 lBufOffset, 44 lDiskOffset, ..., 68 hmmio
   MMCKINFO (20 bytes): ckid, cksize, fccType, dwDataOffset, dwFlags */
#define MMIO_MAX 64
#define MMIOERR_FILENOTFOUND 257
#define MMIOERR_OUTOFMEMORY 258
#define MMIOERR_CANNOTREAD 261
#define MMIOERR_CANNOTSEEK 263
#define MMIOERR_CHUNKNOTFOUND 265
#define MMIOERR_UNBUFFERED 266
typedef struct { int fd; gaddr info; bool own_buf; } mmio_file;
static mmio_file mmio_files[MMIO_MAX];
static pthread_mutex_t mmio_lock = PTHREAD_MUTEX_INITIALIZER;

static mmio_file *mmio_get(uint32_t h)
{
    if (h < 1 || h > MMIO_MAX || !mmio_files[h - 1].info) gp_fatal("winmm: invalid HMMIO 0x%x", h);
    return &mmio_files[h - 1];
}
/* logical file position */
static uint32_t mmio_pos(mmio_file *f)
{
    gaddr i = f->info;
    return rd32(i + 24) ? rd32(i + 40) + (rd32(i + 28) - rd32(i + 24)) : rd32(i + 44);
}
/* refill the buffer starting at pos; returns false on a read error */
static bool mmio_fill(mmio_file *f, uint32_t pos)
{
    gaddr i = f->info, buf = rd32(i + 24);
    uint32_t cap = rd32(i + 20);
    ssize_t n;
    do n = pread(f->fd, G(buf), cap, pos); while (n < 0 && errno == EINTR);
    if (n < 0) return false;
    wr32(i + 40, pos); wr32(i + 28, buf); wr32(i + 32, buf + (uint32_t)n); wr32(i + 44, pos + (uint32_t)n);
    return true;
}
static void mmio_set_pos(mmio_file *f, uint32_t pos)
{
    gaddr i = f->info, buf = rd32(i + 24);
    if (!buf) { wr32(i + 44, pos); return; }
    uint32_t start = rd32(i + 40), valid = rd32(i + 32) - buf;
    if (pos >= start && pos <= start + valid) { wr32(i + 28, buf + (pos - start)); return; }
    wr32(i + 40, pos); wr32(i + 28, buf); wr32(i + 32, buf); wr32(i + 44, pos);   /* empty buffer at pos */
}
static int32_t mmio_read(mmio_file *f, uint8_t *dst, uint32_t n)
{
    gaddr i = f->info, buf = rd32(i + 24);
    if (!buf) {
        uint32_t pos = rd32(i + 44);
        ssize_t r;
        do r = pread(f->fd, dst, n, pos); while (r < 0 && errno == EINTR);
        if (r < 0) return -1;
        wr32(i + 44, pos + (uint32_t)r);
        return (int32_t)r;
    }
    uint32_t done = 0;
    while (done < n) {
        uint32_t next = rd32(i + 28), end = rd32(i + 32);
        if (next >= end) {
            if (!mmio_fill(f, rd32(i + 40) + (end - buf))) return -1;
            if (rd32(i + 32) == rd32(i + 28)) break;             /* end of file */
            continue;
        }
        uint32_t k = end - next < n - done ? end - next : n - done;
        memcpy(dst + done, G(next), k);
        wr32(i + 28, next + k);
        done += k;
    }
    return (int32_t)done;
}

static uint32_t mmioOpenA_(gp_thread *t)
{
    const char *name = gstr(A(0));
    gaddr user = A(1);
    uint32_t flags = A(2);
    if (flags & ~(0x10000u | 0x70u)) gp_fatal("mmioOpenA: flags 0x%x (only buffered read is implemented)", flags);
    if (user && (rd32(user + 4) || rd32(user + 8))) gp_fatal("mmioOpenA: custom I/O procedures are not implemented");
    if (!name || strchr(name, '+')) gp_fatal("mmioOpenA: compound file name \"%s\"", name ? name : "(null)");
    char *host = gp_path_to_host(name);
    int fd = open(host, O_RDONLY | O_CLOEXEC);
    free(host);
    if (fd < 0) { if (user) wr32(user + 12, MMIOERR_FILENOTFOUND); return 0; }
    pthread_mutex_lock(&mmio_lock);
    int slot = -1;
    for (int k = 0; k < MMIO_MAX; k++) if (!mmio_files[k].info) { slot = k; break; }
    if (slot < 0) gp_fatal("mmioOpenA: more than %d open files", MMIO_MAX);
    mmio_file *f = &mmio_files[slot];
    gaddr info = gp_heap_alloc(72, true);
    if (!info) gp_fatal("mmioOpenA: out of guest memory");
    uint32_t cap = user ? rd32(user + 20) : 0;
    gaddr buf = user ? rd32(user + 24) : 0;
    f->own_buf = false;
    if ((flags & 0x10000u) || buf) {
        if (!cap) cap = 8192;
        if (!buf) {
            if (!(buf = gp_heap_alloc(cap, false))) gp_fatal("mmioOpenA: out of guest memory");
            f->own_buf = true;
        }
        wr32(info, 0x10000u); wr32(info + 20, cap); wr32(info + 24, buf);
        wr32(info + 28, buf); wr32(info + 32, buf);
    }
    wr32(info + 68, (uint32_t)slot + 1);
    f->fd = fd; f->info = info;
    pthread_mutex_unlock(&mmio_lock);
    return (uint32_t)slot + 1;
}
static uint32_t mmioClose_(gp_thread *t)
{
    pthread_mutex_lock(&mmio_lock);
    mmio_file *f = mmio_get(A(0));
    close(f->fd);
    if (f->own_buf) gp_heap_free(rd32(f->info + 24));
    gp_heap_free(f->info);
    *f = (mmio_file){0};
    pthread_mutex_unlock(&mmio_lock);
    return 0;
}
static uint32_t mmioRead_(gp_thread *t)
{
    mmio_file *f = mmio_get(A(0));
    int32_t n = (int32_t)A(2);
    if (n < 0) return 0xffffffffu;
    return (uint32_t)mmio_read(f, n ? G(A(1)) : NULL, (uint32_t)n);
}
static uint32_t mmioSeek_(gp_thread *t)
{
    mmio_file *f = mmio_get(A(0));
    int64_t off = (int32_t)A(1), base;
    switch (A(2)) {
    case 0: base = 0; break;
    case 1: base = mmio_pos(f); break;
    case 2: { struct stat st; if (fstat(f->fd, &st) != 0) return 0xffffffffu; base = st.st_size; break; }
    default: return 0xffffffffu;
    }
    int64_t pos = base + off;
    if (pos < 0 || pos > 0x7fffffff) return 0xffffffffu;
    mmio_set_pos(f, (uint32_t)pos);
    return (uint32_t)pos;
}
static uint32_t mmioGetInfo_(gp_thread *t) { mmio_file *f = mmio_get(A(0)); memcpy(G(A(1)), G(f->info), 72); return 0; }
static uint32_t mmioSetInfo_(gp_thread *t)
{
    mmio_file *f = mmio_get(A(0));
    gaddr in = A(1);
    wr32(f->info + 28, rd32(in + 28));                             /* the caller advanced pchNext */
    return 0;
}
static uint32_t mmioAdvance_(gp_thread *t)
{
    mmio_file *f = mmio_get(A(0));
    gaddr in = A(1), i = f->info;
    if (A(2) != 0) gp_fatal("mmioAdvance: write mode is not implemented");
    if (!rd32(i + 24)) return MMIOERR_UNBUFFERED;
    if (in) wr32(i + 28, rd32(in + 28));
    if (!mmio_fill(f, rd32(i + 40) + (rd32(i + 32) - rd32(i + 24)))) return MMIOERR_CANNOTREAD;
    if (in) memcpy(G(in), G(i), 72);
    return 0;
}
static bool mmio_read_u32(mmio_file *f, uint32_t *v) { uint8_t b[4]; if (mmio_read(f, b, 4) != 4) return false; memcpy(v, b, 4); return true; }

static uint32_t mmioDescend_(gp_thread *t)
{
    mmio_file *f = mmio_get(A(0));
    gaddr ck = A(1), parent = A(2);
    uint32_t flags = A(3);
    uint32_t want_id = rd32(ck), want_type = rd32(ck + 8);
    const uint32_t RIFF = 0x46464952u, LIST = 0x5453494cu;
    uint32_t limit = parent ? rd32(parent + 12) + rd32(parent + 4) : 0xffffffffu;
    for (;;) {
        uint32_t at = mmio_pos(f), id, size, type = 0;
        if (at + 8 > limit || !mmio_read_u32(f, &id) || !mmio_read_u32(f, &size)) return MMIOERR_CHUNKNOTFOUND;
        bool form = id == RIFF || id == LIST;
        if (form && !mmio_read_u32(f, &type)) return MMIOERR_CHUNKNOTFOUND;
        bool match = !(flags & 0x70) ||
                     ((flags & 0x10) && id == want_id) ||
                     ((flags & 0x20) && id == RIFF && type == want_type) ||
                     ((flags & 0x40) && id == LIST && type == want_type);
        if (match) {
            wr32(ck, id); wr32(ck + 4, size); wr32(ck + 8, type); wr32(ck + 12, at + 8); wr32(ck + 16, 0);
            return 0;
        }
        uint64_t next = (uint64_t)at + 8 + size + (size & 1);
        if (next > 0x7fffffff) return MMIOERR_CHUNKNOTFOUND;
        mmio_set_pos(f, (uint32_t)next);
    }
}
static uint32_t mmioAscend_(gp_thread *t)
{
    mmio_file *f = mmio_get(A(0));
    gaddr ck = A(1);
    uint32_t size = rd32(ck + 4);
    uint64_t end = (uint64_t)rd32(ck + 12) + size + (size & 1);
    if (end > 0x7fffffff) return MMIOERR_CANNOTSEEK;
    mmio_set_pos(f, (uint32_t)end);
    return 0;
}

const gp_api gp_api_winmm[] = {
    API(mmioOpenA_, "mmioOpenA", 3), API(mmioClose_, "mmioClose", 2), API(mmioRead_, "mmioRead", 3),
    API(mmioSeek_, "mmioSeek", 3), API(mmioGetInfo_, "mmioGetInfo", 3), API(mmioSetInfo_, "mmioSetInfo", 3),
    API(mmioAdvance_, "mmioAdvance", 3), API(mmioDescend_, "mmioDescend", 4), API(mmioAscend_, "mmioAscend", 3),
    API(timeGetTime_, "timeGetTime", 0), API(timeBeginPeriod_, "timeBeginPeriod", 1), API(timeEndPeriod_, "timeEndPeriod", 1),
    { 0 }
};

/* --------------------------------------------------------------- registry
   A per-user registry stored as text next to the saves. Keys are
   case-insensitive paths such as "HKEY_LOCAL_MACHINE\Software\...". */
#undef DLL
#define DLL "advapi32.dll"

typedef struct { char *key, *name; uint32_t type, size; uint8_t *data; } reg_value;
static reg_value *values;
static size_t nvalues;
static char **keys;
static size_t nkeys;
static pthread_mutex_t reg_lock = PTHREAD_MUTEX_INITIALIZER;
static char reg_file[1200];

#define MAX_OPEN 256
static char *open_keys[MAX_OPEN];

static const char *root_name(uint32_t h)
{
    switch (h) {
    case 0x80000000u: return "HKEY_CLASSES_ROOT";
    case 0x80000001u: return "HKEY_CURRENT_USER";
    case 0x80000002u: return "HKEY_LOCAL_MACHINE";
    case 0x80000003u: return "HKEY_USERS";
    }
    return NULL;
}

static bool key_exists(const char *k)
{
    for (size_t i = 0; i < nkeys; i++) if (!strcasecmp(keys[i], k)) return true;
    return false;
}

static void add_key(const char *k)
{
    /* create every ancestor too */
    char buf[1024];
    snprintf(buf, sizeof buf, "%s", k);
    for (char *p = buf;; p++) {
        if (*p == '\\' || !*p) {
            char c = *p; *p = 0;
            if (!key_exists(buf)) {
                keys = realloc(keys, sizeof *keys * (nkeys + 1));
                keys[nkeys++] = strdup(buf);
            }
            *p = c;
            if (!c) break;
        }
    }
}

static void reg_save(void)
{
    char tmp[1300];
    snprintf(tmp, sizeof tmp, "%s.tmp", reg_file);
    FILE *f = fopen(tmp, "w");
    if (!f) gp_fatal("cannot write registry file %s", tmp);
    for (size_t i = 0; i < nkeys; i++) fprintf(f, "K\t%s\n", keys[i]);
    for (size_t i = 0; i < nvalues; i++) {
        fprintf(f, "V\t%s\t%s\t%u\t", values[i].key, values[i].name, values[i].type);
        for (uint32_t j = 0; j < values[i].size; j++) fprintf(f, "%02x", values[i].data[j]);
        fputc('\n', f);
    }
    if (fclose(f) || rename(tmp, reg_file)) gp_fatal("cannot save registry file %s", reg_file);
}

static void reg_load(void)
{
    if (reg_file[0]) return;
    char *host = gp_path_to_host(GUEST_USER_DIR "\\registry.txt");
    snprintf(reg_file, sizeof reg_file, "%s", host);
    free(host);
    FILE *f = fopen(reg_file, "r");
    if (!f) return;
    char line[70000];
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\n")] = 0;
        char *fields[5] = {0}; int n = 0;
        for (char *p = line, *s; n < 5 && (s = strsep(&p, "\t"));) fields[n++] = s;
        if (n == 2 && !strcmp(fields[0], "K")) add_key(fields[1]);
        else if (n == 5 && !strcmp(fields[0], "V")) {
            size_t len = strlen(fields[4]) / 2;
            uint8_t *d = malloc(len ? len : 1);
            for (size_t i = 0; i < len; i++) { unsigned b; sscanf(fields[4] + 2 * i, "%2x", &b); d[i] = (uint8_t)b; }
            values = realloc(values, sizeof *values * (nvalues + 1));
            values[nvalues++] = (reg_value){ strdup(fields[1]), strdup(fields[2]), (uint32_t)strtoul(fields[3], 0, 10), (uint32_t)len, d };
        }
    }
    fclose(f);
}

static char *key_path(uint32_t h, const char *sub)
{
    const char *base = root_name(h);
    if (!base) {
        if (h < 0x100 || h - 0x100 >= MAX_OPEN || !open_keys[h - 0x100]) return NULL;
        base = open_keys[h - 0x100];
    }
    char buf[1024];
    if (sub && *sub) snprintf(buf, sizeof buf, "%s\\%s", base, sub);
    else snprintf(buf, sizeof buf, "%s", base);
    size_t n = strlen(buf);
    while (n && buf[n - 1] == '\\') buf[--n] = 0;
    return strdup(buf);
}

static uint32_t open_handle(char *path)
{
    for (uint32_t i = 0; i < MAX_OPEN; i++)
        if (!open_keys[i]) { open_keys[i] = path; return 0x100 + i; }
    gp_fatal("too many open registry keys");
}

static uint32_t RegOpenKeyExA_(gp_thread *t)
{
    pthread_mutex_lock(&reg_lock);
    reg_load();
    char *p = key_path(A(0), gstr(A(1)));
    uint32_t r = 0;
    if (!p) r = ERROR_INVALID_HANDLE;
    else if (!key_exists(p) && strchr(p, '\\')) { free(p); r = ERROR_FILE_NOT_FOUND; }
    else wr32(A(4), open_handle(p));
    pthread_mutex_unlock(&reg_lock);
    return r;
}
static uint32_t RegCreateKeyExA_(gp_thread *t)
{
    /* (hKey, lpSubKey, Reserved, lpClass, dwOptions, samDesired, lpSecurityAttributes, phkResult, lpdwDisposition) */
    pthread_mutex_lock(&reg_lock);
    reg_load();
    char *p = key_path(A(0), gstr(A(1)));
    if (!p) { pthread_mutex_unlock(&reg_lock); return ERROR_INVALID_HANDLE; }
    bool existed = key_exists(p);
    if (!existed) { add_key(p); reg_save(); }
    wr32(A(7), open_handle(p));
    if (A(8)) wr32(A(8), existed ? 2 : 1);   /* REG_OPENED_EXISTING_KEY / REG_CREATED_NEW_KEY */
    pthread_mutex_unlock(&reg_lock);
    return 0;
}
static uint32_t RegCloseKey_(gp_thread *t)
{
    uint32_t h = A(0);
    if (root_name(h)) return 0;
    if (h < 0x100 || h - 0x100 >= MAX_OPEN || !open_keys[h - 0x100]) return ERROR_INVALID_HANDLE;
    pthread_mutex_lock(&reg_lock);
    free(open_keys[h - 0x100]); open_keys[h - 0x100] = NULL;
    pthread_mutex_unlock(&reg_lock);
    return 0;
}
static reg_value *find_value(const char *key, const char *name)
{
    for (size_t i = 0; i < nvalues; i++)
        if (!strcasecmp(values[i].key, key) && !strcasecmp(values[i].name, name ? name : "")) return &values[i];
    return NULL;
}
static uint32_t RegQueryValueExA_(gp_thread *t)
{
    /* (hKey, lpValueName, lpReserved, lpType, lpData, lpcbData) */
    pthread_mutex_lock(&reg_lock);
    char *k = key_path(A(0), NULL);
    uint32_t r = 0;
    reg_value *v = k ? find_value(k, gstr(A(1))) : NULL;
    if (!k) r = ERROR_INVALID_HANDLE;
    else if (!v) {
        r = ERROR_FILE_NOT_FOUND;
        gp_log("registry: %s\\%s not present", k, gstr(A(1)) ? gstr(A(1)) : "(default)");
    } else {
        if (A(3)) wr32(A(3), v->type);
        if (A(5)) {
            uint32_t cap = rd32(A(5));
            if (A(4) && cap < v->size) r = 234;                     /* ERROR_MORE_DATA */
            else if (A(4)) memcpy(G(A(4)), v->data, v->size);
            wr32(A(5), v->size);
        }
    }
    free(k);
    pthread_mutex_unlock(&reg_lock);
    return r;
}
static uint32_t RegSetValueExA_(gp_thread *t)
{
    /* (hKey, lpValueName, Reserved, dwType, lpData, cbData) */
    pthread_mutex_lock(&reg_lock);
    char *k = key_path(A(0), NULL);
    if (!k) { pthread_mutex_unlock(&reg_lock); return ERROR_INVALID_HANDLE; }
    const char *name = gstr(A(1)) ? gstr(A(1)) : "";
    reg_value *v = find_value(k, name);
    if (!v) {
        values = realloc(values, sizeof *values * (nvalues + 1));
        v = &values[nvalues++];
        *v = (reg_value){ strdup(k), strdup(name), 0, 0, NULL };
    }
    free(v->data);
    v->type = A(3); v->size = A(5);
    v->data = malloc(v->size ? v->size : 1);
    memcpy(v->data, G(A(4)), v->size);
    reg_save();
    free(k);
    pthread_mutex_unlock(&reg_lock);
    return 0;
}

const gp_api gp_api_advapi32[] = {
    API(RegOpenKeyExA_, "RegOpenKeyExA", 5), API(RegCreateKeyExA_, "RegCreateKeyExA", 9),
    API(RegCloseKey_, "RegCloseKey", 1), API(RegQueryValueExA_, "RegQueryValueExA", 6),
    API(RegSetValueExA_, "RegSetValueExA", 6),
    { 0 }
};

/* ---------------------------------------------------------------- shell32 */
#undef DLL
#define DLL "shell32.dll"
static uint32_t SHGetFolderPathA_(gp_thread *t)
{
    /* (hwnd, csidl, hToken, dwFlags, pszPath): every per-user and shared data
       folder maps into the user data folder, so saves stay with the player. */
    const char *sub;
    switch (A(1) & 0xff) {
    case 0x05: sub = "My Documents"; break;           /* CSIDL_PERSONAL */
    case 0x1a: sub = "Application Data"; break;       /* CSIDL_APPDATA */
    case 0x1c: sub = "Local Settings"; break;         /* CSIDL_LOCAL_APPDATA */
    case 0x23: sub = "All Users"; break;              /* CSIDL_COMMON_APPDATA */
    case 0x2e: sub = "Shared Documents"; break;       /* CSIDL_COMMON_DOCUMENTS */
    default: gp_fatal("SHGetFolderPathA CSIDL 0x%x", A(1));
    }
    char g[260];
    snprintf(g, sizeof g, GUEST_USER_DIR "\\%s", sub);
    if (A(1) & 0x8000) {                               /* CSIDL_FLAG_CREATE */
        char *h = gp_path_to_host(g);
        mkdir(h, 0755);
        free(h);
    }
    snprintf((char *)G(A(4)), 260, "%s", g);
    return 0;
}

const gp_api gp_api_shell32[] = { API(SHGetFolderPathA_, "SHGetFolderPathA", 5), { 0 } };

/* ------------------------------------------------------------- ole32 */
#undef DLL
#define DLL "ole32.dll"
static uint32_t CoInitialize_(gp_thread *t) { (void)t; return 0; }
static uint32_t CoUninitialize_(gp_thread *t) { (void)t; return 0; }
static uint32_t CoCreateGuid_(gp_thread *t)
{
    uint8_t g[16];
    if (getentropy(g, sizeof g)) gp_fatal("getentropy failed");
    g[7] = (g[7] & 0x0f) | 0x40;       /* version 4 */
    g[8] = (g[8] & 0x3f) | 0x80;
    memcpy(G(A(0)), g, 16);
    return 0;
}

static uint32_t CoCreateInstance_(gp_thread *t)
{
    /* (rclsid, pUnkOuter, dwClsContext, riid, ppv): no COM classes are registered in this process */
    gaddr c = A(0);
    gp_log("CoCreateInstance {%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}: class not registered",
           rd32(c), rd16(c + 4), rd16(c + 6), rd8(c + 8), rd8(c + 9), rd8(c + 10), rd8(c + 11), rd8(c + 12), rd8(c + 13), rd8(c + 14), rd8(c + 15));
    if (A(4)) wr32(A(4), 0);
    return 0x80040154u;   /* REGDB_E_CLASSNOTREG */
}

const gp_api gp_api_ole32[] = {
    API(CoCreateInstance_, "CoCreateInstance", 5),
    API(CoInitialize_, "CoInitialize", 1), API(CoUninitialize_, "CoUninitialize", 0), API(CoCreateGuid_, "CoCreateGuid", 1),
    { 0 }
};

/* ------------------------------------------------------------- oleaut32 */
#undef DLL
#define DLL "oleaut32.dll"
static uint32_t VariantInit_(gp_thread *t) { memset(G(A(0)), 0, 16); return 0; }
static uint32_t VariantClear_(gp_thread *t)
{
    uint16_t vt = rd16(A(0));
    if (vt > 3 && vt != 11 && vt != 19)                     /* only scalar variants carry no ownership */
        gp_fatal("VariantClear of variant type %u", vt);
    memset(G(A(0)), 0, 16);
    return 0;
}
const gp_api gp_api_oleaut32[] = { API(VariantInit_, "#8", 1), API(VariantClear_, "#9", 1), { 0 } };
