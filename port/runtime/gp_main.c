/* Process start: map the cached guest images, create the main guest thread,
 * run statically imported DLL initialisers, then the game's entry point.
 * usage: fear-runtime <cache dir> <game dir>   (no arguments: app mode, see gp_launcher.m) */
#include "gp.h"
#include "gp_gamepad.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>

char gp_game_dir[1024];
void gp_seed_default_settings(void);
void gp_launcher_prepare(char *game_out, size_t game_cap, char *cache_out, size_t cache_cap);

int main(int argc, char **argv)
{
    char cache[1024];
    if (argc < 3) {
        /* opened as an app: pick the game folder and convert on first launch */
        char game[1024];
        gp_launcher_prepare(game, sizeof game, cache, sizeof cache);
        if (!realpath(game, gp_game_dir)) gp_fatal("game folder %s not found", game);
    } else {
        if (!realpath(argv[1], cache)) gp_fatal("cache folder %s not found", argv[1]);
        if (!realpath(argv[2], gp_game_dir)) gp_fatal("game folder %s not found", argv[2]);
    }
    if (chdir(gp_game_dir)) gp_fatal("cannot enter game folder %s", gp_game_dir);
    /* the converted game code lives in the cache; a development build links it in instead */
    char dylib[1100];
    snprintf(dylib, sizeof dylib, "%s/guest.dylib", cache);
    if (access(dylib, F_OK) == 0 && !dlopen(dylib, RTLD_NOW | RTLD_GLOBAL))
        gp_fatal("cannot load the converted game code %s: %s", dylib, dlerror());
    gp_seed_default_settings();
    gp_vm_init();
    gp_modules_load(cache);
    gp_pad_engine_init(cache);

    gp_module *exe = gp_module_by_name("FEAR.exe");
    if (!exe) gp_fatal("FEAR.exe is not in the cache");
    uint32_t stack = rd32(exe->base + rd32(exe->base + 0x3c) + 0x60);   /* SizeOfStackReserve */
    gp_thread *t = gp_thread_create_state(stack < 0x100000 ? 0x100000 : stack);
    gp_thread_attach(t);

    /* the Windows loader initialises the executable's static DLL imports first */
    static const char *const deps[] = { "msvcr71.dll", "msvcp71.dll" };
    for (size_t i = 0; i < sizeof deps / sizeof *deps; i++) {
        gp_module *m = gp_module_by_name(deps[i]);
        if (!m) gp_fatal("%s is not in the cache", deps[i]);
        if (!gp_module_init(m, t)) gp_fatal("%s DllMain failed", deps[i]);
    }
    gp_log("entering FEAR.exe at 0x%08x", exe->entry);
    gp_call_guest(t, exe->entry, 0, NULL);
    gp_fatal("FEAR.exe entry point returned");
}
