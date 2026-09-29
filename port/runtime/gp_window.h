/* Window/message layer shared by user32, DirectInput and the renderer. */
#ifndef GP_WINDOW_H
#define GP_WINDOW_H
#include "gp.h"

bool gp_headless(void);
void gp_pump_events(void);                       /* translate pending host events into Win32 messages */

/* virtual key state (VK_*) and DirectInput scan code state, updated by input events */
extern uint8_t gp_vk_state[256];                 /* bit 7 = down */
extern uint8_t gp_dik_state[256];
extern int32_t gp_mouse_dx, gp_mouse_dy, gp_mouse_dz;   /* accumulated since last read (DirectInput) */
extern uint8_t gp_mouse_buttons[8];
extern pthread_mutex_t gp_input_lock;
/* DirectInput buffered data; call with gp_input_lock held */
void gp_dinput_key(uint8_t dik, bool down);
void gp_app_init(void);
void gp_dinput_mouse(uint32_t ofs, uint32_t data);

/* game window (the one created by CreateWindowExA), for the Metal renderer */
uint32_t gp_game_hwnd(void);
void *gp_window_metal_layer(uint32_t hwnd);      /* CAMetalLayer *, NULL when headless */
void gp_window_client_size(uint32_t hwnd, uint32_t *w, uint32_t *h);
void gp_display_size(uint32_t *w, uint32_t *h);
void gp_window_pixel_size(uint32_t hwnd, uint32_t *w, uint32_t *h);   /* the window's content size in real (Retina) pixels */

#endif
