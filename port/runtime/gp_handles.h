/* Kernel object handles shared by kernel32 file, sync and thread APIs. */
#ifndef GP_HANDLES_H
#define GP_HANDLES_H
#include "gp.h"
#include <dirent.h>

enum { H_NONE, H_FILE, H_FIND, H_EVENT, H_MUTEX, H_SEMAPHORE, H_THREAD, H_STD };

typedef struct gp_sync {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    int refs;
    /* event */
    bool manual, signaled;
    /* mutex */
    uint32_t owner, count;
    /* semaphore */
    int32_t value, max;
    /* thread */
    bool finished, suspended;       /* suspended: created with CREATE_SUSPENDED, not yet resumed */
    uint32_t exit_code;
} gp_sync;

typedef struct {
    int type;
    int fd;                 /* H_FILE, H_STD */
    bool append_only;
    char *path;             /* H_FILE, H_FIND: host path; H_FIND: directory */
    char *pattern;          /* H_FIND */
    DIR *dir;
    gp_sync *sync;          /* H_EVENT, H_MUTEX, H_SEMAPHORE, H_THREAD */
} gp_handle;

uint32_t gp_handle_new(gp_handle h);
gp_handle *gp_handle_get(uint32_t h, int type);   /* type H_NONE: any */
bool gp_handle_close(uint32_t h);
gp_sync *gp_sync_new(void);
void gp_sync_signal_all(gp_sync *s);               /* thread exit */
bool gp_event_set(uint32_t handle);                 /* SetEvent for native callers */

#endif
