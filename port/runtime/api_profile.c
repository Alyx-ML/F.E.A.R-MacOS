/* kernel32.dll private profile (INI) functions.
 * Parsing follows Windows: case-insensitive section/key names, whitespace
 * trimmed around names and values, values keep surrounding quotes stripped. */
#include "gp_api.h"
#include "gp_win.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define DLL "kernel32.dll"

static pthread_mutex_t ini_lock = PTHREAD_MUTEX_INITIALIZER;

static char *read_all(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *s = malloc((size_t)n + 1);
    if (!s || fread(s, 1, (size_t)n, f) != (size_t)n) gp_fatal("cannot read %s", path);
    s[n] = 0;
    fclose(f);
    return s;
}

static char *trim(char *s)
{
    while (*s == ' ' || *s == '\t') s++;
    char *e = s + strlen(s);
    while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\r')) *--e = 0;
    return s;
}

/* Windows: a file name without a path refers to the Windows directory, which does not exist here */
static char *ini_path(const char *guest)
{
    if (!strchr(guest, '\\') && !strchr(guest, '/')) {
        gp_log("profile file \"%s\" in the Windows directory is not available", guest);
        return NULL;
    }
    return gp_path_to_host(guest);
}

/* find value; returns malloc'd string or NULL */
static char *lookup(const char *path, const char *section, const char *key)
{
    char *text = read_all(path);
    if (!text) return NULL;
    char *result = NULL;
    bool in = false;
    for (char *line = strtok(text, "\n"); line; line = strtok(NULL, "\n")) {
        char *l = trim(line);
        if (*l == '[') {
            char *e = strchr(l, ']');
            if (e) *e = 0;
            in = !strcasecmp(trim(l + 1), section);
            continue;
        }
        if (!in || *l == ';') continue;
        char *eq = strchr(l, '=');
        if (!eq) continue;
        *eq = 0;
        if (strcasecmp(trim(l), key)) continue;
        char *v = trim(eq + 1);
        size_t n = strlen(v);
        if (n >= 2 && ((v[0] == '"' && v[n - 1] == '"') || (v[0] == '\'' && v[n - 1] == '\''))) { v[n - 1] = 0; v++; }
        result = strdup(v);
        break;
    }
    free(text);
    return result;
}

static uint32_t GetPrivateProfileIntA_(gp_thread *t)
{
    char *path = ini_path(gstr(A(3)));
    pthread_mutex_lock(&ini_lock);
    char *v = path ? lookup(path, gstr(A(0)), gstr(A(1))) : NULL;
    pthread_mutex_unlock(&ini_lock);
    free(path);
    if (!v) return A(2);
    uint32_t r = (uint32_t)strtol(v, NULL, 10);
    free(v);
    return r;
}

static uint32_t copy_out(gaddr buf, uint32_t cap, const char *v)
{
    if (!cap) return 0;
    uint32_t n = (uint32_t)strlen(v);
    if (n >= cap) n = cap - 1;
    memcpy(G(buf), v, n);
    wr8(buf + n, 0);
    return n;
}

static uint32_t GetPrivateProfileStringA_(gp_thread *t)
{
    /* (section, key, default, buffer, size, file) */
    if (!A(0) || !A(1)) gp_fatal("GetPrivateProfileStringA enumeration (NULL section or key)");
    char *path = ini_path(gstr(A(5)));
    pthread_mutex_lock(&ini_lock);
    char *v = path ? lookup(path, gstr(A(0)), gstr(A(1))) : NULL;
    pthread_mutex_unlock(&ini_lock);
    free(path);
    uint32_t n;
    if (v) { n = copy_out(A(3), A(4), v); free(v); }
    else {
        char *d = strdup(A(2) ? gstr(A(2)) : "");
        char *td = trim(d);                      /* Windows trims trailing blanks of the default */
        n = copy_out(A(3), A(4), td);
        free(d);
    }
    return n;
}

static char *narrow(gaddr w)
{
    size_t n = 0;
    while (rd16(w + 2 * (uint32_t)n)) n++;
    char *s = malloc(n + 1);
    for (size_t i = 0; i < n; i++) { int c = gp_wc_to_cp1252(rd16(w + 2 * (uint32_t)i)); s[i] = (char)(c < 0 ? '?' : c); }
    s[n] = 0;
    return s;
}

static uint32_t GetPrivateProfileStringW_(gp_thread *t)
{
    if (!A(0) || !A(1)) gp_fatal("GetPrivateProfileStringW enumeration (NULL section or key)");
    char *sec = narrow(A(0)), *key = narrow(A(1)), *file = narrow(A(5));
    char *def = A(2) ? narrow(A(2)) : strdup("");
    char *path = ini_path(file);
    pthread_mutex_lock(&ini_lock);
    char *v = path ? lookup(path, sec, key) : NULL;
    pthread_mutex_unlock(&ini_lock);
    const char *src = v ? v : trim(def);
    uint32_t cap = A(4), n = (uint32_t)strlen(src);
    if (cap) {
        if (n >= cap) n = cap - 1;
        for (uint32_t i = 0; i < n; i++) wr16(A(3) + 2 * i, gp_cp1252_to_wc((uint8_t)src[i]));
        wr16(A(3) + 2 * n, 0);
    } else n = 0;
    free(sec); free(key); free(file); free(def); free(path); free(v);
    return n;
}

static bool write_value(const char *path, const char *section, const char *key, const char *value)
{
    char *text = read_all(path);
    size_t cap = (text ? strlen(text) : 0) + strlen(section) + strlen(key) + (value ? strlen(value) : 0) + 64;
    char *out = malloc(cap);
    out[0] = 0;
    bool in = false, done = false, seen_section = false;
    char *save = NULL;
    for (char *line = text ? strtok_r(text, "\n", &save) : NULL; line; line = strtok_r(NULL, "\n", &save)) {
        char copy[4096];
        snprintf(copy, sizeof copy, "%s", line);
        char *l = trim(copy);
        if (*l == '[') {
            if (in && !done && value) { snprintf(out + strlen(out), cap - strlen(out), "%s=%s\r\n", key, value); done = true; }
            char *e = strchr(l, ']');
            if (e) *e = 0;
            in = !strcasecmp(trim(l + 1), section);
            if (in) seen_section = true;
        } else if (in && key) {
            char *eq = strchr(l, '=');
            if (eq) {
                *eq = 0;
                if (!strcasecmp(trim(l), key)) {
                    if (value && !done) snprintf(out + strlen(out), cap - strlen(out), "%s=%s\r\n", key, value);
                    done = true;
                    continue;
                }
            }
        }
        if (in && !key) continue;                       /* key == NULL deletes the whole section */
        snprintf(out + strlen(out), cap - strlen(out), "%s\n", line);
    }
    if (!done && value && key) {
        if (!seen_section) snprintf(out + strlen(out), cap - strlen(out), "[%s]\r\n", section);
        else if (!in) gp_fatal("profile write: section [%s] closed before insertion", section);
        snprintf(out + strlen(out), cap - strlen(out), "%s=%s\r\n", key, value);
    }
    free(text);
    char tmp[1200];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    FILE *f = fopen(tmp, "wb");
    bool ok = f && fwrite(out, 1, strlen(out), f) == strlen(out);
    if (f && fclose(f)) ok = false;
    if (ok) ok = rename(tmp, path) == 0;
    free(out);
    return ok;
}

static uint32_t WritePrivateProfileStringA_(gp_thread *t)
{
    char *path = ini_path(gstr(A(3)));
    if (!path) { set_error(t, ERROR_PATH_NOT_FOUND); return 0; }
    pthread_mutex_lock(&ini_lock);
    bool ok = write_value(path, gstr(A(0)), gstr(A(1)), gstr(A(2)));
    pthread_mutex_unlock(&ini_lock);
    free(path);
    if (!ok) set_error(t, ERROR_ACCESS_DENIED);
    return ok;
}
static uint32_t WritePrivateProfileStringW_(gp_thread *t)
{
    char *sec = narrow(A(0)), *key = A(1) ? narrow(A(1)) : NULL, *val = A(2) ? narrow(A(2)) : NULL, *file = narrow(A(3));
    char *path = ini_path(file);
    bool ok = false;
    if (path) { pthread_mutex_lock(&ini_lock); ok = write_value(path, sec, key, val); pthread_mutex_unlock(&ini_lock); }
    free(sec); free(key); free(val); free(file); free(path);
    if (!ok) set_error(t, ERROR_ACCESS_DENIED);
    return ok;
}

const gp_api gp_api_kernel32_profile[] = {
    API(GetPrivateProfileIntA_, "GetPrivateProfileIntA", 4),
    API(GetPrivateProfileStringA_, "GetPrivateProfileStringA", 6),
    API(GetPrivateProfileStringW_, "GetPrivateProfileStringW", 6),
    API(WritePrivateProfileStringA_, "WritePrivateProfileStringA", 4),
    API(WritePrivateProfileStringW_, "WritePrivateProfileStringW", 4),
    { 0 }
};
