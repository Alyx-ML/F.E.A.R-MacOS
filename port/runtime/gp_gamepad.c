/* Game controllers through SDL3 (Xbox, PlayStation, Switch and other supported pads), read by the DirectInput
   layer as one joystick. SDL is used for the gamepad subsystem only; the window and audio stay native. */
#include "gp_gamepad.h"
#include <SDL3/SDL.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static SDL_Gamepad *pad;
static bool sdl_ready;
static char pad_name[128];

static void pad_init(void)
{
    if (sdl_ready) return;
    SDL_SetHint(SDL_HINT_NO_SIGNAL_HANDLERS, "1");          /* the game process keeps its own signal handling */
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    if (!SDL_Init(SDL_INIT_GAMEPAD)) gp_fatal("SDL gamepad support failed to start: %s", SDL_GetError());
    sdl_ready = true;
}

/* open the first connected gamepad, drop it when it disconnects */
static void pad_refresh(void)
{
    pad_init();
    SDL_UpdateGamepads();
    if (pad && !SDL_GamepadConnected(pad)) { SDL_CloseGamepad(pad); pad = NULL; }
    if (pad) return;
    int n = 0;
    SDL_JoystickID *ids = SDL_GetGamepads(&n);
    if (ids && n > 0) {
        pad = SDL_OpenGamepad(ids[0]);
        if (pad) {
            const char *nm = SDL_GetGamepadName(pad);
            snprintf(pad_name, sizeof pad_name, "%s", nm ? nm : "Game Controller");
            gp_log("gamepad connected: %s", pad_name);
        } else gp_log("gamepad %u could not be opened: %s", (unsigned)ids[0], SDL_GetError());
    }
    SDL_free(ids);
}

bool gp_pad_present(void) { pad_refresh(); return pad != NULL; }
const char *gp_pad_name(void) { return pad ? pad_name : "Game Controller"; }

bool gp_pad_read(gp_pad_state *s)
{
    pad_refresh();
    if (!pad) return false;
    memset(s, 0, sizeof *s);
    s->axis[0] = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTX);
    s->axis[1] = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTY);
    int lt = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER), rt = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER);
    s->trigger[0] = (int16_t)lt; s->trigger[1] = (int16_t)rt;
    s->axis[2] = (int16_t)(lt - rt);                      /* Z: the two triggers on one axis, as Windows reports Xbox pads */
    s->axis[3] = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHTX);
    s->axis[4] = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHTY);
    s->axis[5] = 0;                                       /* Rz unused */
    static const SDL_GamepadButton map[GP_PAD_BUTTONS - 2] = {
        SDL_GAMEPAD_BUTTON_SOUTH, SDL_GAMEPAD_BUTTON_EAST, SDL_GAMEPAD_BUTTON_WEST, SDL_GAMEPAD_BUTTON_NORTH,
        SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER, SDL_GAMEPAD_BUTTON_BACK, SDL_GAMEPAD_BUTTON_START,
        SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_BUTTON_RIGHT_STICK, SDL_GAMEPAD_BUTTON_GUIDE, SDL_GAMEPAD_BUTTON_TOUCHPAD };
    for (int i = 0; i < GP_PAD_BUTTONS - 2; i++) s->button[i] = SDL_GetGamepadButton(pad, map[i]);
    s->button[GP_PAD_BUTTONS - 2] = lt > 16384;           /* triggers as buttons too */
    s->button[GP_PAD_BUTTONS - 1] = rt > 16384;
    bool up = SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_UP), down = SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_DOWN);
    bool left = SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_LEFT), right = SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_DPAD_RIGHT);
    /* DirectInput POV: hundredths of a degree clockwise from north, -1 when centred */
    int x = right - left, y = down - up;
    static const int32_t deg[3][3] = { { 31500, 0, 4500 }, { 27000, -1, 9000 }, { 22500, 18000, 13500 } };   /* [y+1][x+1] */
    s->pov = deg[y + 1][x + 1];
    return true;
}

/* ------------------------------------------------------------ controller -> game
   F.E.A.R. has no controller support of its own. Following the community patch EchoPatch, gameplay is driven through the
   game's own command system: buttons call OnCommandOn/OnCommandOff with the game's command ids, and the sticks are
   supplied by native hooks inserted at conversion time into GetExtremalCommandValue (analog commands) and IsCommandOn
   (held commands). In menus, where the game shows a mouse cursor, the pad presses keys and mouse buttons instead.
   Everything is editable in gamepad.cfg. */
#include <ctype.h>
#include <math.h>
#include <stdlib.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>

typedef struct { const char *name; uint8_t scan; bool ext; } keyname;
static const keyname key_names[] = {
    {"A",0x1e,0},{"B",0x30,0},{"C",0x2e,0},{"D",0x20,0},{"E",0x12,0},{"F",0x21,0},{"G",0x22,0},{"H",0x23,0},{"I",0x17,0},{"J",0x24,0},
    {"K",0x25,0},{"L",0x26,0},{"M",0x32,0},{"N",0x31,0},{"O",0x18,0},{"P",0x19,0},{"Q",0x10,0},{"R",0x13,0},{"S",0x1f,0},{"T",0x14,0},
    {"U",0x16,0},{"V",0x2f,0},{"W",0x11,0},{"X",0x2d,0},{"Y",0x15,0},{"Z",0x2c,0},
    {"1",0x02,0},{"2",0x03,0},{"3",0x04,0},{"4",0x05,0},{"5",0x06,0},{"6",0x07,0},{"7",0x08,0},{"8",0x09,0},{"9",0x0a,0},{"0",0x0b,0},
    {"SPACE",0x39,0},{"ENTER",0x1c,0},{"ESC",0x01,0},{"TAB",0x0f,0},{"BACKSPACE",0x0e,0},{"GRAVE",0x29,0},
    {"LCTRL",0x1d,0},{"LSHIFT",0x2a,0},{"LALT",0x38,0},{"RSHIFT",0x36,0},{"RCTRL",0x1d,1},{"RALT",0x38,1},
    {"UP",0x48,1},{"DOWN",0x50,1},{"LEFT",0x4b,1},{"RIGHT",0x4d,1},
    {"F1",0x3b,0},{"F2",0x3c,0},{"F3",0x3d,0},{"F4",0x3e,0},{"F5",0x3f,0},{"F6",0x40,0},{"F7",0x41,0},{"F8",0x42,0},{"F9",0x43,0},{"F10",0x44,0},
};
/* the game's command ids: EchoPatch.ini and src/Client/Controller/SDLGamepadSupport.cpp */
typedef struct { const char *name; int id; } cmdname;
static const cmdname command_names[] = {
    {"FIRE",17},{"AIM",71},{"JUMP",15},{"CROUCH",14},{"RELOAD",88},{"ACTIVATE",87},{"SLOWMO",106},{"MEDKIT",70},{"FLASHLIGHT",114},
    {"MELEE",19},{"GRENADE",81},{"NEXTWEAPON",77},{"NEXTGRENADE",73},{"LEANLEFT",20},{"LEANRIGHT",21},{"MISSION",78},
    {"MENU",13},{"QUICKSAVE",74},{"QUICKLOAD",75},
};
#define MAX_COMMAND_ID 114
enum { CMD_FORWARD = 2, CMD_STRAFE = 5, CMD_PITCH = 22, CMD_YAW = 23 };

enum { IN_A, IN_B, IN_X, IN_Y, IN_LB, IN_RB, IN_BACK, IN_START, IN_LS, IN_RS, IN_GUIDE, IN_TOUCHPAD, IN_LT, IN_RT,
       IN_DPAD_UP, IN_DPAD_DOWN, IN_DPAD_LEFT, IN_DPAD_RIGHT, IN_LSTICK_UP, IN_LSTICK_DOWN, IN_LSTICK_LEFT, IN_LSTICK_RIGHT, IN_COUNT };
static const char *const in_names[IN_COUNT] = { "A","B","X","Y","LB","RB","BACK","START","LS","RS","GUIDE","TOUCHPAD","LT","RT",
    "DPAD_UP","DPAD_DOWN","DPAD_LEFT","DPAD_RIGHT","LSTICK_UP","LSTICK_DOWN","LSTICK_LEFT","LSTICK_RIGHT" };
enum { OUT_NONE, OUT_KEY, OUT_MOUSE, OUT_WHEEL_UP, OUT_WHEEL_DOWN, OUT_COMMAND };
typedef struct { int kind; uint8_t scan; bool ext; int button; int command; } output;

static output game_map[IN_COUNT], menu_map[IN_COUNT];
static float stick_deadzone = 0.24f, aim_sensitivity = 2.0f, menu_look_speed = 900.0f;
static bool emulation_on = true, cfg_loaded;

static const char DEFAULT_CFG[] =
    "# Game controller settings. Format: input = output (one per line, # starts a comment).\n"
    "#\n"
    "# Gameplay: the pad drives the game's own commands, like the EchoPatch community patch. The sticks are analog:\n"
    "# left stick moves and strafes, right stick looks around.\n"
    "# Menus: whenever the game shows its mouse cursor the pad presses keys and mouse buttons (lines starting menu_).\n"
    "#\n"
    "# inputs : A B X Y LB RB BACK START LS RS GUIDE TOUCHPAD LT RT DPAD_UP DPAD_DOWN DPAD_LEFT DPAD_RIGHT\n"
    "# outputs: a command name (FIRE AIM JUMP CROUCH RELOAD ACTIVATE SLOWMO MEDKIT FLASHLIGHT MELEE GRENADE NEXTWEAPON\n"
    "#          NEXTGRENADE LEANLEFT LEANRIGHT MISSION MENU QUICKSAVE QUICKLOAD) or COMMAND:<id>,\n"
    "#          a key (A-Z 0-9 SPACE ENTER ESC TAB BACKSPACE GRAVE LCTRL LSHIFT LALT UP DOWN LEFT RIGHT F1-F10),\n"
    "#          MOUSE1..MOUSE5, WHEEL_UP, WHEEL_DOWN, or NONE\n"
    "\n"
    "emulation = on\n"
    "stick_deadzone = 0.24\n"
    "aim_sensitivity = 2.0\n"
    "menu_look_speed = 900\n"
    "\n"
    "A = JUMP\nB = CROUCH\nX = RELOAD\nY = SLOWMO\n"
    "LS = MEDKIT\nRS = FLASHLIGHT\nLB = GRENADE\nRB = MELEE\n"
    "DPAD_UP = NEXTWEAPON\nDPAD_DOWN = NEXTGRENADE\nDPAD_LEFT = LEANLEFT\nDPAD_RIGHT = LEANRIGHT\n"
    "LT = AIM\nRT = FIRE\nBACK = MISSION\nSTART = ESC\n"
    "\n"
    "menu_A = ENTER\nmenu_B = ESC\nmenu_START = ESC\n"
    "menu_DPAD_UP = UP\nmenu_DPAD_DOWN = DOWN\nmenu_DPAD_LEFT = LEFT\nmenu_DPAD_RIGHT = RIGHT\n"
    "menu_LSTICK_UP = UP\nmenu_LSTICK_DOWN = DOWN\nmenu_LSTICK_LEFT = LEFT\nmenu_LSTICK_RIGHT = RIGHT\n"
    "menu_RT = MOUSE1\nmenu_LT = MOUSE2\n";

static bool parse_output(const char *v, output *o)
{
    if (!strcasecmp(v, "NONE")) { *o = (output){ .kind = OUT_NONE }; return true; }
    if (!strcasecmp(v, "WHEEL_UP")) { *o = (output){ .kind = OUT_WHEEL_UP }; return true; }
    if (!strcasecmp(v, "WHEEL_DOWN")) { *o = (output){ .kind = OUT_WHEEL_DOWN }; return true; }
    if (!strncasecmp(v, "MOUSE", 5) && v[5] >= '1' && v[5] <= '5' && !v[6]) { *o = (output){ .kind = OUT_MOUSE, .button = v[5] - '1' }; return true; }
    if (!strncasecmp(v, "COMMAND:", 8)) {
        char *end; long id = strtol(v + 8, &end, 10);
        if (*end || id < 1 || id > MAX_COMMAND_ID) return false;
        *o = (output){ .kind = OUT_COMMAND, .command = (int)id };
        return true;
    }
    for (size_t i = 0; i < sizeof command_names / sizeof *command_names; i++)
        if (!strcasecmp(v, command_names[i].name)) { *o = (output){ .kind = OUT_COMMAND, .command = command_names[i].id }; return true; }
    for (size_t i = 0; i < sizeof key_names / sizeof *key_names; i++)
        if (!strcasecmp(v, key_names[i].name)) { *o = (output){ .kind = OUT_KEY, .scan = key_names[i].scan, .ext = key_names[i].ext }; return true; }
    return false;
}

static char *trim(char *s)
{
    while (isspace((unsigned char)*s)) s++;
    char *e = s + strlen(s);
    while (e > s && isspace((unsigned char)e[-1])) *--e = 0;
    return s;
}

static void cfg_load(void)
{
    cfg_loaded = true;
    char path[1200];
    snprintf(path, sizeof path, "%s/gamepad.cfg", gp_user_root());
    if (access(path, F_OK) != 0) {
        FILE *w = fopen(path, "w");
        if (!w) gp_fatal("cannot write %s", path);
        fputs(DEFAULT_CFG, w);
        if (fclose(w)) gp_fatal("cannot write %s", path);
    }
    FILE *f = fopen(path, "r");
    if (!f) gp_fatal("cannot read %s", path);
    char line[256];
    int lineno = 0;
    while (fgets(line, sizeof line, f)) {
        lineno++;
        char *hash = strchr(line, '#');
        if (hash) *hash = 0;
        char *eq = strchr(line, '=');
        if (!eq) { if (*trim(line)) gp_fatal("%s line %d: expected \"input = output\"", path, lineno); continue; }
        *eq = 0;
        char *k = trim(line), *v = trim(eq + 1);
        if (!strcasecmp(k, "emulation")) { emulation_on = !strcasecmp(v, "on") || !strcmp(v, "1"); continue; }
        if (!strcasecmp(k, "stick_deadzone")) { stick_deadzone = (float)atof(v); continue; }
        if (!strcasecmp(k, "aim_sensitivity")) { aim_sensitivity = (float)atof(v); continue; }
        if (!strcasecmp(k, "menu_look_speed")) { menu_look_speed = (float)atof(v); continue; }
        output *table = game_map;
        if (!strncasecmp(k, "menu_", 5)) { table = menu_map; k += 5; }
        int in = -1;
        for (int i = 0; i < IN_COUNT; i++) if (!strcasecmp(k, in_names[i])) in = i;
        if (in < 0) gp_fatal("%s line %d: unknown input \"%s\"", path, lineno, k);
        if (!parse_output(v, &table[in])) gp_fatal("%s line %d: unknown output \"%s\"", path, lineno, v);
    }
    fclose(f);
}

/* ---- engine access (addresses come from the converter: hooks.txt) */
static gaddr addr_on_command_on, addr_on_command_off, addr_shell_var;
static bool engine_ready;
static bool command_active[MAX_COMMAND_ID + 1];

void gp_pad_engine_init(const char *cache)
{
    char path[1200];
    snprintf(path, sizeof path, "%s/hooks.txt", cache);
    FILE *f = fopen(path, "r");
    if (!f) gp_fatal("%s is missing: the converted game does not have the controller hooks; convert the game again", path);
    char name[64];
    unsigned addr;
    while (fscanf(f, "%63s %x", name, &addr) == 2) {
        if (!strcmp(name, "OnCommandOn")) addr_on_command_on = addr;
        else if (!strcmp(name, "OnCommandOff")) addr_on_command_off = addr;
        else if (!strcmp(name, "ShellVariable")) addr_shell_var = addr;
    }
    fclose(f);
    if (!addr_on_command_on || !addr_on_command_off || !addr_shell_var) gp_fatal("%s is incomplete", path);
    engine_ready = true;
}

static void engine_command(int id, bool on)
{
    uint32_t shell = rd32(addr_shell_var);
    if (!shell) return;                                    /* the game has not created its client shell yet */
    command_active[id] = on;
    uint32_t arg = (uint32_t)id;
    gp_call_guest_this(gp_current(), on ? addr_on_command_on : addr_on_command_off, shell, 1, &arg);
}

/* ---- pad state shared with the hooks */
static gp_pad_state latest;
static bool latest_valid;
static uint64_t latest_ns;
static bool in_game_mode;                                 /* no mouse cursor shown: gameplay */
static volatile bool cursor_shown = true;                 /* the game starts in its menus */
void gp_pad_note_cursor(bool shown) { cursor_shown = shown; }

static void refresh_state(void)
{
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (latest_valid && now - latest_ns < 2000000ull) return;
    latest_ns = now;
    latest_valid = gp_pad_read(&latest);
}

/* called from translated GameClient code (inserted by tools/hooks.py) */
uint32_t gp_pad_hook_command_on(uint32_t id)
{
    return in_game_mode && id <= MAX_COMMAND_ID && command_active[id];
}
bool gp_pad_hook_axis(uint32_t id, double *value)
{
    if (!emulation_on || !in_game_mode || !engine_ready) return false;
    if (id != CMD_FORWARD && id != CMD_STRAFE && id != CMD_PITCH && id != CMD_YAW) return false;
    refresh_state();
    if (!latest_valid) return false;
    int raw = id == CMD_FORWARD ? -latest.axis[1] : id == CMD_STRAFE ? latest.axis[0] : id == CMD_PITCH ? latest.axis[4] : latest.axis[3];
    double v = abs(raw) < 7849 ? 0.0 : raw / 32768.0;      /* EchoPatch's dead zone */
    if (id == CMD_PITCH || id == CMD_YAW) v *= aim_sensitivity;
    *value = v;
    return true;
}

static void emit_keys(const output *o, bool down)
{
    switch (o->kind) {
    case OUT_KEY: gp_inject_key(o->scan, o->ext, down); break;
    case OUT_MOUSE: gp_inject_mouse_button(o->button, down); break;
    case OUT_WHEEL_UP: if (down) gp_inject_wheel(120); break;
    case OUT_WHEEL_DOWN: if (down) gp_inject_wheel(-120); break;
    case OUT_COMMAND: if (engine_ready) engine_command(o->command, down); break;
    default: break;
    }
}

void gp_pad_emulate(void)
{
    static uint64_t last_ns;
    static bool held[IN_COUNT];
    static bool held_in_game;                             /* which map the held outputs belong to */
    static bool suppressed[IN_COUNT];                     /* down when the map changed: ignored until released */
    static float rem_x, rem_y;
    if (gp_current()->thread_id != gp_main_thread_id()) return;   /* the game's input runs on its main thread */
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now - last_ns < 4000000ull) return;                   /* at most 250 reads a second */
    double dt = last_ns ? (double)(now - last_ns) / 1e9 : 0.0;
    last_ns = now;
    if (!cfg_loaded) cfg_load();
    bool game_mode = !cursor_shown;
    output *map = game_mode ? game_map : menu_map;
    gp_pad_state st;
    bool have = emulation_on && gp_pad_read(&st);
    if (have) { latest = st; latest_valid = true; latest_ns = now; }
    in_game_mode = have && game_mode;
    /* switching between gameplay and menus, or losing the pad: release everything that is held */
    bool switched = false;
    if (!have || game_mode != held_in_game) {
        output *old = held_in_game ? game_map : menu_map;
        for (int i = 0; i < IN_COUNT; i++) if (held[i]) { held[i] = false; emit_keys(&old[i], false); }
        held_in_game = game_mode;
        if (!have) return;
        switched = true;
    }
    bool now_down[IN_COUNT] = {0};
    for (int i = 0; i <= IN_TOUCHPAD; i++) now_down[i] = st.button[i];
    now_down[IN_LT] = st.trigger[0] > 12000; now_down[IN_RT] = st.trigger[1] > 12000;
    now_down[IN_DPAD_UP] = st.pov == 0 || st.pov == 4500 || st.pov == 31500;
    now_down[IN_DPAD_DOWN] = st.pov == 18000 || st.pov == 13500 || st.pov == 22500;
    now_down[IN_DPAD_LEFT] = st.pov == 27000 || st.pov == 22500 || st.pov == 31500;
    now_down[IN_DPAD_RIGHT] = st.pov == 9000 || st.pov == 4500 || st.pov == 13500;
    float lx = st.axis[0] / 32768.0f, ly = st.axis[1] / 32768.0f, th = 0.5f;
    now_down[IN_LSTICK_UP] = ly < -th; now_down[IN_LSTICK_DOWN] = ly > th;
    now_down[IN_LSTICK_LEFT] = lx < -th; now_down[IN_LSTICK_RIGHT] = lx > th;
    /* A button held while the game flipped between gameplay and menus (Start opens the pause menu) must not act again in
       the other map: it stays ignored until it is released. */
    for (int i = 0; i < IN_COUNT; i++) {
        if (switched && now_down[i]) suppressed[i] = true;
        if (!now_down[i]) suppressed[i] = false;
        if (suppressed[i]) now_down[i] = false;
    }
    for (int i = 0; i < IN_COUNT; i++)
        if (now_down[i] != held[i]) {
            held[i] = now_down[i];
            if (getenv("GP_TRACE_PAD")) gp_log("pad: %s %s -> %s output kind %d command %d", in_names[i], now_down[i] ? "down" : "up", game_mode ? "game" : "menu", map[i].kind, map[i].command);
            emit_keys(&map[i], now_down[i]);
        }
    if (game_mode) return;                                     /* gameplay sticks are analog, supplied through the hooks */
    /* menus: the right stick moves the mouse cursor */
    float rx = st.axis[3] / 32768.0f, ry = st.axis[4] / 32768.0f;
    float mag = sqrtf(rx * rx + ry * ry);
    if (mag > stick_deadzone) {
        float scale = (mag - stick_deadzone) / (1.0f - stick_deadzone);
        scale = scale > 1.0f ? 1.0f : scale;
        scale = scale * scale / mag;
        rem_x += rx * scale * menu_look_speed * (float)dt;
        rem_y += ry * scale * menu_look_speed * (float)dt;
        int dx = (int)rem_x, dy = (int)rem_y;
        rem_x -= (float)dx; rem_y -= (float)dy;
        if (dx || dy) gp_inject_mouse_move(dx, dy);
    } else rem_x = rem_y = 0.0f;
}
