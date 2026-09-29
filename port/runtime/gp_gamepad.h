/* Game controller state from SDL3, shaped like a DirectInput joystick (see gp_dinput.c). */
#ifndef GP_GAMEPAD_H
#define GP_GAMEPAD_H
#include "gp.h"

#define GP_PAD_AXES 6          /* X, Y (left stick), Z (triggers), Rx, Ry (right stick), Rz (unused) */
#define GP_PAD_BUTTONS 14      /* A B X Y LB RB Back Start LS RS Guide Touchpad, then LT RT as buttons */

typedef struct {
    int16_t axis[GP_PAD_AXES];         /* -32768..32767, positive = right/down */
    uint8_t button[GP_PAD_BUTTONS];    /* 0 or 1 */
    int32_t pov;                       /* hundredths of a degree clockwise from north, -1 = centred */
    int16_t trigger[2];                /* left, right: 0..32767 */
} gp_pad_state;

bool gp_pad_present(void);             /* a controller is connected (opens it on first use) */
const char *gp_pad_name(void);
bool gp_pad_read(gp_pad_state *s);     /* false when no controller is connected */

/* keyboard and mouse emulation (gamepad.cfg in the user folder), called from the message pump */
void gp_pad_emulate(void);
void gp_pad_engine_init(const char *cache);       /* reads hooks.txt written by the converter */
void gp_pad_note_cursor(bool shown);              /* the game showed or hid its mouse cursor */
uint32_t gp_pad_hook_command_on(uint32_t id);     /* for the translated-code hooks (tc_hook_*) */
bool gp_pad_hook_axis(uint32_t id, double *value);
const char *gp_user_root(void);

/* injection into the window layer (gp_window.m), exactly as host keyboard and mouse events arrive */
void gp_inject_key(uint8_t scan, bool extended, bool down);
void gp_inject_mouse_move(int dx, int dy);
void gp_inject_mouse_button(int button, bool down);
void gp_inject_wheel(int delta);

#endif
