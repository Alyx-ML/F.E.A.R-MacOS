/* user32.dll: window classes, windows, message queue, hooks, cursor, keyboard state.
 * Windows are AppKit NSWindows with a CAMetalLayer view; GP_HEADLESS=1 keeps
 * them virtual. Guest code runs on the main thread, so PeekMessage pumps AppKit. */
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include "gp_api.h"
#include "gp_win.h"
#include "gp_window.h"
#include "gp_gamepad.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#define DLL "user32.dll"

#define WM_CREATE 0x0001
#define WM_DESTROY 0x0002
#define WM_MOVE 0x0003
#define WM_SIZE 0x0005
#define WM_ACTIVATE 0x0006
#define WM_SETFOCUS 0x0007
#define WM_KILLFOCUS 0x0008
#define WM_PAINT 0x000F
#define WM_CLOSE 0x0010
#define WM_QUIT 0x0012
#define WM_ERASEBKGND 0x0014
#define WM_SHOWWINDOW 0x0018
#define WM_ACTIVATEAPP 0x001C
#define WM_SETCURSOR 0x0020
#define WM_GETMINMAXINFO 0x0024
#define WM_WINDOWPOSCHANGING 0x0046
#define WM_WINDOWPOSCHANGED 0x0047
#define WM_NCCREATE 0x0081
#define WM_NCDESTROY 0x0082
#define WM_NCCALCSIZE 0x0083
#define WM_NCACTIVATE 0x0086
#define WM_KEYDOWN 0x0100
#define WM_KEYUP 0x0101
#define WM_CHAR 0x0102
#define WM_SYSKEYDOWN 0x0104
#define WM_SYSKEYUP 0x0105
#define WM_SYSCOMMAND 0x0112
#define WM_MOUSEMOVE 0x0200
#define WM_LBUTTONDOWN 0x0201
#define WM_LBUTTONUP 0x0202
#define WM_RBUTTONDOWN 0x0204
#define WM_RBUTTONUP 0x0205
#define WM_MBUTTONDOWN 0x0207
#define WM_MBUTTONUP 0x0208
#define WM_MOUSEWHEEL 0x020A

uint8_t gp_vk_state[256];
uint8_t gp_dik_state[256];
int32_t gp_mouse_dx, gp_mouse_dy, gp_mouse_dz;
uint8_t gp_mouse_buttons[8];
pthread_mutex_t gp_input_lock = PTHREAD_MUTEX_INITIALIZER;

static int headless = -1;
bool gp_headless(void)
{
    if (headless < 0) headless = getenv("GP_HEADLESS") && strcmp(getenv("GP_HEADLESS"), "0");
    return headless;
}

/* ------------------------------------------------------------ classes */
typedef struct { uint16_t name[64]; uint32_t style, proc, instance, icon, cursor, background; uint32_t atom; bool unicode; } wclass;
static wclass classes[32];
static int nclasses;

static void guest_wstr(gaddr a, uint16_t *out, size_t cap)
{
    size_t i = 0;
    if (a && a < 0x10000) { out[0] = 0; return; }   /* atoms are compared by value */
    for (; a && i + 1 < cap; i++) { out[i] = rd16(a + 2 * (uint32_t)i); if (!out[i]) break; }
    out[i < cap ? i : cap - 1] = 0;
}
static void guest_astr_w(gaddr a, uint16_t *out, size_t cap)
{
    size_t i = 0;
    for (; a && i + 1 < cap; i++) { out[i] = gp_cp1252_to_wc(rd8(a + (uint32_t)i)); if (!out[i]) break; }
    out[i < cap ? i : cap - 1] = 0;
}
static bool weq(const uint16_t *a, const uint16_t *b)
{
    for (; *a && *b; a++, b++) if (gp_lowerw(*a) != gp_lowerw(*b)) return false;
    return *a == *b;
}

static uint32_t RegisterClassW_(gp_thread *t)
{
    gaddr wc = A(0);
    if (nclasses == 32) gp_fatal("too many window classes");
    wclass *c = &classes[nclasses];
    memset(c, 0, sizeof *c);
    c->style = rd32(wc); c->proc = rd32(wc + 4); c->instance = rd32(wc + 16);
    c->icon = rd32(wc + 20); c->cursor = rd32(wc + 24); c->background = rd32(wc + 28);
    guest_wstr(rd32(wc + 36), c->name, 64);
    c->atom = 0xC000u + (uint32_t)nclasses;
    c->unicode = true;
    nclasses++;
    return c->atom;
}

/* ------------------------------------------------------------ windows */
@interface GPView : NSView
@end

typedef struct {
    bool used;
    uint32_t hwnd, style, exstyle, proc, parent, userdata, instance, id;
    int32_t x, y, w, h;                 /* window rect in screen coordinates (Win32: y down) */
    bool visible, is_desktop;
    wclass *cls;
    NSWindow *ns;
    GPView *view;
    CAMetalLayer *layer;
} gwin;

#define MAX_WINDOWS 16
#define HWND_BASE 0x00010010u
static gwin windows[MAX_WINDOWS];
static uint32_t game_hwnd;
static const uint32_t desktop_hwnd = 0x00010004u;

static gwin *win(uint32_t h)
{
    if (h < HWND_BASE || (h - HWND_BASE) % 4) return NULL;
    uint32_t i = (h - HWND_BASE) / 4;
    return i < MAX_WINDOWS && windows[i].used ? &windows[i] : NULL;
}

/* window content size in points for a game resolution of w x h pixels: 1:1, shrunk to fit 90% of the visible screen */
static NSSize fit_points(int32_t w, int32_t h)
{
    NSRect vis = NSScreen.mainScreen.visibleFrame;
    CGFloat k = fmin(1.0, fmin(vis.size.width * 0.9 / w, vis.size.height * 0.9 / h));
    return NSMakeSize(floor(w * k), floor(h * k));
}

void gp_display_size(uint32_t *w, uint32_t *h)
{
    if (gp_headless()) { *w = 1920; *h = 1080; return; }
    /* the game renders into a layer the system scales, so modes are counted in backing pixels, not points */
    NSScreen *sc = NSScreen.mainScreen;
    CGFloat k = sc.backingScaleFactor;
    *w = (uint32_t)(sc.frame.size.width * k); *h = (uint32_t)(sc.frame.size.height * k);
}

uint32_t gp_game_hwnd(void) { return game_hwnd; }
void *gp_window_metal_layer(uint32_t h) { gwin *w = win(h); return w ? (__bridge void *)w->layer : NULL; }

/* Win32 client size = window size for the borderless/popup game window; for
   captioned windows AdjustWindowRect added the frame, which AppKit draws itself. */
static void client_size(gwin *w, uint32_t *cw, uint32_t *ch)
{
    /* the game's coordinate space is its own pixel size; the view is only scaled to fit the screen */
    *cw = (uint32_t)w->w; *ch = (uint32_t)w->h;
}
void gp_window_pixel_size(uint32_t h, uint32_t *pw, uint32_t *ph)
{
    gwin *w = win(h);
    if (!w || !w->ns) { *pw = w ? (uint32_t)w->w : 0; *ph = w ? (uint32_t)w->h : 0; return; }
    NSSize s = [w->view convertSizeToBacking:w->view.bounds.size];
    *pw = (uint32_t)s.width; *ph = (uint32_t)s.height;
}
void gp_window_client_size(uint32_t h, uint32_t *cw, uint32_t *ch)
{
    gwin *w = win(h);
    if (!w) gp_fatal("client size of unknown window 0x%x", h);
    client_size(w, cw, ch);
}

/* ------------------------------------------------------ message queue */
typedef struct { uint32_t hwnd, msg, wparam, lparam, time; } qmsg;
#define QSIZE 1024
static qmsg queue[QSIZE];
static uint32_t qhead, qtail;
static bool quit_posted;
static uint32_t quit_code;

static void post(uint32_t hwnd, uint32_t msg, uint32_t wp, uint32_t lp)
{
    if (qtail - qhead == QSIZE) {
        gp_log("message queue full; dropping message 0x%x", msg);   /* Windows also caps the queue (10000) */
        return;
    }
    queue[qtail++ % QSIZE] = (qmsg){ hwnd, msg, wp, lp, (uint32_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000) };
}

static uint32_t call_proc(uint32_t proc, uint32_t hwnd, uint32_t msg, uint32_t wp, uint32_t lp)
{
    gp_thread *t = gp_current();
    uint32_t args[4] = { hwnd, msg, wp, lp };
    return gp_call_guest(t, proc, 4, args);
}

static uint32_t send_msg(uint32_t hwnd, uint32_t msg, uint32_t wp, uint32_t lp)
{
    gwin *w = win(hwnd);
    if (!w) return 0;
    return call_proc(w->proc, hwnd, msg, wp, lp);
}

/* -------------------------------------------------- key translation */
typedef struct { uint16_t vk, scan; bool extended; } keymap;
static keymap mac_keys[128];
static void init_keys(void)
{
    static bool done;
    if (done) return;
    done = true;
    /* kVK_* (ANSI layout) -> VK code, set-1 scan code (= DirectInput DIK) */
    /* scan codes with 0x100 set are extended (E0-prefixed) keys */
    static const struct { uint8_t mac; uint16_t vk, scan; } k[] = {
        {0x00,'A',0x1e},{0x01,'S',0x1f},{0x02,'D',0x20},{0x03,'F',0x21},{0x04,'H',0x23},{0x05,'G',0x22},{0x06,'Z',0x2c},
        {0x07,'X',0x2d},{0x08,'C',0x2e},{0x09,'V',0x2f},{0x0b,'B',0x30},{0x0c,'Q',0x10},{0x0d,'W',0x11},{0x0e,'E',0x12},
        {0x0f,'R',0x13},{0x10,'Y',0x15},{0x11,'T',0x14},{0x12,'1',0x02},{0x13,'2',0x03},{0x14,'3',0x04},{0x15,'4',0x05},
        {0x16,'6',0x07},{0x17,'5',0x06},{0x18,0xbb,0x0d},{0x19,'9',0x0a},{0x1a,'7',0x08},{0x1b,0xbd,0x0c},{0x1c,'8',0x09},
        {0x1d,'0',0x0b},{0x1e,0xdd,0x1b},{0x1f,'O',0x18},{0x20,'U',0x16},{0x21,0xdb,0x1a},{0x22,'I',0x17},{0x23,'P',0x19},
        {0x24,0x0d,0x1c},{0x25,'L',0x26},{0x26,'J',0x24},{0x27,0xde,0x28},{0x28,'K',0x25},{0x29,0xba,0x27},{0x2a,0xdc,0x2b},
        {0x2b,0xbc,0x33},{0x2c,0xbf,0x35},{0x2d,'N',0x31},{0x2e,'M',0x32},{0x2f,0xbe,0x34},{0x30,0x09,0x0f},{0x31,0x20,0x39},
        {0x32,0xc0,0x29},{0x33,0x08,0x0e},{0x35,0x1b,0x01},{0x37,0x5b,0x100|0x5b},{0x38,0x10,0x2a},{0x39,0x14,0x3a},{0x3a,0x12,0x38},
        {0x3b,0x11,0x1d},{0x3c,0x10,0x36},{0x3d,0x12,0x100|0x38},{0x3e,0x11,0x100|0x1d},
        {0x41,0x6e,0x53},{0x43,0x6a,0x37},{0x45,0x6b,0x4e},{0x47,0x90,0x45},{0x4b,0x6f,0x100|0x35},{0x4c,0x0d,0x100|0x1c},{0x4e,0x6d,0x4a},
        {0x52,0x60,0x52},{0x53,0x61,0x4f},{0x54,0x62,0x50},{0x55,0x63,0x51},{0x56,0x64,0x4b},{0x57,0x65,0x4c},{0x58,0x66,0x4d},
        {0x59,0x67,0x47},{0x5b,0x68,0x48},{0x5c,0x69,0x49},
        {0x60,0x74,0x3f},{0x61,0x75,0x40},{0x62,0x76,0x41},{0x63,0x72,0x3d},{0x64,0x77,0x42},{0x65,0x78,0x43},{0x67,0x7a,0x57},
        {0x6d,0x79,0x44},{0x6f,0x7b,0x58},{0x76,0x73,0x3e},{0x78,0x71,0x3c},{0x7a,0x70,0x3b},{0x60,0x74,0x3f},
        {0x72,0x2d,0x100|0x52},{0x73,0x24,0x100|0x47},{0x74,0x21,0x100|0x49},{0x75,0x2e,0x100|0x53},{0x77,0x23,0x100|0x4f},{0x79,0x22,0x100|0x51},
        {0x7b,0x25,0x100|0x4b},{0x7c,0x27,0x100|0x4d},{0x7d,0x28,0x100|0x50},{0x7e,0x26,0x100|0x48},
    };
    for (size_t i = 0; i < sizeof k / sizeof *k; i++) mac_keys[k[i].mac] = (keymap){ k[i].vk, (uint16_t)(k[i].scan & 0xff), k[i].scan >= 0x100 };
}

static void key_event(uint32_t vk, uint32_t scan, bool extended, bool down, uint32_t ch)
{
    pthread_mutex_lock(&gp_input_lock);
    bool was = gp_vk_state[vk] & 0x80;
    gp_vk_state[vk] = down ? 0x80 : 0;
    if (vk == 0x10 || vk == 0x11 || vk == 0x12) gp_vk_state[vk] = down ? 0x80 : 0;
    uint8_t dik = (uint8_t)(extended ? (scan | 0x80) : scan);
    bool dik_was = gp_dik_state[dik] & 0x80;
    gp_dik_state[dik] = down ? 0x80 : 0;
    if (dik_was != down) gp_dinput_key(dik, down);            /* DirectInput reports changes, not auto-repeat */
    pthread_mutex_unlock(&gp_input_lock);
    if (!game_hwnd) return;
    uint32_t lp = 1u | (scan << 16) | (extended ? 1u << 24 : 0) | (was ? 1u << 30 : 0) | (down ? 0 : 3u << 30);
    post(game_hwnd, down ? WM_KEYDOWN : WM_KEYUP, vk, lp);
    if (down && ch) post(game_hwnd, WM_CHAR, ch, lp);
}

/* --------------------------------------------------------- AppKit */
@implementation GPView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }
- (CALayer *)makeBackingLayer { return [CAMetalLayer layer]; }
@end

@interface GPWindowDelegate : NSObject <NSWindowDelegate>
@end
@implementation GPWindowDelegate
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; if (game_hwnd) post(game_hwnd, WM_CLOSE, 0, 0); return NO; }
- (void)windowDidBecomeKey:(NSNotification *)n { (void)n; if (game_hwnd) { post(game_hwnd, WM_ACTIVATEAPP, 1, 0); post(game_hwnd, WM_ACTIVATE, 1, 0); } }
- (void)windowDidResignKey:(NSNotification *)n { (void)n; if (game_hwnd) { post(game_hwnd, WM_ACTIVATE, 0, 0); post(game_hwnd, WM_ACTIVATEAPP, 0, 0); } }
@end
static GPWindowDelegate *delegate;

static void app_init(void)
{
    static bool done;
    if (done || gp_headless()) return;
    done = true;
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp finishLaunching];
    delegate = [GPWindowDelegate new];
}

/* the launcher and the game share one NSApplication */
void gp_app_init(void) { app_init(); }

static void handle_ns_event(NSEvent *e)
{
    init_keys();
    switch (e.type) {
    case NSEventTypeKeyDown: case NSEventTypeKeyUp: {
        if (e.keyCode == 111 && getenv("GP_AUDIO_AB")) {        /* F12: audio A/B test, the title shows the mode */
            if (e.type == NSEventTypeKeyDown && !e.isARepeat) {
                extern const char *gp_ds_debug_step(void);
                NSString *mode = @(gp_ds_debug_step());
                for (int i = 0; i < MAX_WINDOWS; i++) if (windows[i].used && windows[i].ns) windows[i].ns.title = [NSString stringWithFormat:@"F.E.A.R. [%@]", mode];
            }
            return;
        }
        keymap m = e.keyCode < 128 ? mac_keys[e.keyCode] : (keymap){0};
        if (!m.vk) return;
        uint32_t ch = 0;
        if (e.type == NSEventTypeKeyDown && e.characters.length == 1) {
            unichar u = [e.characters characterAtIndex:0];
            if (u < 0xf700) ch = u == 0x7f ? 8 : u;   /* skip function-key private-use codes */
        }
        key_event(m.vk, m.scan, m.extended, e.type == NSEventTypeKeyDown, ch);
        return;                                      /* never forward to AppKit: no system beep */
    }
    case NSEventTypeFlagsChanged: {
        keymap m = e.keyCode < 128 ? mac_keys[e.keyCode] : (keymap){0};
        if (!m.vk) break;
        NSEventModifierFlags f = e.modifierFlags;
        bool down = (m.vk == 0x10 && (f & NSEventModifierFlagShift)) || (m.vk == 0x11 && (f & NSEventModifierFlagControl)) ||
                    (m.vk == 0x12 && (f & NSEventModifierFlagOption)) || (m.vk == 0x14 && (f & NSEventModifierFlagCapsLock)) ||
                    (m.vk == 0x5b && (f & NSEventModifierFlagCommand));
        key_event(m.vk, m.scan, m.extended, down, 0);
        break;
    }
    case NSEventTypeMouseMoved: case NSEventTypeLeftMouseDragged: case NSEventTypeRightMouseDragged: case NSEventTypeOtherMouseDragged:
        pthread_mutex_lock(&gp_input_lock);
        gp_mouse_dx += (int32_t)e.deltaX; gp_mouse_dy += (int32_t)e.deltaY;
        if ((int32_t)e.deltaX) gp_dinput_mouse(0, (uint32_t)(int32_t)e.deltaX);    /* DIMOFS_X */
        if ((int32_t)e.deltaY) gp_dinput_mouse(4, (uint32_t)(int32_t)e.deltaY);    /* DIMOFS_Y */
        pthread_mutex_unlock(&gp_input_lock);
        break;
    case NSEventTypeLeftMouseDown: case NSEventTypeLeftMouseUp:
    case NSEventTypeRightMouseDown: case NSEventTypeRightMouseUp:
    case NSEventTypeOtherMouseDown: case NSEventTypeOtherMouseUp: {
        bool down = e.type == NSEventTypeLeftMouseDown || e.type == NSEventTypeRightMouseDown || e.type == NSEventTypeOtherMouseDown;
        NSInteger b = e.buttonNumber;
        if (b >= 0 && b < 8) {
            pthread_mutex_lock(&gp_input_lock);
            gp_mouse_buttons[b] = down ? 0x80 : 0;
            gp_dinput_mouse(12 + (uint32_t)b, down ? 0x80 : 0);                    /* DIMOFS_BUTTON0.. */
            pthread_mutex_unlock(&gp_input_lock);
        }
        static const uint8_t vk[3] = { 0x01, 0x02, 0x04 };
        if (b < 3) gp_vk_state[vk[b]] = down ? 0x80 : 0;
        break;
    }
    case NSEventTypeScrollWheel:
        pthread_mutex_lock(&gp_input_lock);
        {
            int32_t dz = (int32_t)(e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 120));
            gp_mouse_dz += dz;
            if (dz) gp_dinput_mouse(8, (uint32_t)dz);                              /* DIMOFS_Z */
        }
        pthread_mutex_unlock(&gp_input_lock);
        break;
    default: break;
    }
    [NSApp sendEvent:e];
}

/* headless input script on stdin: "down <scan>" / "up <scan>" (hex or decimal) */
static void pump_stdin(void)
{
    static char buf[4096];
    static size_t len;
    static bool nonblock;
    if (!nonblock) { fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK); nonblock = true; }
    ssize_t n = read(0, buf + len, sizeof buf - 1 - len);
    if (n > 0) len += (size_t)n;
    char *nl;
    while ((nl = memchr(buf, '\n', len))) {
        *nl = 0;
        char verb[16]; unsigned scan;
        if (sscanf(buf, "%15s %i", verb, (int *)&scan) == 2) {
            init_keys();
            uint32_t vk = 0;
            for (int i = 0; i < 128; i++) if (mac_keys[i].scan == (scan & 0x7f) && mac_keys[i].extended == !!(scan & 0x80)) vk = mac_keys[i].vk;
            key_event(vk, scan & 0x7f, scan & 0x80, !strcmp(verb, "down"), 0);
        }
        len -= (size_t)(nl + 1 - buf);
        memmove(buf, nl + 1, len);
    }
}

/* injection for the controller emulation: the same paths real host events take */
void gp_inject_key(uint8_t scan, bool extended, bool down)
{
    init_keys();
    uint32_t vk = 0;
    for (int i = 0; i < 128; i++) if (mac_keys[i].scan == scan && mac_keys[i].extended == extended) vk = mac_keys[i].vk;
    if (!vk) gp_fatal("controller emulation: no virtual key for scan code 0x%02x%s", scan, extended ? " (extended)" : "");
    key_event(vk, scan, extended, down, 0);
}
void gp_inject_mouse_move(int dx, int dy)
{
    pthread_mutex_lock(&gp_input_lock);
    gp_mouse_dx += dx; gp_mouse_dy += dy;
    if (dx) gp_dinput_mouse(0, (uint32_t)dx);
    if (dy) gp_dinput_mouse(4, (uint32_t)dy);
    pthread_mutex_unlock(&gp_input_lock);
}
void gp_inject_mouse_button(int b, bool down)
{
    if (b < 0 || b >= 8) return;
    pthread_mutex_lock(&gp_input_lock);
    gp_mouse_buttons[b] = down ? 0x80 : 0;
    gp_dinput_mouse(12 + (uint32_t)b, down ? 0x80 : 0);
    pthread_mutex_unlock(&gp_input_lock);
    static const uint8_t vk[3] = { 0x01, 0x02, 0x04 };
    if (b < 3) gp_vk_state[vk[b]] = down ? 0x80 : 0;
}
void gp_inject_wheel(int delta)
{
    pthread_mutex_lock(&gp_input_lock);
    gp_mouse_dz += delta;
    gp_dinput_mouse(8, (uint32_t)delta);
    pthread_mutex_unlock(&gp_input_lock);
}

void gp_pump_events(void)
{
    gp_pad_emulate();
    if (gp_headless()) { pump_stdin(); return; }
    app_init();
    @autoreleasepool {
        NSEvent *e;
        while ((e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:nil inMode:NSDefaultRunLoopMode dequeue:YES]))
            handle_ns_event(e);
    }
}

/* ------------------------------------------------------ window API */
static uint32_t CreateWindowExA_(gp_thread *t)
{
    /* (exstyle, class, title, style, x, y, w, h, parent, menu, instance, param) */
    uint16_t cname[64];
    gaddr cn = A(1);
    wclass *c = NULL;
    if (cn < 0x10000) { for (int i = 0; i < nclasses; i++) if (classes[i].atom == cn) c = &classes[i]; }
    else { guest_astr_w(cn, cname, 64); for (int i = 0; i < nclasses; i++) if (weq(classes[i].name, cname)) c = &classes[i]; }
    if (!c) gp_fatal("CreateWindowExA: class \"%s\" is not registered", cn >= 0x10000 ? gstr(cn) : "#atom");
    uint32_t i = 0;
    while (i < MAX_WINDOWS && windows[i].used) i++;
    if (i == MAX_WINDOWS) gp_fatal("too many windows");
    gwin *w = &windows[i];
    *w = (gwin){0};
    w->used = true; w->hwnd = HWND_BASE + 4 * i; w->cls = c; w->proc = c->proc;
    w->exstyle = A(0); w->style = A(3); w->parent = A(8);
    w->id = A(9); w->instance = A(10);
    w->x = (int32_t)A(4); w->y = (int32_t)A(5); w->w = (int32_t)A(6); w->h = (int32_t)A(7);
    if (w->x == (int32_t)0x80000000) w->x = w->y = 0;
    if (w->w == (int32_t)0x80000000) { w->w = 640; w->h = 480; }
    if (!game_hwnd && !(w->style & 0x40000000u)) game_hwnd = w->hwnd;   /* first top-level window */
    gp_log("CreateWindowExA \"%s\" %dx%d style 0x%x -> hwnd 0x%x", gstr(A(2)) ? gstr(A(2)) : "", w->w, w->h, w->style, w->hwnd);
    if (!gp_headless()) {
        app_init();
        NSWindowStyleMask sm = (w->style & 0x00C00000u) ? (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable)
                                                         : NSWindowStyleMaskBorderless;
        NSSize pts = fit_points(w->w, w->h);
        w->ns = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, pts.width, pts.height) styleMask:sm backing:NSBackingStoreBuffered defer:NO];
        w->ns.title = [NSString stringWithCString:(gstr(A(2)) ? gstr(A(2)) : "F.E.A.R.") encoding:NSWindowsCP1252StringEncoding];
        w->ns.delegate = delegate;
        w->ns.acceptsMouseMovedEvents = YES;
        w->view = [[GPView alloc] initWithFrame:NSMakeRect(0, 0, pts.width, pts.height)];
        w->view.wantsLayer = YES;
        w->layer = (CAMetalLayer *)w->view.layer;
        w->ns.contentView = w->view;
        [w->ns center];
    }
    /* creation messages, synchronously like Windows */
    gaddr cs = gp_heap_alloc(48, true);
    wr32(cs, A(11)); wr32(cs + 4, A(10)); wr32(cs + 8, A(9)); wr32(cs + 12, A(8));
    wr32(cs + 16, (uint32_t)w->h); wr32(cs + 20, (uint32_t)w->w); wr32(cs + 24, (uint32_t)w->y); wr32(cs + 28, (uint32_t)w->x);
    wr32(cs + 32, w->style); wr32(cs + 36, A(2)); wr32(cs + 40, A(1)); wr32(cs + 44, w->exstyle);
    uint32_t h = w->hwnd;
    if (!send_msg(h, WM_NCCREATE, 0, cs)) { gp_heap_free(cs); w->used = false; set_error(t, 1400); return 0; }
    if ((int32_t)send_msg(h, WM_CREATE, 0, cs) == -1) { gp_heap_free(cs); w->used = false; return 0; }
    gp_heap_free(cs);
    if (w->style & 0x10000000u) {                     /* WS_VISIBLE */
        w->visible = true;
        if (w->ns) [w->ns makeKeyAndOrderFront:nil];
    }
    return h;
}

static uint32_t DefWindowProcW_(gp_thread *t)
{
    uint32_t h = A(0), msg = A(1);
    switch (msg) {
    case WM_NCCREATE: return 1;
    case WM_CLOSE: {
        extern uint32_t gp_destroy_window(uint32_t);
        gp_destroy_window(h);
        return 0;
    }
    case WM_ERASEBKGND: return 1;
    case WM_NCACTIVATE: return 1;
    case WM_SETCURSOR: return 0;
    case WM_SYSCOMMAND: return 0;
    case WM_GETMINMAXINFO: case WM_WINDOWPOSCHANGING: case WM_WINDOWPOSCHANGED: return 0;
    case WM_PAINT: return 0;
    default: return 0;
    }
}

static uint32_t CallWindowProcW_(gp_thread *t) { return call_proc(A(0), A(1), A(2), A(3), A(4)); }

uint32_t gp_destroy_window(uint32_t h)
{
    gwin *w = win(h);
    if (!w) return 0;
    send_msg(h, WM_DESTROY, 0, 0);
    send_msg(h, WM_NCDESTROY, 0, 0);
    if (w->ns) { [w->ns orderOut:nil]; w->ns = nil; w->view = nil; w->layer = nil; }
    *w = (gwin){0};
    if (h == game_hwnd) game_hwnd = 0;
    return 1;
}
static uint32_t DestroyWindow_(gp_thread *t) { return gp_destroy_window(A(0)); }

static uint32_t ShowWindow_(gp_thread *t)
{
    gwin *w = win(A(0));
    if (!w) return 0;
    bool was = w->visible;
    w->visible = A(1) != 0;
    if (w->ns) { if (w->visible) { [w->ns makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; } else [w->ns orderOut:nil]; }
    return was;
}
static uint32_t UpdateWindow_(gp_thread *t) { if (!win(A(0))) return 0; send_msg(A(0), WM_PAINT, 0, 0); return 1; }
static uint32_t IsWindow_(gp_thread *t) { return win(A(0)) != NULL || A(0) == desktop_hwnd; }
static uint32_t IsIconic_(gp_thread *t) { gwin *w = win(A(0)); return w && w->ns && w->ns.miniaturized; }
static uint32_t GetDesktopWindow_(gp_thread *t) { (void)t; return desktop_hwnd; }
static uint32_t GetForegroundWindow_(gp_thread *t) { (void)t; return game_hwnd; }
static uint32_t SetForegroundWindow_(gp_thread *t) { gwin *w = win(A(0)); if (w && w->ns) [NSApp activateIgnoringOtherApps:YES]; return w != NULL; }
static uint32_t SetFocus_(gp_thread *t) { (void)t; return game_hwnd; }
static uint32_t FindWindowA_(gp_thread *t)
{
    /* SndDrv looks for the game window by class/title; there is only one */
    (void)t;
    return game_hwnd;
}

static void write_rect(gaddr r, int32_t l, int32_t tp, int32_t rt, int32_t b)
{ wr32(r, (uint32_t)l); wr32(r + 4, (uint32_t)tp); wr32(r + 8, (uint32_t)rt); wr32(r + 12, (uint32_t)b); }

static uint32_t GetClientRect_(gp_thread *t)
{
    uint32_t cw, ch;
    if (A(0) == desktop_hwnd) gp_display_size(&cw, &ch);
    else { gwin *w = win(A(0)); if (!w) { set_error(t, 1400); return 0; } client_size(w, &cw, &ch); }
    write_rect(A(1), 0, 0, (int32_t)cw, (int32_t)ch);
    return 1;
}
static uint32_t GetWindowRect_(gp_thread *t)
{
    if (A(0) == desktop_hwnd) { uint32_t dw, dh; gp_display_size(&dw, &dh); write_rect(A(1), 0, 0, (int32_t)dw, (int32_t)dh); return 1; }
    gwin *w = win(A(0));
    if (!w) { set_error(t, 1400); return 0; }
    write_rect(A(1), w->x, w->y, w->x + w->w, w->y + w->h);
    return 1;
}
static uint32_t AdjustWindowRect_(gp_thread *t)
{
    /* The game window is borderless (WS_POPUP) in practice; a captioned style gets
       the XP classic frame metrics so the client area keeps the requested size. */
    uint32_t style = A(1);
    if (style & 0x00C00000u) {
        gaddr r = A(0);
        write_rect(r, (int32_t)rd32(r) - 3, (int32_t)rd32(r + 4) - 22, (int32_t)rd32(r + 8) + 3, (int32_t)rd32(r + 12) + 3);
    }
    return 1;
}
static uint32_t SetWindowPos_(gp_thread *t)
{
    /* (hwnd, after, x, y, cx, cy, flags) */
    gwin *w = win(A(0));
    if (!w) { set_error(t, 1400); return 0; }
    uint32_t flags = A(6);
    if (!(flags & 0x2)) { w->x = (int32_t)A(2); w->y = (int32_t)A(3); }    /* SWP_NOMOVE */
    if (!(flags & 0x1)) {                                                    /* SWP_NOSIZE */
        w->w = (int32_t)A(4); w->h = (int32_t)A(5);
        if (w->ns) { [w->ns setContentSize:fit_points(w->w, w->h)]; [w->ns center]; }
        post(A(0), WM_SIZE, 0, ((uint32_t)w->h << 16) | ((uint32_t)w->w & 0xffff));
    }
    if (flags & 0x40) { w->visible = true; if (w->ns) [w->ns makeKeyAndOrderFront:nil]; }   /* SWP_SHOWWINDOW */
    return 1;
}
static uint32_t ClientToScreen_(gp_thread *t)
{
    gwin *w = win(A(0));
    if (!w) return 0;
    wr32(A(1), rd32(A(1)) + (uint32_t)w->x); wr32(A(1) + 4, rd32(A(1) + 4) + (uint32_t)w->y);
    return 1;
}
static uint32_t ScreenToClient_(gp_thread *t)
{
    gwin *w = win(A(0));
    if (!w) return 0;
    wr32(A(1), rd32(A(1)) - (uint32_t)w->x); wr32(A(1) + 4, rd32(A(1) + 4) - (uint32_t)w->y);
    return 1;
}
static uint32_t GetWindowLongW_(gp_thread *t)
{
    gwin *w = win(A(0));
    if (!w) { set_error(t, 1400); return 0; }
    switch ((int32_t)A(1)) {
    case -4: return w->proc;          /* GWL_WNDPROC */
    case -16: return w->style;
    case -20: return w->exstyle;
    case -21: return w->userdata;
    case -6: return w->instance;      /* GWL_HINSTANCE */
    case -8: return w->parent;        /* GWL_HWNDPARENT */
    case -12: return w->id;           /* GWL_ID */
    }
    gp_fatal("GetWindowLongW index %d", (int32_t)A(1));
}
static uint32_t SetWindowLongW_(gp_thread *t)
{
    gwin *w = win(A(0));
    if (!w) { set_error(t, 1400); return 0; }
    uint32_t old;
    switch ((int32_t)A(1)) {
    case -4: old = w->proc; w->proc = A(2); return old;
    case -16: old = w->style; w->style = A(2); return old;
    case -20: old = w->exstyle; w->exstyle = A(2); return old;
    case -21: old = w->userdata; w->userdata = A(2); return old;
    }
    gp_fatal("SetWindowLongW index %d", (int32_t)A(1));
}


/* ---------------------------------------------------------- window enumeration and metrics */
static gwin *first_toplevel(void) { for (int i = 0; i < MAX_WINDOWS; i++) if (windows[i].used && !windows[i].parent) return &windows[i]; return NULL; }
static uint32_t GetTopWindow_(gp_thread *t)
{
    (void)t;
    if (!A(0)) { gwin *w = win(game_hwnd) ? win(game_hwnd) : first_toplevel(); return w ? w->hwnd : 0; }
    for (int i = 0; i < MAX_WINDOWS; i++) if (windows[i].used && windows[i].parent == A(0)) return windows[i].hwnd;
    return 0;
}
static uint32_t GetWindow_(gp_thread *t)
{
    /* siblings are in creation order: GW_HWNDFIRST 0, LAST 1, NEXT 2, PREV 3, OWNER 4, CHILD 5 */
    gwin *w = win(A(0));
    uint32_t cmd = A(1);
    if (!w) { set_error(t, 1400); return 0; }
    int self = (int)(w - windows), found = -1;
    switch (cmd) {
    case 0: for (int i = 0; i < MAX_WINDOWS && found < 0; i++) if (windows[i].used && windows[i].parent == w->parent) found = i; break;
    case 1: for (int i = MAX_WINDOWS - 1; i >= 0 && found < 0; i--) if (windows[i].used && windows[i].parent == w->parent) found = i; break;
    case 2: for (int i = self + 1; i < MAX_WINDOWS && found < 0; i++) if (windows[i].used && windows[i].parent == w->parent) found = i; break;
    case 3: for (int i = self - 1; i >= 0 && found < 0; i--) if (windows[i].used && windows[i].parent == w->parent) found = i; break;
    case 4: return 0;                                             /* windows here have no owners */
    case 5: for (int i = 0; i < MAX_WINDOWS && found < 0; i++) if (windows[i].used && windows[i].parent == w->hwnd) found = i; break;
    default: gp_fatal("GetWindow: command %u", cmd);
    }
    return found < 0 ? 0 : windows[found].hwnd;
}
static uint32_t GetWindowThreadProcessId_(gp_thread *t)
{
    /* every window is created by the guest's main thread */
    if (!win(A(0))) { set_error(t, 1400); return 0; }
    if (A(1)) wr32(A(1), (uint32_t)getpid());
    return gp_main_thread_id();
}
static uint32_t GetActiveWindow_(gp_thread *t) { (void)t; return game_hwnd; }
static uint32_t IsWindowVisible_(gp_thread *t)
{
    (void)t;
    for (gwin *w = win(A(0)); w; w = win(w->parent)) if (!w->visible) return 0;
    return win(A(0)) != NULL;
}
static uint32_t GetClassLongA_(gp_thread *t)
{
    gwin *w = win(A(0));
    if (!w) { set_error(t, 1400); return 0; }
    switch ((int32_t)A(1)) {
    case -26: return w->cls->style;                               /* GCL_STYLE */
    case -24: return w->cls->proc;                                /* GCL_WNDPROC */
    case -16: return w->cls->instance;                            /* GCL_HMODULE */
    case -14: return w->cls->icon;                                /* GCL_HICON */
    case -12: return w->cls->cursor;                              /* GCL_HCURSOR */
    case -10: return w->cls->background;                          /* GCL_HBRBACKGROUND */
    }
    gp_fatal("GetClassLongA index %d", (int32_t)A(1));
}
static uint32_t GetCursorPos_(gp_thread *t)
{
    (void)t;
    int32_t x = 0, y = 0;
    if (!gp_headless()) {
        NSPoint p = NSEvent.mouseLocation;
        x = (int32_t)p.x; y = (int32_t)(NSScreen.screens[0].frame.size.height - p.y);   /* Win32: origin top-left */
    }
    wr32(A(0), (uint32_t)x); wr32(A(0) + 4, (uint32_t)y);
    return 1;
}
static uint32_t GetSystemMetrics_(gp_thread *t)
{
    (void)t;
    uint32_t sw, sh;
    gp_display_size(&sw, &sh);
    switch (A(0)) {
    case 0: return sw;                                            /* SM_CXSCREEN */
    case 1: return sh;                                            /* SM_CYSCREEN */
    case 4: return 19;                                            /* SM_CYCAPTION */
    case 5: case 6: return 1;                                     /* SM_CXBORDER, SM_CYBORDER */
    case 7: case 8: return 3;                                     /* SM_CXDLGFRAME, SM_CYDLGFRAME */
    case 15: return 19;                                           /* SM_CYMENU */
    case 32: case 33: return 4;                                   /* SM_CXFRAME, SM_CYFRAME */
    case 76: case 77: return 0;                                   /* SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN */
    case 78: return sw;                                           /* SM_CXVIRTUALSCREEN */
    case 79: return sh;                                           /* SM_CYVIRTUALSCREEN */
    case 80: return 1;                                            /* SM_CMONITORS */
    }
    gp_fatal("GetSystemMetrics(%u)", A(0));
}

static uint32_t BeginPaint_(gp_thread *t) { memset(G(A(1)), 0, 64); wr32(A(1), 0x00020001u); return 0x00020001u; }
static uint32_t EndPaint_(gp_thread *t) { (void)t; return 1; }

/* ---------------------------------------------------------- messages */
static uint32_t peek(gp_thread *t, bool unicode)
{
    (void)unicode;
    gaddr m = A(0);
    uint32_t hwnd = A(1), lo = A(2), hi = A(3), remove = A(4) & 1;
    gp_pump_events();
    for (uint32_t i = qhead; i != qtail; i++) {
        qmsg q = queue[i % QSIZE];
        if (hwnd && q.hwnd != hwnd) continue;
        if ((lo || hi) && (q.msg < lo || q.msg > hi)) continue;
        wr32(m, q.hwnd); wr32(m + 4, q.msg); wr32(m + 8, q.wparam); wr32(m + 12, q.lparam); wr32(m + 16, q.time);
        wr32(m + 20, 0); wr32(m + 24, 0);
        if (remove) {
            for (uint32_t j = i; j != qhead; j--) queue[j % QSIZE] = queue[(j - 1) % QSIZE];
            qhead++;
        }
        return 1;
    }
    if (quit_posted && (!lo || lo <= WM_QUIT)) {
        wr32(m, 0); wr32(m + 4, WM_QUIT); wr32(m + 8, quit_code); wr32(m + 12, 0);
        if (remove) quit_posted = false;
        return 1;
    }
    return 0;
}
static uint32_t PeekMessageA_(gp_thread *t) { return peek(t, false); }
static uint32_t PeekMessageW_(gp_thread *t) { return peek(t, true); }
static uint32_t TranslateMessage_(gp_thread *t) { (void)t; return 0; }   /* WM_CHAR is produced with the key event */
static uint32_t DispatchMessageW_(gp_thread *t)
{
    gaddr m = A(0);
    uint32_t h = rd32(m);
    if (!h || !win(h)) return 0;
    return send_msg(h, rd32(m + 4), rd32(m + 8), rd32(m + 12));
}
static uint32_t PostQuitMessage_(gp_thread *t) { quit_posted = true; quit_code = A(0); return 0; }
static uint32_t SendMessageA_(gp_thread *t) { return send_msg(A(0), A(1), A(2), A(3)); }
static uint32_t SendMessageTimeoutA_(gp_thread *t)
{
    uint32_t r = send_msg(A(0), A(1), A(2), A(3));
    if (A(6)) wr32(A(6), r);
    return 1;
}

/* ------------------------------------------------------------- hooks */
static uint32_t SetWindowsHookExA_(gp_thread *t)
{
    /* FEAR installs a low-level keyboard hook to swallow the Windows keys; macOS
       has no such keys to swallow, so the hook is registered but never called. */
    gp_log("SetWindowsHookExA(id %d)", (int32_t)A(0));
    return 0x00030001u;
}
static uint32_t UnhookWindowsHookEx_(gp_thread *t) { (void)t; return 1; }
static uint32_t CallNextHookEx_(gp_thread *t) { (void)t; return 0; }

/* ------------------------------------------------------------ cursor */
static int32_t cursor_count;
static uint32_t ShowCursor_(gp_thread *t)
{
    int32_t before = cursor_count;
    cursor_count += A(0) ? 1 : -1;
    if (!gp_headless()) {
        if (before >= 0 && cursor_count < 0) [NSCursor hide];
        if (before < 0 && cursor_count >= 0) [NSCursor unhide];
    }
    return (uint32_t)cursor_count;
}
static uint32_t SetCursor_(gp_thread *t) { static uint32_t cur; uint32_t o = cur; cur = A(0); (void)t; return o; }
static uint32_t LoadCursorA_(gp_thread *t) { return 0x00040000u | (A(1) & 0xffff); }
static uint32_t LoadIconA_(gp_thread *t) { return 0x00050000u | (A(1) & 0xffff); }
static uint32_t LoadImageA_(gp_thread *t) { return 0x00060000u | (A(1) & 0xffff); }
static uint32_t DestroyCursor_(gp_thread *t) { (void)t; return 1; }
static uint32_t SetCursorPos_(gp_thread *t)
{
    /* the game recentres the pointer for mouse look; host relative motion comes from event deltas */
    if (!gp_headless()) CGWarpMouseCursorPosition(CGPointMake((CGFloat)(int32_t)A(0), (CGFloat)(int32_t)A(1)));
    return 1;
}
static uint32_t ClipCursor_(gp_thread *t)
{
    if (!gp_headless()) CGAssociateMouseAndMouseCursorPosition(A(0) ? false : true);   /* clip = capture */
    return 1;
}

/* ---------------------------------------------------------- keyboard */
static uint32_t GetAsyncKeyState_(gp_thread *t)
{
    gp_pump_events();
    return (gp_vk_state[A(0) & 0xff] & 0x80) ? 0x8000u : 0;
}
static uint32_t GetKeyboardState_(gp_thread *t) { memcpy(G(A(0)), gp_vk_state, 256); return 1; }
static uint32_t ToAscii_(gp_thread *t)
{
    /* (vk, scan, keystate, lpChar, flags): US layout */
    uint32_t vk = A(0);
    bool shift = rd8(A(2) + 0x10) & 0x80;
    int c = 0;
    if (vk >= 'A' && vk <= 'Z') c = shift ? (int)vk : (int)vk + 32;
    else if (vk >= '0' && vk <= '9') c = shift ? ")!@#$%^&*("[vk - '0'] : (int)vk;
    else if (vk == ' ' || vk == 0x0d || vk == 0x08 || vk == 0x1b || vk == 0x09) c = (int)vk;
    else {
        static const struct { uint8_t vk; char n, s; } p[] = { {0xba,';',':'},{0xbb,'=','+'},{0xbc,',','<'},{0xbd,'-','_'},
            {0xbe,'.','>'},{0xbf,'/','?'},{0xc0,'`','~'},{0xdb,'[','{'},{0xdc,'\\','|'},{0xdd,']','}'},{0xde,'\'','"'} };
        for (size_t i = 0; i < sizeof p / sizeof *p; i++) if (p[i].vk == vk) c = shift ? p[i].s : p[i].n;
    }
    if (!c) return 0;
    wr16(A(3), (uint16_t)c);
    return 1;
}

/* ------------------------------------------------------------- misc */
static uint32_t SystemParametersInfoA_(gp_thread *t)
{
    uint32_t action = A(0);
    switch (action) {
    case 0x10: if (A(2)) wr32(A(2), 0); return 1;              /* SPI_GETSCREENSAVEACTIVE */
    case 0x11: return 1;                                        /* SPI_SETSCREENSAVEACTIVE */
    case 0x30: { uint32_t w, h; gp_display_size(&w, &h); write_rect(A(2), 0, 0, (int32_t)w, (int32_t)h); return 1; }  /* SPI_GETWORKAREA */
    case 0x3a: case 0x34: case 0x32: case 0x3b: case 0x35: case 0x33:                  /* sticky/toggle/filter keys get/set */
        if (action & 1) return 1;
        if (A(2)) { uint32_t cb = rd32(A(2)); memset(G(A(2) + 4), 0, cb > 4 ? cb - 4 : 0); }
        return 1;
    }
    gp_fatal("SystemParametersInfoA action 0x%x", action);
}

static uint32_t message_box(const char *text, const char *caption, uint32_t type)
{
    gp_log("MessageBox [%s]: %s", caption ? caption : "", text ? text : "");
    if (!gp_headless()) {
        app_init();
        NSAlert *a = [NSAlert new];
        a.messageText = caption ? [NSString stringWithCString:caption encoding:NSWindowsCP1252StringEncoding] : @"F.E.A.R.";
        a.informativeText = text ? [NSString stringWithCString:text encoding:NSWindowsCP1252StringEncoding] : @"";
        uint32_t kind = type & 0xf;
        if (kind == 4 || kind == 3) { [a addButtonWithTitle:@"Yes"]; [a addButtonWithTitle:@"No"]; }
        else if (kind == 1) { [a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Cancel"]; }
        else [a addButtonWithTitle:@"OK"];
        NSModalResponse r = [a runModal];
        if (kind == 4 || kind == 3) return r == NSAlertFirstButtonReturn ? 6 : 7;
        if (kind == 1) return r == NSAlertFirstButtonReturn ? 1 : 2;
        return 1;
    }
    uint32_t kind = type & 0xf;
    return (kind == 4 || kind == 3) ? 7 : 1;     /* headless: "No" for questions, OK otherwise */
}
static uint32_t MessageBoxA_(gp_thread *t) { return message_box(gstr(A(1)), gstr(A(2)), A(3)); }
static uint32_t MessageBoxW_(gp_thread *t)
{
    char text[2048] = "", cap[256] = "";
    for (uint32_t i = 0; A(1) && i + 1 < sizeof text && rd16(A(1) + 2 * i); i++) { int c = gp_wc_to_cp1252(rd16(A(1) + 2 * i)); text[i] = (char)(c < 0 ? '?' : c); text[i + 1] = 0; }
    for (uint32_t i = 0; A(2) && i + 1 < sizeof cap && rd16(A(2) + 2 * i); i++) { int c = gp_wc_to_cp1252(rd16(A(2) + 2 * i)); cap[i] = (char)(c < 0 ? '?' : c); cap[i + 1] = 0; }
    return message_box(text, cap, A(3));
}

const gp_api gp_api_user32[] = {
    API(RegisterClassW_, "RegisterClassW", 1), API(CreateWindowExA_, "CreateWindowExA", 12),
    API(DefWindowProcW_, "DefWindowProcW", 4), API(CallWindowProcW_, "CallWindowProcW", 5),
    API(DestroyWindow_, "DestroyWindow", 1), API(ShowWindow_, "ShowWindow", 2), API(UpdateWindow_, "UpdateWindow", 1),
    API(IsWindow_, "IsWindow", 1), API(IsIconic_, "IsIconic", 1), API(GetDesktopWindow_, "GetDesktopWindow", 0),
    API(GetForegroundWindow_, "GetForegroundWindow", 0), API(SetForegroundWindow_, "SetForegroundWindow", 1),
    API(SetFocus_, "SetFocus", 1), API(FindWindowA_, "FindWindowA", 2),
    API(GetClientRect_, "GetClientRect", 2), API(GetWindowRect_, "GetWindowRect", 2), API(AdjustWindowRect_, "AdjustWindowRect", 3),
    API(SetWindowPos_, "SetWindowPos", 7), API(ClientToScreen_, "ClientToScreen", 2), API(ScreenToClient_, "ScreenToClient", 2),
    API(GetTopWindow_, "GetTopWindow", 1), API(GetWindow_, "GetWindow", 2), API(GetWindowThreadProcessId_, "GetWindowThreadProcessId", 2),
    API(GetActiveWindow_, "GetActiveWindow", 0), API(IsWindowVisible_, "IsWindowVisible", 1), API(GetClassLongA_, "GetClassLongA", 2),
    API(GetCursorPos_, "GetCursorPos", 1), API(GetSystemMetrics_, "GetSystemMetrics", 1), API(GetWindowLongW_, "GetWindowLongA", 2),
    API(GetWindowLongW_, "GetWindowLongW", 2), API(SetWindowLongW_, "SetWindowLongW", 3),
    API(BeginPaint_, "BeginPaint", 2), API(EndPaint_, "EndPaint", 2),
    API(PeekMessageA_, "PeekMessageA", 5), API(PeekMessageW_, "PeekMessageW", 5), API(TranslateMessage_, "TranslateMessage", 1),
    API(DispatchMessageW_, "DispatchMessageW", 1), API(PostQuitMessage_, "PostQuitMessage", 1),
    API(SendMessageA_, "SendMessageA", 4), API(SendMessageTimeoutA_, "SendMessageTimeoutA", 7),
    API(SetWindowsHookExA_, "SetWindowsHookExA", 4), API(UnhookWindowsHookEx_, "UnhookWindowsHookEx", 1),
    API(CallNextHookEx_, "CallNextHookEx", 4),
    API(ShowCursor_, "ShowCursor", 1), API(SetCursor_, "SetCursor", 1), API(LoadCursorA_, "LoadCursorA", 2),
    API(LoadIconA_, "LoadIconA", 2), API(LoadImageA_, "LoadImageA", 6), API(DestroyCursor_, "DestroyCursor", 1),
    API(SetCursorPos_, "SetCursorPos", 2), API(ClipCursor_, "ClipCursor", 1),
    API(GetAsyncKeyState_, "GetAsyncKeyState", 1), API(GetKeyboardState_, "GetKeyboardState", 1), API(ToAscii_, "ToAscii", 5),
    API(SystemParametersInfoA_, "SystemParametersInfoA", 4),
    API(MessageBoxA_, "MessageBoxA", 4), API(MessageBoxW_, "MessageBoxW", 4),
    { 0 }
};
