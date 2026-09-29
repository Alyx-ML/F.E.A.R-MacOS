/* Win32 constants and helpers shared by API implementations. */
#ifndef GP_WIN_H
#define GP_WIN_H
#include "gp.h"

/* The guest sees the game folder as this Windows path. */
#define GUEST_GAME_DIR "C:\\FEAR"
/* Per-user data (saves, profiles, settings) */
#define GUEST_USER_DIR "C:\\FEARUSER"

#define ERROR_SUCCESS 0
#define ERROR_FILE_NOT_FOUND 2
#define ERROR_PATH_NOT_FOUND 3
#define ERROR_TOO_MANY_OPEN_FILES 4
#define ERROR_ACCESS_DENIED 5
#define ERROR_INVALID_HANDLE 6
#define ERROR_NOT_ENOUGH_MEMORY 8
#define ERROR_BAD_LENGTH 24
#define ERROR_HANDLE_EOF 38
#define ERROR_NOT_SUPPORTED 50
#define ERROR_FILE_EXISTS 80
#define ERROR_INVALID_PARAMETER 87
#define ERROR_INSUFFICIENT_BUFFER 122
#define ERROR_MOD_NOT_FOUND 126
#define ERROR_PROC_NOT_FOUND 127
#define ERROR_ALREADY_EXISTS 183
#define ERROR_ENVVAR_NOT_FOUND 203
#define ERROR_NO_MORE_ITEMS 259
#define ERROR_INVALID_ADDRESS 487
#define ERROR_DLL_INIT_FAILED 1114
#define ERROR_NO_MORE_FILES 18

#define HEAP_ZERO_MEMORY 0x08
#define HEAP_REALLOC_IN_PLACE_ONLY 0x10
#define MEM_COMMIT 0x1000
#define MEM_RESERVE 0x2000
#define MEM_RELEASE 0x8000
#define MEM_FREE 0x10000
#define MEM_PRIVATE 0x20000
#define PAGE_NOACCESS 0x01
#define PAGE_READWRITE 0x04
#define LCMAP_LOWERCASE 0x100
#define LCMAP_UPPERCASE 0x200

gaddr gp_wstrdup_guest(const char *ascii);
gaddr gp_native_module(const char *name);           /* fake HMODULE of a native DLL, 0 if unknown */
const char *gp_native_module_name(gaddr h);

uint16_t gp_cp1252_to_wc(uint8_t c);
int gp_wc_to_cp1252(uint16_t w);
int gp_upper1252(int c);
int gp_lower1252(int c);
uint16_t gp_upperw(uint16_t c);
uint16_t gp_lowerw(uint16_t c);

#endif
