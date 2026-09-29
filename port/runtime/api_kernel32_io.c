/* kernel32.dll: handles, files, directories, paths, find, synchronisation objects, threads. */
#include "gp_api.h"
#include "gp_win.h"
#include "gp_handles.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define DLL "kernel32.dll"

/* ---------------------------------------------------------------- handles */
#define MAX_HANDLES 4096
#define HANDLE_BASE 0x100u
static gp_handle table[MAX_HANDLES];
static pthread_mutex_t table_lock = PTHREAD_MUTEX_INITIALIZER;

uint32_t gp_handle_new(gp_handle h)
{
    pthread_mutex_lock(&table_lock);
    for (uint32_t i = 0; i < MAX_HANDLES; i++)
        if (table[i].type == H_NONE) {
            table[i] = h;
            pthread_mutex_unlock(&table_lock);
            return HANDLE_BASE + 4 * i;
        }
    pthread_mutex_unlock(&table_lock);
    gp_fatal("handle table full");
}

gp_handle *gp_handle_get(uint32_t h, int type)
{
    if (h < HANDLE_BASE || (h - HANDLE_BASE) % 4 || (h - HANDLE_BASE) / 4 >= MAX_HANDLES) return NULL;
    gp_handle *e = &table[(h - HANDLE_BASE) / 4];
    if (e->type == H_NONE || (type != H_NONE && e->type != type)) return NULL;
    return e;
}

gp_sync *gp_sync_new(void)
{
    gp_sync *s = calloc(1, sizeof *s);
    if (!s) gp_fatal("out of host memory");
    pthread_mutex_init(&s->lock, NULL);
    pthread_cond_init(&s->cond, NULL);
    s->refs = 1;
    return s;
}

static void sync_release(gp_sync *s)
{
    pthread_mutex_lock(&s->lock);
    int r = --s->refs;
    pthread_mutex_unlock(&s->lock);
    if (!r) { pthread_mutex_destroy(&s->lock); pthread_cond_destroy(&s->cond); free(s); }
}

bool gp_handle_close(uint32_t h)
{
    pthread_mutex_lock(&table_lock);
    gp_handle *e = gp_handle_get(h, H_NONE);
    if (!e) { pthread_mutex_unlock(&table_lock); return false; }
    gp_handle copy = *e;
    memset(e, 0, sizeof *e);
    pthread_mutex_unlock(&table_lock);
    if (copy.type == H_FILE && copy.fd >= 0) close(copy.fd);
    if (copy.dir) closedir(copy.dir);
    free(copy.path); free(copy.pattern);
    if (copy.sync) sync_release(copy.sync);
    return true;
}

static uint32_t std_handles[3];
static uint32_t GetStdHandle_(gp_thread *t)
{
    int32_t which = (int32_t)A(0);
    if (which > -10 || which < -12) { set_error(t, ERROR_INVALID_HANDLE); return 0xffffffffu; }
    int i = -10 - which;                         /* -10 in, -11 out, -12 err */
    if (!std_handles[i]) std_handles[i] = gp_handle_new((gp_handle){ .type = H_STD, .fd = i });
    return std_handles[i];
}
static uint32_t SetStdHandle_(gp_thread *t)
{
    int32_t which = (int32_t)A(0);
    if (which > -10 || which < -12) { set_error(t, ERROR_INVALID_HANDLE); return 0; }
    std_handles[-10 - which] = A(1);
    return 1;
}
static uint32_t GetFileType_(gp_thread *t)
{
    gp_handle *h = gp_handle_get(A(0), H_NONE);
    if (!h) { set_error(t, ERROR_INVALID_HANDLE); return 0; }
    if (h->type == H_STD) return 2;              /* FILE_TYPE_CHAR */
    if (h->type == H_FILE) return 1;             /* FILE_TYPE_DISK */
    return 0;
}
static uint32_t CloseHandle_(gp_thread *t)
{
    uint32_t h = A(0);
    if (h == 0xffffffffu || h == 0xfffffffeu) return 1;   /* pseudo handles */
    if (gp_handle_close(h)) return 1;
    set_error(t, ERROR_INVALID_HANDLE);
    return 0;
}

/* ---------------------------------------------------------------- paths
   Guest paths: "C:\FEAR\..." is the game folder, "C:\FEARUSER\..." the user
   data folder, relative paths start at the current directory. Components are
   matched case-insensitively like NTFS. */
static char user_dir[PATH_MAX];

static const char *user_root(void)
{
    if (!user_dir[0]) {
        const char *e = getenv("GP_USER_DIR");
        if (e) snprintf(user_dir, sizeof user_dir, "%s", e);
        else snprintf(user_dir, sizeof user_dir, "%s/Library/Application Support/FEAR", getenv("HOME"));
        char tmp[PATH_MAX];
        snprintf(tmp, sizeof tmp, "%s", user_dir);
        for (char *p = tmp + 1; *p; p++) if (*p == '/') { *p = 0; mkdir(tmp, 0755); *p = '/'; }
        mkdir(tmp, 0755);
    }
    return user_dir;
}

/* First run: the game starts at 1920x1080. settings.cfg is the game's own settings file (quoted name/value pairs); it
   rewrites the file whenever the player changes options, so an existing file is never touched. */
void gp_seed_default_settings(void)
{
    char dir[PATH_MAX], path[PATH_MAX];
    snprintf(dir, sizeof dir, "%s/Shared Documents/Monolith Productions/FEAR", user_root());
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof tmp, "%s", dir);
    for (char *p = tmp + 1; *p; p++) if (*p == '/') { *p = 0; mkdir(tmp, 0755); *p = '/'; }
    mkdir(tmp, 0755);
    snprintf(path, sizeof path, "%s/settings.cfg", dir);
    if (access(path, F_OK) == 0) return;
    FILE *f = fopen(path, "w");
    if (!f) gp_fatal("cannot write %s: %s", path, strerror(errno));
    fputs("\"BitDepth\" \"32\"\n\"ScreenWidth\" \"1920\"\n\"ScreenHeight\" \"1080\"\n", f);
    if (fclose(f)) gp_fatal("cannot write %s: %s", path, strerror(errno));
}

const char *gp_user_root(void) { return user_root(); }

/* append one component, matching an existing entry case-insensitively */
static void append_component(char *out, size_t cap, const char *comp, size_t n)
{
    size_t len = strlen(out);
    if (n == 1 && comp[0] == '.') return;
    if (n == 2 && comp[0] == '.' && comp[1] == '.') {
        char *s = strrchr(out, '/');
        if (s && s != out) *s = 0;
        return;
    }
    char name[NAME_MAX + 1];
    if (n > NAME_MAX) n = NAME_MAX;
    memcpy(name, comp, n); name[n] = 0;
    DIR *d = opendir(len ? out : "/");
    if (d) {
        struct dirent *e;
        while ((e = readdir(d)))
            if (!strcasecmp(e->d_name, name)) { snprintf(name, sizeof name, "%s", e->d_name); break; }
        closedir(d);
    }
    snprintf(out + len, cap - len, "/%s", name);
}

char *gp_path_to_host(const char *guest)
{
    char out[PATH_MAX];
    const char *p = guest;
    if (((p[0] | 0x20) >= 'a' && (p[0] | 0x20) <= 'z') && p[1] == ':') {
        p += 2;
        while (*p == '\\' || *p == '/') p++;
        size_t gl = strlen(GUEST_USER_DIR) - 3, fl = strlen(GUEST_GAME_DIR) - 3;
        if (!strncasecmp(p, &GUEST_USER_DIR[3], gl) && (p[gl] == 0 || p[gl] == '\\' || p[gl] == '/')) {
            snprintf(out, sizeof out, "%s", user_root()); p += gl;
        } else if (!strncasecmp(p, &GUEST_GAME_DIR[3], fl) && (p[fl] == 0 || p[fl] == '\\' || p[fl] == '/')) {
            snprintf(out, sizeof out, "%s", gp_game_dir); p += fl;
        } else {
            return NULL;                                   /* other Windows locations do not exist here */
        }
    } else if (*p == '\\' || *p == '/') {
        return NULL;
    } else {
        if (!getcwd(out, sizeof out)) return NULL;
    }
    while (*p) {
        while (*p == '\\' || *p == '/') p++;
        const char *s = p;
        while (*p && *p != '\\' && *p != '/') p++;
        if (p > s) append_component(out, sizeof out, s, (size_t)(p - s));
    }
    return strdup(out);
}

/* host path back to the guest view (for GetCurrentDirectory / GetFullPathName) */
static void host_to_guest(const char *host, char *out, size_t cap)
{
    size_t gl = strlen(gp_game_dir), ul = strlen(user_root());
    const char *rest; const char *root;
    if (!strncmp(host, gp_game_dir, gl) && (host[gl] == 0 || host[gl] == '/')) { root = GUEST_GAME_DIR; rest = host + gl; }
    else if (!strncmp(host, user_dir, ul) && (host[ul] == 0 || host[ul] == '/')) { root = GUEST_USER_DIR; rest = host + ul; }
    else gp_fatal("host path %s is outside the guest view", host);
    snprintf(out, cap, "%s%s", root, rest);
    for (char *c = out; *c; c++) if (*c == '/') *c = '\\';
}

static uint32_t errno_to_win(int e)
{
    switch (e) {
    case ENOENT: return ERROR_FILE_NOT_FOUND;
    case ENOTDIR: return ERROR_PATH_NOT_FOUND;
    case EACCES: case EPERM: case EISDIR: return ERROR_ACCESS_DENIED;
    case EEXIST: return ERROR_FILE_EXISTS;
    case EMFILE: case ENFILE: return ERROR_TOO_MANY_OPEN_FILES;
    default: return ERROR_ACCESS_DENIED;
    }
}

static char *wide_to_utf8_guest(gaddr w)
{
    size_t n = 0;
    while (rd16(w + 2 * (uint32_t)n)) n++;
    char *s = malloc(n + 1);
    if (!s) gp_fatal("out of host memory");
    for (size_t i = 0; i < n; i++) {
        int c = gp_wc_to_cp1252(rd16(w + 2 * (uint32_t)i));
        s[i] = (char)(c < 0 ? '?' : c);
    }
    s[n] = 0;
    return s;
}

/* ---------------------------------------------------------------- files */
#define GENERIC_READ 0x80000000u
#define GENERIC_WRITE 0x40000000u

static uint32_t create_file(gp_thread *t, const char *guest, uint32_t access, uint32_t disposition)
{
    char *host = gp_path_to_host(guest);
    if (!host) { set_error(t, ERROR_PATH_NOT_FOUND); return 0xffffffffu; }
    int flags = (access & GENERIC_WRITE) ? ((access & GENERIC_READ) ? O_RDWR : O_WRONLY) : O_RDONLY;
    struct stat st;
    bool exists = stat(host, &st) == 0;
    if (exists && S_ISDIR(st.st_mode)) { free(host); set_error(t, ERROR_ACCESS_DENIED); return 0xffffffffu; }
    switch (disposition) {
    case 1: flags |= O_CREAT | O_EXCL; break;             /* CREATE_NEW */
    case 2: flags |= O_CREAT | O_TRUNC; break;            /* CREATE_ALWAYS */
    case 3: break;                                        /* OPEN_EXISTING */
    case 4: flags |= O_CREAT; break;                      /* OPEN_ALWAYS */
    case 5: flags |= O_TRUNC; break;                      /* TRUNCATE_EXISTING */
    default: free(host); set_error(t, ERROR_INVALID_PARAMETER); return 0xffffffffu;
    }
    int fd = open(host, flags | O_CLOEXEC, 0644);
    if (fd < 0) {
        static int tr = -1;
        if (tr < 0) tr = getenv("GP_TRACE_FILES") != NULL;
        if (tr) gp_log("CreateFile(\"%s\") failed: %s", guest, strerror(errno));
        set_error(t, errno_to_win(errno)); free(host); return 0xffffffffu;
    }
    if (getenv("GP_TRACE_FILES") && strcmp(getenv("GP_TRACE_FILES"), "2") == 0) gp_log("CreateFile(\"%s\") opened", guest);
    set_error(t, (exists && (disposition == 2 || disposition == 4)) ? ERROR_ALREADY_EXISTS : 0);
    return gp_handle_new((gp_handle){ .type = H_FILE, .fd = fd, .path = host });
}
static uint32_t CreateFileA_(gp_thread *t) { return create_file(t, gstr(A(0)), A(1), A(4)); }
static uint32_t CreateFileW_(gp_thread *t)
{
    char *p = wide_to_utf8_guest(A(0));
    uint32_t r = create_file(t, p, A(1), A(4));
    free(p);
    return r;
}

static int handle_fd(gp_thread *t, uint32_t h)
{
    gp_handle *e = gp_handle_get(h, H_NONE);
    if (e && e->type == H_FILE) return e->fd;
    if (e && e->type == H_STD) return e->fd;
    set_error(t, ERROR_INVALID_HANDLE);
    return -1;
}

static uint32_t ReadFile_(gp_thread *t)
{
    int fd = handle_fd(t, A(0));
    if (A(3)) wr32(A(3), 0);
    if (fd < 0) return 0;
    if (A(4)) gp_fatal("ReadFile with OVERLAPPED");
    uint32_t want = A(2), got = 0;
    while (got < want) {
        ssize_t n = read(fd, G(A(1) + got), want - got);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { set_error(t, errno_to_win(errno)); return 0; }
        if (n == 0) break;
        got += (uint32_t)n;
    }
    if (A(3)) wr32(A(3), got);
    return 1;
}
static uint32_t WriteFile_(gp_thread *t)
{
    int fd = handle_fd(t, A(0));
    if (A(3)) wr32(A(3), 0);
    if (fd < 0) return 0;
    if (A(4)) gp_fatal("WriteFile with OVERLAPPED");
    uint32_t want = A(2), done = 0;
    while (done < want) {
        ssize_t n = write(fd, G(A(1) + done), want - done);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { set_error(t, errno_to_win(errno)); return 0; }
        done += (uint32_t)n;
    }
    if (A(3)) wr32(A(3), done);
    return 1;
}
static uint32_t SetFilePointer_(gp_thread *t)
{
    int fd = handle_fd(t, A(0));
    if (fd < 0) return 0xffffffffu;
    int64_t off = (int32_t)A(1);
    if (A(2)) off = (int64_t)(((uint64_t)rd32(A(2)) << 32) | A(1));
    off_t r = lseek(fd, off, A(3) == 0 ? SEEK_SET : A(3) == 1 ? SEEK_CUR : SEEK_END);
    if (r < 0) { set_error(t, ERROR_INVALID_PARAMETER); return 0xffffffffu; }
    if (A(2)) wr32(A(2), (uint32_t)((uint64_t)r >> 32));
    set_error(t, 0);
    return (uint32_t)r;
}
static uint32_t SetFilePointerEx_(gp_thread *t)
{
    int fd = handle_fd(t, A(0));
    if (fd < 0) return 0;
    int64_t off = (int64_t)(((uint64_t)A(2) << 32) | A(1));
    off_t r = lseek(fd, off, A(4) == 0 ? SEEK_SET : A(4) == 1 ? SEEK_CUR : SEEK_END);
    if (r < 0) { set_error(t, ERROR_INVALID_PARAMETER); return 0; }
    if (A(3)) { wr32(A(3), (uint32_t)r); wr32(A(3) + 4, (uint32_t)((uint64_t)r >> 32)); }
    return 1;
}
static uint32_t GetFileSizeEx_(gp_thread *t)
{
    int fd = handle_fd(t, A(0));
    struct stat st;
    if (fd < 0 || fstat(fd, &st)) return 0;
    wr32(A(1), (uint32_t)st.st_size); wr32(A(1) + 4, (uint32_t)((uint64_t)st.st_size >> 32));
    return 1;
}
static uint32_t SetEndOfFile_(gp_thread *t)
{
    int fd = handle_fd(t, A(0));
    if (fd < 0) return 0;
    off_t pos = lseek(fd, 0, SEEK_CUR);
    if (ftruncate(fd, pos)) { set_error(t, errno_to_win(errno)); return 0; }
    return 1;
}
static uint32_t FlushFileBuffers_(gp_thread *t)
{
    int fd = handle_fd(t, A(0));
    if (fd < 0) return 0;
    if (fd > 2) fsync(fd);
    return 1;
}

static uint64_t to_filetime(struct timespec ts) { return ((uint64_t)ts.tv_sec + 11644473600ull) * 10000000ull + (uint64_t)ts.tv_nsec / 100; }
static void wr64(gaddr a, uint64_t v) { wr32(a, (uint32_t)v); wr32(a + 4, (uint32_t)(v >> 32)); }
static uint32_t attributes(const struct stat *st) { return S_ISDIR(st->st_mode) ? 0x10 : 0x80; }  /* DIRECTORY / NORMAL */

static uint32_t GetFileInformationByHandle_(gp_thread *t)
{
    int fd = handle_fd(t, A(0));
    struct stat st;
    if (fd < 0 || fstat(fd, &st)) return 0;
    gaddr p = A(1);
    memset(G(p), 0, 52);
    wr32(p, attributes(&st));
    wr64(p + 4, to_filetime(st.st_birthtimespec)); wr64(p + 12, to_filetime(st.st_atimespec)); wr64(p + 20, to_filetime(st.st_mtimespec));
    wr32(p + 28, (uint32_t)st.st_dev);
    wr32(p + 32, (uint32_t)((uint64_t)st.st_size >> 32)); wr32(p + 36, (uint32_t)st.st_size);
    wr32(p + 40, (uint32_t)st.st_nlink);
    wr32(p + 44, (uint32_t)(st.st_ino >> 32)); wr32(p + 48, (uint32_t)st.st_ino);
    return 1;
}

static uint32_t file_attributes(gp_thread *t, const char *guest)
{
    char *host = gp_path_to_host(guest);
    struct stat st;
    if (!host || stat(host, &st)) { set_error(t, host ? errno_to_win(errno) : ERROR_PATH_NOT_FOUND); free(host); return 0xffffffffu; }
    free(host);
    return attributes(&st);
}
static uint32_t GetFileAttributesA_(gp_thread *t) { return file_attributes(t, gstr(A(0))); }
static uint32_t GetFileAttributesW_(gp_thread *t) { char *p = wide_to_utf8_guest(A(0)); uint32_t r = file_attributes(t, p); free(p); return r; }
static uint32_t GetFileAttributesExA_(gp_thread *t)
{
    if (A(1)) gp_fatal("GetFileAttributesExA info level %u", A(1));
    char *host = gp_path_to_host(gstr(A(0)));
    struct stat st;
    if (!host || stat(host, &st)) { set_error(t, host ? errno_to_win(errno) : ERROR_PATH_NOT_FOUND); free(host); return 0; }
    free(host);
    gaddr p = A(2);
    wr32(p, attributes(&st));
    wr64(p + 4, to_filetime(st.st_birthtimespec)); wr64(p + 12, to_filetime(st.st_atimespec)); wr64(p + 20, to_filetime(st.st_mtimespec));
    wr32(p + 28, (uint32_t)((uint64_t)st.st_size >> 32)); wr32(p + 32, (uint32_t)st.st_size);
    return 1;
}
static uint32_t SetFileAttributesA_(gp_thread *t) { return file_attributes(t, gstr(A(0))) != 0xffffffffu; }  /* no read-only/hidden bits on the host */

static uint32_t path_op(gp_thread *t, const char *guest, int (*op)(const char *))
{
    char *host = gp_path_to_host(guest);
    if (!host) { set_error(t, ERROR_PATH_NOT_FOUND); return 0; }
    int r = op(host);
    if (r) set_error(t, errno_to_win(errno));
    free(host);
    return r == 0;
}
static int mkdir_(const char *p) { return mkdir(p, 0755); }
static uint32_t CreateDirectoryA_(gp_thread *t) { return path_op(t, gstr(A(0)), mkdir_); }
static uint32_t CreateDirectoryW_(gp_thread *t) { char *p = wide_to_utf8_guest(A(0)); uint32_t r = path_op(t, p, mkdir_); free(p); return r; }
static uint32_t RemoveDirectoryA_(gp_thread *t) { return path_op(t, gstr(A(0)), rmdir); }
static uint32_t DeleteFileA_(gp_thread *t) { return path_op(t, gstr(A(0)), unlink); }
static uint32_t DeleteFileW_(gp_thread *t) { char *p = wide_to_utf8_guest(A(0)); uint32_t r = path_op(t, p, unlink); free(p); return r; }
static uint32_t MoveFileA_(gp_thread *t)
{
    char *a = gp_path_to_host(gstr(A(0))), *b = gp_path_to_host(gstr(A(1)));
    struct stat st;
    uint32_t ok = 0;
    if (!a || !b) set_error(t, ERROR_PATH_NOT_FOUND);
    else if (!stat(b, &st)) set_error(t, ERROR_ALREADY_EXISTS);   /* MoveFile never replaces */
    else if (rename(a, b)) set_error(t, errno_to_win(errno));
    else ok = 1;
    free(a); free(b);
    return ok;
}
static uint32_t CopyFileA_(gp_thread *t)
{
    char *a = gp_path_to_host(gstr(A(0))), *b = gp_path_to_host(gstr(A(1)));
    uint32_t ok = 0;
    int in = -1, out = -1;
    if (!a || !b) { set_error(t, ERROR_PATH_NOT_FOUND); goto done; }
    in = open(a, O_RDONLY | O_CLOEXEC);
    if (in < 0) { set_error(t, errno_to_win(errno)); goto done; }
    out = open(b, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | (A(2) ? O_EXCL : 0), 0644);
    if (out < 0) { set_error(t, errno_to_win(errno)); goto done; }
    char buf[65536];
    for (;;) {
        ssize_t n = read(in, buf, sizeof buf);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { set_error(t, errno_to_win(errno)); goto done; }
        if (!n) break;
        for (ssize_t w = 0; w < n;) {
            ssize_t k = write(out, buf + w, (size_t)(n - w));
            if (k < 0 && errno == EINTR) continue;
            if (k < 0) { set_error(t, errno_to_win(errno)); goto done; }
            w += k;
        }
    }
    ok = 1;
done:
    if (in >= 0) close(in);
    if (out >= 0) close(out);
    free(a); free(b);
    return ok;
}

static uint32_t GetCurrentDirectoryA_(gp_thread *t)
{
    char host[PATH_MAX], g[PATH_MAX];
    if (!getcwd(host, sizeof host)) gp_fatal("getcwd failed");
    host_to_guest(host, g, sizeof g);
    uint32_t n = (uint32_t)strlen(g);
    if (A(0) <= n) return n + 1;
    memcpy(G(A(1)), g, n + 1);
    return n;
}
static uint32_t SetCurrentDirectoryA_(gp_thread *t) { return path_op(t, gstr(A(0)), chdir); }

static uint32_t GetFullPathNameA_(gp_thread *t)
{
    char *host = gp_path_to_host(gstr(A(0)));
    if (!host) { set_error(t, ERROR_PATH_NOT_FOUND); return 0; }
    char g[PATH_MAX];
    host_to_guest(host, g, sizeof g);
    free(host);
    uint32_t n = (uint32_t)strlen(g);
    if (A(1) <= n) return n + 1;
    memcpy(G(A(2)), g, n + 1);
    if (A(3)) { char *s = strrchr(g, '\\'); wr32(A(3), s ? A(2) + (uint32_t)(s + 1 - g) : A(2)); }
    return n;
}

static uint32_t GetDriveTypeA_(gp_thread *t)
{
    const char *p = gstr(A(0));
    return (!p || ((p[0] | 0x20) == 'c')) ? 3 : 1;   /* DRIVE_FIXED for C:, DRIVE_NO_ROOT_DIR otherwise */
}
static uint32_t GetLogicalDrives_(gp_thread *t) { (void)t; return 1u << 2; }   /* C: */
static uint32_t GetDiskFreeSpaceA_(gp_thread *t)
{
    if (A(1)) wr32(A(1), 8); if (A(2)) wr32(A(2), 512);
    if (A(3)) wr32(A(3), 0x00ffffff); if (A(4)) wr32(A(4), 0x00ffffff);
    return 1;
}

static uint32_t GetTempPathA_(gp_thread *t)
{
    static const char tmp[] = GUEST_USER_DIR "\\Temp\\";
    char *host = gp_path_to_host(GUEST_USER_DIR "\\Temp");
    mkdir(host, 0755);
    free(host);
    uint32_t n = sizeof tmp - 1;
    if (A(0) <= n) return n + 1;
    memcpy(G(A(1)), tmp, n + 1);
    return n;
}
static uint32_t GetTempFileNameA_(gp_thread *t)
{
    /* (lpPathName, lpPrefixString, uUnique, lpTempFileName): creates the file when uUnique == 0 */
    const char *dir = gstr(A(0)), *prefix = gstr(A(1));
    uint32_t unique = A(2);
    static uint32_t counter;
    char name[300];
    for (uint32_t tries = 0; tries < 0x10000; tries++) {
        uint32_t u = unique ? unique : ((uint32_t)getpid() + __atomic_add_fetch(&counter, 1, __ATOMIC_SEQ_CST)) & 0xffff;
        if (!u) continue;
        size_t dl = strlen(dir);
        snprintf(name, sizeof name, "%s%s%.3s%X.tmp", dir, (dl && (dir[dl - 1] == '\\' || dir[dl - 1] == '/')) ? "" : "\\", prefix, u);
        if (unique) break;
        char *host = gp_path_to_host(name);
        if (!host) { set_error(t, ERROR_PATH_NOT_FOUND); return 0; }
        int fd = open(host, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
        free(host);
        if (fd >= 0) { close(fd); unique = u; break; }
        if (errno != EEXIST) { set_error(t, errno_to_win(errno)); return 0; }
    }
    snprintf((char *)G(A(3)), 260, "%s", name);
    return unique;
}

/* ---------------------------------------------------------------- find */
static bool find_next(gp_handle *h, gaddr data)
{
    struct dirent *e;
    while ((e = readdir(h->dir))) {
        if (fnmatch(h->pattern, e->d_name, FNM_CASEFOLD)) continue;
        char full[PATH_MAX];
        snprintf(full, sizeof full, "%s/%s", h->path, e->d_name);
        struct stat st;
        if (stat(full, &st)) continue;
        memset(G(data), 0, 320);
        wr32(data, attributes(&st));
        wr64(data + 4, to_filetime(st.st_birthtimespec)); wr64(data + 12, to_filetime(st.st_atimespec));
        wr64(data + 20, to_filetime(st.st_mtimespec));
        wr32(data + 28, (uint32_t)((uint64_t)st.st_size >> 32)); wr32(data + 32, (uint32_t)st.st_size);
        snprintf((char *)G(data + 44), 260, "%s", e->d_name);
        return true;
    }
    return false;
}
static uint32_t FindFirstFileA_(gp_thread *t)
{
    const char *g = gstr(A(0));
    const char *slash = strrchr(g, '\\');
    const char *s2 = strrchr(g, '/');
    if (s2 > slash) slash = s2;
    char dir[PATH_MAX];
    if (slash) { snprintf(dir, sizeof dir, "%.*s", (int)(slash - g), g); if (!dir[0] || dir[strlen(dir) - 1] == ':') strcat(dir, "\\"); }
    else snprintf(dir, sizeof dir, ".");
    char *host = gp_path_to_host(dir);
    DIR *d = host ? opendir(host) : NULL;
    if (!d) { free(host); set_error(t, ERROR_PATH_NOT_FOUND); return 0xffffffffu; }
    const char *pat = slash ? slash + 1 : g;
    /* Windows "*.*" matches every name, including ones without a dot */
    gp_handle h = { .type = H_FIND, .fd = -1, .path = host, .pattern = strdup(strcmp(pat, "*.*") ? pat : "*"), .dir = d };
    if (!find_next(&h, A(1))) {
        closedir(d); free(host); free(h.pattern);
        set_error(t, ERROR_FILE_NOT_FOUND);
        return 0xffffffffu;
    }
    return gp_handle_new(h);
}
static uint32_t FindNextFileA_(gp_thread *t)
{
    gp_handle *h = gp_handle_get(A(0), H_FIND);
    if (!h) { set_error(t, ERROR_INVALID_HANDLE); return 0; }
    if (find_next(h, A(1))) return 1;
    set_error(t, ERROR_NO_MORE_FILES);
    return 0;
}
static uint32_t FindClose_(gp_thread *t) { return gp_handle_close(A(0)); }

/* ------------------------------------------------------ sync objects */
static void notify_multi(void);
static uint32_t new_sync(int type, gp_sync *s) { return gp_handle_new((gp_handle){ .type = type, .fd = -1, .sync = s }); }

static uint32_t CreateEventA_(gp_thread *t)
{
    if (A(3)) gp_log("CreateEventA: name \"%s\" ignored (single process)", gstr(A(3)));
    gp_sync *s = gp_sync_new();
    s->manual = A(1) != 0; s->signaled = A(2) != 0;
    return new_sync(H_EVENT, s);
}
/* also used by native subsystems (DirectSound notifications) */
bool gp_event_set(uint32_t handle)
{
    gp_handle *h = gp_handle_get(handle, H_EVENT);
    if (!h) return false;
    pthread_mutex_lock(&h->sync->lock);
    h->sync->signaled = true;
    pthread_cond_broadcast(&h->sync->cond);
    pthread_mutex_unlock(&h->sync->lock);
    notify_multi();
    return true;
}
static uint32_t SetEvent_(gp_thread *t)
{
    if (gp_event_set(A(0))) return 1;
    set_error(t, ERROR_INVALID_HANDLE);
    return 0;
}
static uint32_t ResetEvent_(gp_thread *t)
{
    gp_handle *h = gp_handle_get(A(0), H_EVENT);
    if (!h) { set_error(t, ERROR_INVALID_HANDLE); return 0; }
    pthread_mutex_lock(&h->sync->lock);
    h->sync->signaled = false;
    pthread_mutex_unlock(&h->sync->lock);
    return 1;
}
static uint32_t CreateMutexA_(gp_thread *t)
{
    gp_sync *s = gp_sync_new();
    if (A(1)) { s->owner = t->thread_id; s->count = 1; }
    set_error(t, 0);
    return new_sync(H_MUTEX, s);
}

static uint32_t ReleaseMutex_(gp_thread *t)
{
    gp_handle *h = gp_handle_get(A(0), H_MUTEX);
    if (!h) { set_error(t, ERROR_INVALID_HANDLE); return 0; }
    pthread_mutex_lock(&h->sync->lock);
    if (!h->sync->count || h->sync->owner != t->thread_id) {
        pthread_mutex_unlock(&h->sync->lock);
        set_error(t, 288);                                                 /* ERROR_NOT_OWNER */
        return 0;
    }
    if (--h->sync->count == 0) h->sync->owner = 0;
    pthread_cond_broadcast(&h->sync->cond);
    pthread_mutex_unlock(&h->sync->lock);
    notify_multi();
    return 1;
}

/* WaitForMultipleObjects waiters sleep on one process-wide condition; every
   state change that can satisfy a wait broadcasts it under multi_lock, so a
   waiter that checked all objects under the same lock cannot miss a wake-up. */
static pthread_mutex_t multi_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t multi_cond = PTHREAD_COND_INITIALIZER;
static void notify_multi(void)
{
    pthread_mutex_lock(&multi_lock);
    pthread_cond_broadcast(&multi_cond);
    pthread_mutex_unlock(&multi_lock);
}

void gp_sync_signal_all(gp_sync *s)
{
    pthread_mutex_lock(&s->lock);
    s->finished = true;
    pthread_cond_broadcast(&s->cond);
    pthread_mutex_unlock(&s->lock);
    notify_multi();
}

/* try to acquire under s->lock */
static bool try_acquire(gp_thread *t, int type, gp_sync *s)
{
    switch (type) {
    case H_EVENT: if (!s->signaled) return false; if (!s->manual) s->signaled = false; return true;
    case H_MUTEX:
        if (s->count && s->owner != t->thread_id) return false;
        s->owner = t->thread_id; s->count++; return true;
    case H_SEMAPHORE: if (s->value <= 0) return false; s->value--; return true;
    case H_THREAD: return s->finished;
    }
    return false;
}

static uint32_t wait_one(gp_thread *t, uint32_t handle, uint32_t ms)
{
    gp_handle *h = gp_handle_get(handle, H_NONE);
    if (!h || !h->sync) { set_error(t, ERROR_INVALID_HANDLE); return 0xffffffffu; }
    gp_sync *s = h->sync;
    int type = h->type;
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += ms / 1000; until.tv_nsec += (long)(ms % 1000) * 1000000L;
    if (until.tv_nsec >= 1000000000L) { until.tv_sec++; until.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&s->lock);
    while (!try_acquire(t, type, s)) {
        if (ms == 0) { pthread_mutex_unlock(&s->lock); return 0x102; }            /* WAIT_TIMEOUT */
        int r = ms == 0xffffffffu ? pthread_cond_wait(&s->cond, &s->lock) : pthread_cond_timedwait(&s->cond, &s->lock, &until);
        if (r == ETIMEDOUT && !try_acquire(t, type, s)) { pthread_mutex_unlock(&s->lock); return 0x102; }
        if (r == ETIMEDOUT) break;
    }
    pthread_mutex_unlock(&s->lock);
    return 0;                                                                     /* WAIT_OBJECT_0 */
}
static uint32_t WaitForSingleObject_(gp_thread *t) { return wait_one(t, A(0), A(1)); }

static uint32_t WaitForMultipleObjects_(gp_thread *t)
{
    uint32_t n = A(0), all = A(2), ms = A(3);
    gaddr list = A(1);
    if (n == 0 || n > 64) { set_error(t, ERROR_INVALID_PARAMETER); return 0xffffffffu; }
    if (all) gp_fatal("WaitForMultipleObjects(bWaitAll=TRUE)");
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += ms / 1000; until.tv_nsec += (long)(ms % 1000) * 1000000L;
    if (until.tv_nsec >= 1000000000L) { until.tv_sec++; until.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&multi_lock);
    for (;;) {
        for (uint32_t i = 0; i < n; i++)
            if (wait_one(t, rd32(list + 4 * i), 0) == 0) { pthread_mutex_unlock(&multi_lock); return i; }
        if (ms == 0) break;
        int r = ms == 0xffffffffu ? pthread_cond_wait(&multi_cond, &multi_lock)
                                  : pthread_cond_timedwait(&multi_cond, &multi_lock, &until);
        if (r == ETIMEDOUT) {
            for (uint32_t i = 0; i < n; i++)
                if (wait_one(t, rd32(list + 4 * i), 0) == 0) { pthread_mutex_unlock(&multi_lock); return i; }
            break;
        }
    }
    pthread_mutex_unlock(&multi_lock);
    return 0x102;
}

static uint32_t DuplicateHandle_(gp_thread *t)
{
    /* (hSourceProcess, hSource, hTargetProcess, lpTarget, access, inherit, options) */
    uint32_t src = A(1);
    if (src == 0xfffffffeu) {                    /* GetCurrentThread() pseudo handle -> real handle */
        gp_fatal("DuplicateHandle of the current-thread pseudo handle");
    }
    gp_handle *h = gp_handle_get(src, H_NONE);
    if (!h || !h->sync) gp_fatal("DuplicateHandle of handle 0x%x", src);
    pthread_mutex_lock(&h->sync->lock); h->sync->refs++; pthread_mutex_unlock(&h->sync->lock);
    gp_handle copy = { .type = h->type, .fd = -1, .sync = h->sync };
    wr32(A(3), gp_handle_new(copy));
    if (A(6) & 1) gp_handle_close(src);          /* DUPLICATE_CLOSE_SOURCE */
    return 1;
}

/* ---------------------------------------------------------------- threads */
typedef struct { gp_thread *t; gaddr start, param; gp_sync *sync; } thread_start;

static void *thread_main(void *arg)
{
    thread_start *ts = arg;
    gp_thread *t = ts->t;
    gp_sync *s = ts->sync;
    gaddr start = ts->start, param = ts->param;
    free(ts);
    gp_thread_attach(t);
    pthread_mutex_lock(&s->lock);
    while (s->suspended) pthread_cond_wait(&s->cond, &s->lock);      /* CREATE_SUSPENDED until ResumeThread */
    pthread_mutex_unlock(&s->lock);
    uint32_t code = gp_call_guest(t, start, 1, &param);
    pthread_mutex_lock(&s->lock); s->exit_code = code; pthread_mutex_unlock(&s->lock);
    gp_sync_signal_all(s);
    return NULL;
}

static uint32_t CreateThread_(gp_thread *t)
{
    /* (attributes, stack size, start, param, flags, lpThreadId) */
    if (A(4) & ~4u) gp_fatal("CreateThread: flags 0x%x", A(4));
    thread_start *ts = calloc(1, sizeof *ts);
    if (!ts) gp_fatal("out of host memory");
    ts->start = A(2); ts->param = A(3);
    ts->t = gp_thread_create_state(A(1) > 0x100000 ? A(1) : 0x100000);
    uint32_t tid = ts->t->thread_id;
    ts->sync = gp_sync_new();
    ts->sync->refs = 2;                          /* the handle and the running thread */
    ts->sync->suspended = (A(4) & 4) != 0;
    uint32_t h = new_sync(H_THREAD, ts->sync);
    pthread_t pt;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&at, 8u << 20);    /* native frames of nested guest->native->guest calls */
    if (pthread_create(&pt, &at, thread_main, ts)) gp_fatal("pthread_create failed");
    pthread_attr_destroy(&at);
    if (A(5)) wr32(A(5), tid);
    return h;
}
static uint32_t ResumeThread_(gp_thread *t)
{
    gp_handle *h = gp_handle_get(A(0), H_THREAD);
    if (!h) { set_error(t, ERROR_INVALID_HANDLE); return 0xffffffffu; }
    pthread_mutex_lock(&h->sync->lock);
    uint32_t previous = h->sync->suspended ? 1 : 0;
    h->sync->suspended = false;
    pthread_cond_broadcast(&h->sync->cond);
    pthread_mutex_unlock(&h->sync->lock);
    return previous;
}
static uint32_t GetExitCodeThread_(gp_thread *t)
{
    gp_handle *h = gp_handle_get(A(0), H_THREAD);
    if (!h) { set_error(t, ERROR_INVALID_HANDLE); return 0; }
    pthread_mutex_lock(&h->sync->lock);
    wr32(A(1), h->sync->finished ? h->sync->exit_code : 259);   /* STILL_ACTIVE */
    pthread_mutex_unlock(&h->sync->lock);
    return 1;
}
static uint32_t SetThreadPriority_(gp_thread *t) { (void)t; return 1; }   /* the host scheduler decides */
static uint32_t GetThreadPriority_(gp_thread *t) { (void)t; return 0; }

const gp_api gp_api_kernel32_io[] = {
    API(GetStdHandle_, "GetStdHandle", 1), API(SetStdHandle_, "SetStdHandle", 2), API(GetFileType_, "GetFileType", 1),
    API(CloseHandle_, "CloseHandle", 1),
    API(CreateFileA_, "CreateFileA", 7), API(CreateFileW_, "CreateFileW", 7),
    API(ReadFile_, "ReadFile", 5), API(WriteFile_, "WriteFile", 5),
    API(SetFilePointer_, "SetFilePointer", 4), API(SetFilePointerEx_, "SetFilePointerEx", 5),
    API(GetFileSizeEx_, "GetFileSizeEx", 2), API(SetEndOfFile_, "SetEndOfFile", 1), API(FlushFileBuffers_, "FlushFileBuffers", 1),
    API(GetFileInformationByHandle_, "GetFileInformationByHandle", 2),
    API(GetFileAttributesA_, "GetFileAttributesA", 1), API(GetFileAttributesW_, "GetFileAttributesW", 1),
    API(GetFileAttributesExA_, "GetFileAttributesExA", 3), API(SetFileAttributesA_, "SetFileAttributesA", 2),
    API(CreateDirectoryA_, "CreateDirectoryA", 2), API(CreateDirectoryW_, "CreateDirectoryW", 2),
    API(RemoveDirectoryA_, "RemoveDirectoryA", 1), API(DeleteFileA_, "DeleteFileA", 1), API(DeleteFileW_, "DeleteFileW", 1),
    API(MoveFileA_, "MoveFileA", 2), API(CopyFileA_, "CopyFileA", 3),
    API(GetCurrentDirectoryA_, "GetCurrentDirectoryA", 2), API(SetCurrentDirectoryA_, "SetCurrentDirectoryA", 1),
    API(GetFullPathNameA_, "GetFullPathNameA", 4),
    API(GetTempPathA_, "GetTempPathA", 2), API(GetTempFileNameA_, "GetTempFileNameA", 4),
    API(GetDriveTypeA_, "GetDriveTypeA", 1), API(GetLogicalDrives_, "GetLogicalDrives", 0),
    API(GetDiskFreeSpaceA_, "GetDiskFreeSpaceA", 5),
    API(FindFirstFileA_, "FindFirstFileA", 2), API(FindNextFileA_, "FindNextFileA", 2), API(FindClose_, "FindClose", 1),
    API(CreateEventA_, "CreateEventA", 4), API(SetEvent_, "SetEvent", 1), API(ResetEvent_, "ResetEvent", 1),
    API(CreateMutexA_, "CreateMutexA", 3), API(ReleaseMutex_, "ReleaseMutex", 1),
    API(WaitForSingleObject_, "WaitForSingleObject", 2), API(WaitForMultipleObjects_, "WaitForMultipleObjects", 4),
    API(DuplicateHandle_, "DuplicateHandle", 7),
    API(CreateThread_, "CreateThread", 6), API(ResumeThread_, "ResumeThread", 1), API(GetExitCodeThread_, "GetExitCodeThread", 2),
    API(SetThreadPriority_, "SetThreadPriority", 2), API(GetThreadPriority_, "GetThreadPriority", 1),
    { 0 }
};
