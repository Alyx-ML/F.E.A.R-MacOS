/* dinput8.dll: IDirectInput8A with the system keyboard and mouse.
 * Immediate state and buffered data come from host input events (gp_window.m). */
#include "gp_api.h"
#include "gp_win.h"
#include "gp_window.h"
#include "gp_gamepad.h"
#include <stdlib.h>
#include <string.h>
#include <ApplicationServices/ApplicationServices.h>

#define DI_OK 0
#define DI_BUFFEROVERFLOW 1
#define DI_NOEFFECT 1
#define DIERR_INVALIDPARAM 0x80070057u
#define DIERR_NOTACQUIRED 0x8007000Cu
#define DIERR_INPUTLOST 0x8007001Eu
#define DIERR_DEVICENOTREG 0x80040154u
#define E_NOINTERFACE 0x80004002u

static const char KEYBOARD[] = "6F1D2B61-D5A0-11CF-BFC7-444553540000";
static const char MOUSE[] = "6F1D2B60-D5A0-11CF-BFC7-444553540000";
static const char JOYSTICK[] = "6F1D2B70-D5A0-11CF-BFC7-444553540000";

/* ------------------------------------------------------ buffered events */
typedef struct { uint32_t ofs, data, time, seq; } di_event;
#define RING 1024
typedef struct {
    di_event ev[RING];
    uint32_t head, tail, capacity;     /* capacity: DIPROP_BUFFERSIZE */
    bool overflow;
} ring;
static ring kb_ring, mouse_ring, joy_ring;
static uint32_t sequence;
static bool kb_acquired, mouse_acquired, joy_acquired;

static void push(ring *r, uint32_t ofs, uint32_t data)
{
    if (!r->capacity) return;
    if (r->tail - r->head >= r->capacity || r->tail - r->head >= RING) { r->overflow = true; r->head++; }
    r->ev[r->tail++ % RING] = (di_event){ ofs, data, (uint32_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000), ++sequence };
}
/* called by the window layer with gp_input_lock held */
void gp_dinput_key(uint8_t dik, bool down) { if (kb_acquired) push(&kb_ring, dik, down ? 0x80 : 0); }
void gp_dinput_mouse(uint32_t ofs, uint32_t data) { if (mouse_acquired) push(&mouse_ring, ofs, data); }

/* ------------------------------------------------------------ objects */
enum { DEV_KEYBOARD = 1, DEV_MOUSE = 2, DEV_JOYSTICK = 3 };
/* device object: {vtable, refs, kind, data size, coop flags} */
#define DEV_KIND(o) ((o) + 8)
#define DEV_SIZE(o) ((o) + 12)
#define DEV_COOP(o) ((o) + 16)
#define DEV_FMT(o) ((o) + 20)      /* host data-format slot + 1 (0 = none) */

static const char *const di8_methods[] = { "QueryInterface", "AddRef", "Release", "CreateDevice", "EnumDevices",
    "GetDeviceStatus", "RunControlPanel", "Initialize", "FindDevice", "EnumDevicesBySemantics", "ConfigureDevices" };
static const char *const dev_methods[] = { "QueryInterface", "AddRef", "Release", "GetCapabilities", "EnumObjects",
    "GetProperty", "SetProperty", "Acquire", "Unacquire", "GetDeviceState", "GetDeviceData", "SetDataFormat",
    "SetEventNotification", "SetCooperativeLevel", "GetObjectInfo", "GetDeviceInfo", "RunControlPanel", "Initialize",
    "CreateEffect", "EnumEffects", "GetEffectInfo", "GetForceFeedbackState", "SendForceFeedbackCommand",
    "EnumCreatedEffectObjects", "Escape", "Poll", "SendDeviceData", "EnumEffectsInFile", "WriteEffectToFile",
    "BuildActionMap", "SetActionMap", "GetImageInfo" };
static gaddr di8_vt, dev_vt;

static uint32_t DirectInput8Create_(gp_thread *t)
{
    /* (hinst, version, riid, ppvOut, punkOuter) */
    if (!gp_guid_eq(A(2), "BF798030-483A-4DA2-AA99-5D64ED369700")) {   /* IID_IDirectInput8A */
        gp_log("DirectInput8Create: interface not supported");
        return E_NOINTERFACE;
    }
    if (!di8_vt) {
        di8_vt = gp_com_vtable("IDirectInput8A", di8_methods, 11);
        dev_vt = gp_com_vtable("IDirectInputDevice8A", dev_methods, 32);
    }
    wr32(A(3), gp_com_new(di8_vt, 0));
    return DI_OK;
}

static uint32_t AddRef_(gp_thread *t) { uint32_t r = rd32(A(0) + 4) + 1; wr32(A(0) + 4, r); return r; }
static uint32_t Release_(gp_thread *t)
{
    uint32_t r = rd32(A(0) + 4) - 1;
    wr32(A(0) + 4, r);
    if (!r) gp_heap_free(A(0));
    return r;
}


/* ------------------------------------------------------------ joystick (SDL3 gamepad)
   Offsets follow DIJOYSTATE: lX lY lZ lRx lRy lRz, 2 sliders, 4 POV, 32 buttons. */
#define JOY_AXIS_OFS(i) (4u * (uint32_t)(i))
#define JOY_POV_OFS 32u
#define JOY_BTN_OFS 48u
typedef struct { int32_t min, max; } axis_range;
static axis_range joy_range[GP_PAD_AXES] = { {0, 65535}, {0, 65535}, {0, 65535}, {0, 65535}, {0, 65535}, {0, 65535} };
static uint32_t joy_deadzone[GP_PAD_AXES];                 /* DIPROP_DEADZONE, 0..10000 */
static uint32_t joy_saturation[GP_PAD_AXES] = { 10000, 10000, 10000, 10000, 10000, 10000 };   /* DIPROP_SATURATION */
static int32_t joy_axis[GP_PAD_AXES], joy_pov = -1;
static uint8_t joy_button[GP_PAD_BUTTONS];
static bool joy_have_state;

/* sample the controller, scale to the ranges the game set, and queue an event for every change */
static void joy_poll(void)
{
    gp_pad_state st;
    if (!gp_pad_read(&st)) return;
    int32_t axis[GP_PAD_AXES];
    for (int i = 0; i < GP_PAD_AXES; i++) {
        int32_t raw = st.axis[i];
        int32_t dz = (int32_t)((int64_t)joy_deadzone[i] * 32768 / 10000);
        if (raw > -dz && raw < dz) raw = 0;
        int32_t sat = (int32_t)((int64_t)joy_saturation[i] * 32768 / 10000);
        if (sat > 0 && sat < 32768) { int64_t v = (int64_t)raw * 32768 / sat; raw = (int32_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v); }
        axis[i] = joy_range[i].min + (int32_t)(((int64_t)raw + 32768) * (joy_range[i].max - joy_range[i].min) / 65535);
    }
    for (int i = 0; i < GP_PAD_AXES; i++)
        if (!joy_have_state || axis[i] != joy_axis[i]) { joy_axis[i] = axis[i]; if (joy_acquired) push(&joy_ring, JOY_AXIS_OFS(i), (uint32_t)axis[i]); }
    if (!joy_have_state || st.pov != joy_pov) { joy_pov = st.pov; if (joy_acquired) push(&joy_ring, JOY_POV_OFS, (uint32_t)st.pov); }
    for (int i = 0; i < GP_PAD_BUTTONS; i++)
        if (!joy_have_state || st.button[i] != joy_button[i]) { joy_button[i] = st.button[i]; if (joy_acquired) push(&joy_ring, JOY_BTN_OFS + (uint32_t)i, st.button[i] ? 0x80 : 0); }
    if (getenv("GP_TRACE_PAD")) {
        static int shown;
        static gp_pad_state last;
        bool changed = false;
        for (int i = 0; i < GP_PAD_AXES; i++) if (abs(st.axis[i] - last.axis[i]) > 4000) changed = true;
        for (int i = 0; i < GP_PAD_BUTTONS; i++) if (st.button[i] != last.button[i]) changed = true;
        if (st.pov != last.pov) changed = true;
        if (changed && shown++ < 400) {
            gp_log("pad: axes %d %d %d %d %d, pov %d, buttons %02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x", st.axis[0], st.axis[1], st.axis[2], st.axis[3], st.axis[4], st.pov,
                   st.button[0], st.button[1], st.button[2], st.button[3], st.button[4], st.button[5], st.button[6], st.button[7], st.button[8], st.button[9], st.button[10], st.button[11], st.button[12], st.button[13]);
            last = st;
        }
    }
    joy_have_state = true;
}

static void fill_instance(gaddr p, int kind)
{
    /* DIDEVICEINSTANCEA (580 bytes) */
    memset(G(p), 0, 580);
    wr32(p, 580);
    unsigned d1, d2, d3, b[8];
    sscanf(kind == DEV_KEYBOARD ? KEYBOARD : kind == DEV_JOYSTICK ? JOYSTICK : MOUSE, "%8x-%4x-%4x-%2x%2x-%2x%2x%2x%2x%2x%2x", &d1, &d2, &d3, &b[0], &b[1], &b[2], &b[3], &b[4], &b[5], &b[6], &b[7]);
    for (int k = 0; k < 2; k++) {            /* guidInstance and guidProduct */
        gaddr g = p + 4 + 16 * (uint32_t)k;
        wr32(g, d1); wr16(g + 4, (uint16_t)d2); wr16(g + 6, (uint16_t)d3);
        for (int i = 0; i < 8; i++) wr8(g + 8 + (uint32_t)i, (uint8_t)b[i]);
    }
    wr32(p + 36, kind == DEV_KEYBOARD ? 0x0413 : kind == DEV_JOYSTICK ? 0x0115 : 0x0112);    /* DI8DEVTYPE_KEYBOARD|PCENH / GAMEPAD|STANDARD / MOUSE|UNKNOWN */
    const char *name = kind == DEV_KEYBOARD ? "Keyboard" : kind == DEV_JOYSTICK ? gp_pad_name() : "Mouse";
    strcpy((char *)G(p + 40), name);
    strcpy((char *)G(p + 300), name);
}

static uint32_t EnumDevices_(gp_thread *t)
{
    /* (this, dwDevType, callback, pvRef, flags) */
    uint32_t cls = A(1) & 0xff;
    gaddr inst = gp_heap_alloc(580, true);
    int kinds[3], n = 0;
    if (cls == 0 || cls == 3 || cls == 0x13) kinds[n++] = DEV_KEYBOARD;   /* ALL, DEVCLASS_KEYBOARD, DEVTYPE_KEYBOARD */
    if (cls == 0 || cls == 2 || cls == 0x12) kinds[n++] = DEV_MOUSE;      /* ALL, DEVCLASS_POINTER, DEVTYPE_MOUSE */
    /* No joystick is offered: the game would bind stick X/Y to the camera. Controllers reach the game through its command
       system instead (gp_gamepad.c), like EchoPatch, which also skips the game's joystick set-up. */
    for (int i = 0; i < n; i++) {
        fill_instance(inst, kinds[i]);
        uint32_t args[2] = { inst, A(3) };
        if (!gp_call_guest(t, A(2), 2, args)) break;                    /* DIENUM_STOP */
    }
    gp_heap_free(inst);
    return DI_OK;
}

static uint32_t CreateDevice_(gp_thread *t)
{
    /* (this, rguid, lplpDevice, pUnkOuter) */
    int kind = gp_guid_eq(A(1), KEYBOARD) ? DEV_KEYBOARD : gp_guid_eq(A(1), MOUSE) ? DEV_MOUSE : 0;
    if (!kind) return DIERR_DEVICENOTREG;
    gaddr o = gp_com_new(dev_vt, 16);
    wr32(DEV_KIND(o), (uint32_t)kind);
    if (kind == DEV_JOYSTICK) gp_log("DirectInput: joystick device created (%s)", gp_pad_name());
    wr32(A(2), o);
    return DI_OK;
}
static uint32_t GetDeviceStatus_(gp_thread *t)
{
    return (gp_guid_eq(A(1), KEYBOARD) || gp_guid_eq(A(1), MOUSE)                                                          ) ? DI_OK : DIERR_DEVICENOTREG;
}

/* ------------------------------------------------------------ device */
static int kind_of(gaddr o) { return (int)rd32(DEV_KIND(o)); }

/* ------------------------------------------------------------ data formats
   DIDATAFORMAT {dwSize, dwObjSize, dwFlags, dwDataSize, dwNumObjs, rgodf};
   DIOBJECTDATAFORMAT {pguid, dwOfs, dwType, dwFlags}. Each format object is
   matched to a device object as DirectInput does; unmatched non-optional
   objects make the format invalid. */
typedef struct { const char *guid; uint32_t ofs, type; const char *name; } di_object;
static int device_objects(int kind, di_object *o);
static void write_guid(gaddr g, const char *text);
typedef struct { uint32_t size; int32_t ofs[256]; } di_format;   /* by device object index */
#define MAX_FORMATS 64
static di_format formats[MAX_FORMATS];
static int nformats;

static bool guid_matches(gaddr g, const char *text) { return !g || gp_guid_eq(g, text); }

static uint32_t SetDataFormat_(gp_thread *t)
{
    gaddr o = A(0), df = A(1);
    uint32_t objsize = rd32(df + 4), size = rd32(df + 12), n = rd32(df + 16);
    gaddr list = rd32(df + 20);
    if (objsize != 16 || size > 4096 || n > 512) return DIERR_INVALIDPARAM;
    di_object objs_[256];
    int nobj = device_objects(kind_of(o), objs_);
    di_format f = { size, {0} };
    for (int i = 0; i < 256; i++) f.ofs[i] = -1;
    for (uint32_t k = 0; k < n; k++) {
        gaddr e = list + 16 * k;
        gaddr guid = rd32(e);
        uint32_t ofs = rd32(e + 4), type = rd32(e + 8);
        uint32_t inst = (type >> 8) & 0xffff, tmask = type & 0xff;
        bool any = inst == 0xffff;
        int found = -1;
        for (int i = 0; i < nobj && found < 0; i++) {
            if (f.ofs[i] >= 0 || !guid_matches(guid, objs_[i].guid)) continue;
            if (tmask && !(objs_[i].type & tmask)) continue;
            if (!any && ((objs_[i].type >> 8) & 0xffff) != inst) continue;
            found = i;
        }
        if (found < 0) {
            if (type & 0x80000000u) continue;                  /* DIDFT_OPTIONAL */
            gp_log("DirectInput data format object %u (type 0x%x) matches no device object", k, type);
            return DIERR_INVALIDPARAM;
        }
        f.ofs[found] = (int32_t)ofs;
    }
    int slot = (int)rd32(DEV_FMT(o)) - 1;
    if (slot < 0) {
        if (nformats == MAX_FORMATS) gp_fatal("too many DirectInput data formats");
        slot = nformats++;
    }
    formats[slot] = f;
    wr32(DEV_FMT(o), (uint32_t)slot + 1);
    wr32(DEV_SIZE(o), size);
    if (kind_of(o) == DEV_JOYSTICK) gp_log("DirectInput: joystick data format set (%u bytes, %u objects)", size, n);
    return DI_OK;
}
static uint32_t SetCooperativeLevel_(gp_thread *t) { wr32(DEV_COOP(A(0)), A(2)); return DI_OK; }

static void capture_mouse(bool on)
{
    if (gp_headless()) return;
    static bool captured;
    if (on == captured) return;
    captured = on;
    CGAssociateMouseAndMouseCursorPosition(!on);
    if (on) CGDisplayHideCursor(kCGDirectMainDisplay); else CGDisplayShowCursor(kCGDirectMainDisplay);
}

static uint32_t Acquire_(gp_thread *t)
{
    gaddr o = A(0);
    pthread_mutex_lock(&gp_input_lock);
    bool already;
    if (kind_of(o) == DEV_KEYBOARD) { already = kb_acquired; kb_acquired = true; }
    else if (kind_of(o) == DEV_JOYSTICK) { already = joy_acquired; joy_acquired = true; joy_have_state = false; }   /* first poll reports the whole state */
    else { already = mouse_acquired; mouse_acquired = true; gp_mouse_dx = gp_mouse_dy = gp_mouse_dz = 0; }
    pthread_mutex_unlock(&gp_input_lock);
    if (kind_of(o) == DEV_JOYSTICK) gp_log("DirectInput: joystick acquired");
    if (kind_of(o) == DEV_MOUSE && (rd32(DEV_COOP(o)) & 1)) capture_mouse(true);   /* DISCL_EXCLUSIVE */
    return already ? DI_NOEFFECT : DI_OK;
}
static uint32_t Unacquire_(gp_thread *t)
{
    gaddr o = A(0);
    pthread_mutex_lock(&gp_input_lock);
    if (kind_of(o) == DEV_KEYBOARD) kb_acquired = false; else if (kind_of(o) == DEV_JOYSTICK) joy_acquired = false; else mouse_acquired = false;
    pthread_mutex_unlock(&gp_input_lock);
    if (kind_of(o) == DEV_MOUSE) capture_mouse(false);
    return DI_OK;
}

static uint32_t GetDeviceState_(gp_thread *t)
{
    gaddr o = A(0), out = A(2);
    uint32_t cb = A(1);
    gp_pump_events();
    int slot = (int)rd32(DEV_FMT(o)) - 1;
    if (slot < 0) return DIERR_INVALIDPARAM;
    di_format *f = &formats[slot];
    di_object objs_[256];
    int nobj = device_objects(kind_of(o), objs_);
    pthread_mutex_lock(&gp_input_lock);
    bool acq = kind_of(o) == DEV_KEYBOARD ? kb_acquired : kind_of(o) == DEV_JOYSTICK ? joy_acquired : mouse_acquired;
    if (!acq) { pthread_mutex_unlock(&gp_input_lock); return DIERR_NOTACQUIRED; }
    if (kind_of(o) == DEV_JOYSTICK) joy_poll();
    if (cb != f->size) { pthread_mutex_unlock(&gp_input_lock); return DIERR_INVALIDPARAM; }
    memset(G(out), 0, cb);
    for (int i = 0; i < nobj; i++) {
        if (f->ofs[i] < 0) continue;
        gaddr d = out + (uint32_t)f->ofs[i];
        if (kind_of(o) == DEV_KEYBOARD) wr8(d, gp_dik_state[objs_[i].ofs]);
        else if (kind_of(o) == DEV_JOYSTICK) {
            uint32_t ofs = objs_[i].ofs;
            if (ofs < 24) wr32(d, (uint32_t)joy_axis[ofs / 4]);
            else if (ofs < JOY_POV_OFS) wr32(d, (uint32_t)((joy_range[0].min + joy_range[0].max) / 2));     /* sliders: centred */
            else if (ofs < JOY_BTN_OFS) wr32(d, ofs == JOY_POV_OFS ? (uint32_t)joy_pov : 0xffffffffu);
            else wr8(d, joy_button[ofs - JOY_BTN_OFS] ? 0x80 : 0);
        }
        else if (objs_[i].ofs == 0) wr32(d, (uint32_t)gp_mouse_dx);
        else if (objs_[i].ofs == 4) wr32(d, (uint32_t)gp_mouse_dy);
        else if (objs_[i].ofs == 8) wr32(d, (uint32_t)gp_mouse_dz);
        else wr8(d, gp_mouse_buttons[objs_[i].ofs - 12]);
    }
    if (kind_of(o) == DEV_MOUSE) gp_mouse_dx = gp_mouse_dy = gp_mouse_dz = 0;
    pthread_mutex_unlock(&gp_input_lock);
    return DI_OK;
}

static uint32_t GetDeviceData_(gp_thread *t)
{
    /* (this, cbObjectData, rgdod, pdwInOut, dwFlags) */
    gaddr o = A(0), out = A(2), inout = A(3);
    uint32_t cb = A(1), flags = A(4);
    if (cb != 20 && cb != 16) return DIERR_INVALIDPARAM;
    int slot = (int)rd32(DEV_FMT(o)) - 1;
    if (slot < 0) return DIERR_INVALIDPARAM;
    di_format *f = &formats[slot];
    di_object objs_[256];
    int nobj = device_objects(kind_of(o), objs_);
    gp_pump_events();
    pthread_mutex_lock(&gp_input_lock);
    bool acq = kind_of(o) == DEV_KEYBOARD ? kb_acquired : kind_of(o) == DEV_JOYSTICK ? joy_acquired : mouse_acquired;
    ring *r = kind_of(o) == DEV_KEYBOARD ? &kb_ring : kind_of(o) == DEV_JOYSTICK ? &joy_ring : &mouse_ring;
    if (!acq) { pthread_mutex_unlock(&gp_input_lock); return DIERR_NOTACQUIRED; }
    if (kind_of(o) == DEV_JOYSTICK) joy_poll();
    uint32_t want = rd32(inout), n = 0, consumed = 0;
    uint32_t avail = r->tail - r->head;
    while (consumed < avail && (!out || n < want)) {
        di_event e = r->ev[(r->head + consumed) % RING];
        consumed++;
        int32_t fofs = -1;                                   /* raw device offset -> data format offset */
        for (int i = 0; i < nobj; i++) if (objs_[i].ofs == e.ofs) { fofs = f->ofs[i]; break; }
        if (fofs < 0) continue;                              /* object not in the format */
        if (out) {
            gaddr d = out + n * cb;
            wr32(d, (uint32_t)fofs); wr32(d + 4, e.data); wr32(d + 8, e.time); wr32(d + 12, e.seq);
            if (cb == 20) wr32(d + 16, 0);
        }
        n++;
        if (!out && n == want) break;
    }
    if (!(flags & 1)) r->head += consumed;                   /* DIGDD_PEEK keeps them */
    uint32_t ret = r->overflow ? DI_BUFFEROVERFLOW : DI_OK;
    r->overflow = false;
    pthread_mutex_unlock(&gp_input_lock);
    wr32(inout, n);
    return ret;
}

static uint32_t SetProperty_(gp_thread *t)
{
    /* (this, rguidProp, pdiph): predefined properties are small integers */
    uint32_t prop = A(1);
    gaddr ph = A(2);
    int kind = kind_of(A(0));
    switch (prop) {
    case 1: {                                                    /* DIPROP_BUFFERSIZE */
        uint32_t n = rd32(ph + 16);
        pthread_mutex_lock(&gp_input_lock);
        ring *r = kind == DEV_KEYBOARD ? &kb_ring : kind == DEV_JOYSTICK ? &joy_ring : &mouse_ring;
        r->capacity = n > RING ? RING : n;
        pthread_mutex_unlock(&gp_input_lock);
        return DI_OK;
    }
    case 2:                                                      /* DIPROP_AXISMODE */
        if (rd32(ph + 16) != (kind == DEV_JOYSTICK ? 0u : 1u)) gp_fatal("DirectInput axis mode %u for device kind %d", rd32(ph + 16), kind);   /* mouse: relative, joystick: absolute */
        return DI_OK;
    case 4: case 5: case 6:                                      /* DIPROP_RANGE, DEADZONE, SATURATION: joystick axes */
        if (kind != DEV_JOYSTICK) break;
        {
            int first = 0, last = GP_PAD_AXES - 1;                /* DIPH_DEVICE: every axis */
            uint32_t how = rd32(ph + 12), obj = rd32(ph + 8);
            if (how == 1 || how == 2) {
                di_object objs_[256];
                int n = device_objects(kind, objs_), found = -1;
                for (int i = 0; i < n && found < 0; i++)
                    if ((how == 1 && objs_[i].ofs == obj) || (how == 2 && (objs_[i].type & 0x00ffff0f) == (obj & 0x00ffff0f))) found = i;
                if (found < 0 || objs_[found].ofs >= 24) return 0x80070002u;    /* DIERR_OBJECTNOTFOUND; only the six axes take these */
                first = last = (int)(objs_[found].ofs / 4);
            } else if (how != 0) return DIERR_INVALIDPARAM;
            pthread_mutex_lock(&gp_input_lock);
            for (int a = first; a <= last; a++) {
                if (prop == 4) { joy_range[a].min = (int32_t)rd32(ph + 16); joy_range[a].max = (int32_t)rd32(ph + 20); }
                else if (prop == 5) joy_deadzone[a] = rd32(ph + 16) > 10000 ? 10000 : rd32(ph + 16);
                else joy_saturation[a] = rd32(ph + 16) > 10000 ? 10000 : rd32(ph + 16);
            }
            joy_have_state = false;                               /* re-scale and report the current state */
            pthread_mutex_unlock(&gp_input_lock);
        }
        return DI_OK;
    case 7: case 8: case 9:                                      /* FFGAIN, FFLOAD, AUTOCENTER: no force feedback on this device */
        if (kind == DEV_JOYSTICK) return 0x80004001u;            /* DIERR_UNSUPPORTED */
        break;
    }
    gp_fatal("IDirectInputDevice8A::SetProperty(%u)", prop);
}
static uint32_t GetProperty_(gp_thread *t)
{
    uint32_t prop = A(1);
    gaddr ph = A(2);
    if (prop == 1) { int k = kind_of(A(0)); wr32(ph + 16, (k == DEV_KEYBOARD ? kb_ring : k == DEV_JOYSTICK ? joy_ring : mouse_ring).capacity); return DI_OK; }
    if ((prop == 4 || prop == 5 || prop == 6) && kind_of(A(0)) == DEV_JOYSTICK) {
        int a = 0;
        if (rd32(ph + 12) == 1 && rd32(ph + 8) < 24) a = (int)(rd32(ph + 8) / 4);
        if (prop == 4) { wr32(ph + 16, (uint32_t)joy_range[a].min); wr32(ph + 20, (uint32_t)joy_range[a].max); }
        else wr32(ph + 16, prop == 5 ? joy_deadzone[a] : joy_saturation[a]);
        return DI_OK;
    }
    if (prop == 3) { wr32(ph + 16, kind_of(A(0)) != DEV_JOYSTICK && rd32(ph + 8) == 8 ? 120 : 1); return DI_OK; }   /* DIPROP_GRANULARITY: wheel 120 */
    if (prop == 20) {                                                                  /* DIPROP_KEYNAME: DIPROPSTRING */
        di_object objs_[256];
        int n = device_objects(kind_of(A(0)), objs_);
        uint32_t key = rd32(ph + 8), how = rd32(ph + 12);
        for (int i = 0; i < n; i++)
            if ((how == 1 && objs_[i].ofs == key) || (how == 2 && (objs_[i].type & 0x00ffff0f) == (key & 0x00ffff0f))) {
                const char *nm = objs_[i].name;
                size_t k = 0;
                for (; nm[k] && k < 259; k++) wr16(ph + 16 + 2 * (uint32_t)k, (uint8_t)nm[k]);
                wr16(ph + 16 + 2 * (uint32_t)k, 0);
                return DI_OK;
            }
        return 0x80070002u;                                                            /* DIERR_OBJECTNOTFOUND */
    }
    gp_fatal("IDirectInputDevice8A::GetProperty(%u)", prop);
}
static uint32_t GetCapabilities_(gp_thread *t)
{
    gaddr c = A(1);
    uint32_t size = rd32(c);
    memset(G(c + 4), 0, size - 4);
    int kind = kind_of(A(0));
    wr32(c + 4, 0x00000005);                                     /* DIDC_ATTACHED | DIDC_EMULATED */
    wr32(c + 8, kind == DEV_KEYBOARD ? 0x0413 : kind == DEV_JOYSTICK ? 0x0115 : 0x0112);
    wr32(c + 12, kind == DEV_KEYBOARD ? 0 : kind == DEV_JOYSTICK ? GP_PAD_AXES : 3);                  /* axes */
    wr32(c + 16, kind == DEV_KEYBOARD ? 128 : kind == DEV_JOYSTICK ? GP_PAD_BUTTONS : 5);             /* buttons */
    if (kind == DEV_JOYSTICK && size >= 24) wr32(c + 20, 1);                                          /* POV hats */
    return DI_OK;
}
/* key names as DirectInput reports them on an English system */
static const char *key_name(uint32_t dik)
{
    static const char *const n[256] = {
        [0x01]="Esc",[0x02]="1",[0x03]="2",[0x04]="3",[0x05]="4",[0x06]="5",[0x07]="6",[0x08]="7",[0x09]="8",[0x0a]="9",[0x0b]="0",
        [0x0c]="-",[0x0d]="=",[0x0e]="Backspace",[0x0f]="Tab",[0x10]="Q",[0x11]="W",[0x12]="E",[0x13]="R",[0x14]="T",[0x15]="Y",
        [0x16]="U",[0x17]="I",[0x18]="O",[0x19]="P",[0x1a]="[",[0x1b]="]",[0x1c]="Enter",[0x1d]="Ctrl",[0x1e]="A",[0x1f]="S",
        [0x20]="D",[0x21]="F",[0x22]="G",[0x23]="H",[0x24]="J",[0x25]="K",[0x26]="L",[0x27]=";",[0x28]="'",[0x29]="`",
        [0x2a]="Shift",[0x2b]="\\",[0x2c]="Z",[0x2d]="X",[0x2e]="C",[0x2f]="V",[0x30]="B",[0x31]="N",[0x32]="M",[0x33]=",",
        [0x34]=".",[0x35]="/",[0x36]="Right Shift",[0x37]="Num *",[0x38]="Alt",[0x39]="Space",[0x3a]="Caps Lock",
        [0x3b]="F1",[0x3c]="F2",[0x3d]="F3",[0x3e]="F4",[0x3f]="F5",[0x40]="F6",[0x41]="F7",[0x42]="F8",[0x43]="F9",[0x44]="F10",
        [0x45]="Pause",[0x46]="Scroll Lock",[0x47]="Num 7",[0x48]="Num 8",[0x49]="Num 9",[0x4a]="Num -",[0x4b]="Num 4",
        [0x4c]="Num 5",[0x4d]="Num 6",[0x4e]="Num +",[0x4f]="Num 1",[0x50]="Num 2",[0x51]="Num 3",[0x52]="Num 0",[0x53]="Num Del",
        [0x57]="F11",[0x58]="F12",[0x9c]="Num Enter",[0x9d]="Right Ctrl",[0xb5]="Num /",[0xb8]="Right Alt",[0xc5]="Num Lock",
        [0xc7]="Home",[0xc8]="Up",[0xc9]="Page Up",[0xcb]="Left",[0xcd]="Right",[0xcf]="End",[0xd0]="Down",[0xd1]="Page Down",
        [0xd2]="Insert",[0xd3]="Delete",[0xdb]="Left Windows",[0xdc]="Right Windows",[0xdd]="Application",
    };
    return dik < 256 ? n[dik] : NULL;
}

static void write_guid(gaddr g, const char *text)
{
    unsigned d1, d2, d3, b[8];
    sscanf(text, "%8x-%4x-%4x-%2x%2x-%2x%2x%2x%2x%2x%2x", &d1, &d2, &d3, &b[0], &b[1], &b[2], &b[3], &b[4], &b[5], &b[6], &b[7]);
    wr32(g, d1); wr16(g + 4, (uint16_t)d2); wr16(g + 6, (uint16_t)d3);
    for (int i = 0; i < 8; i++) wr8(g + 8 + (uint32_t)i, (uint8_t)b[i]);
}

/* objects of a device in DirectInput order; returns count */
static int device_objects(int kind, di_object *o)
{
    int n = 0;
    if (kind == DEV_MOUSE) {
        o[n++] = (di_object){ "A36D02E0-C9F3-11CF-BFC7-444553540000", 0, 0x001 | (0u << 8), "X-axis" };
        o[n++] = (di_object){ "A36D02E1-C9F3-11CF-BFC7-444553540000", 4, 0x001 | (1u << 8), "Y-axis" };
        o[n++] = (di_object){ "A36D02E2-C9F3-11CF-BFC7-444553540000", 8, 0x001 | (2u << 8), "Wheel" };
        static const char *const bn[5] = { "Button 0", "Button 1", "Button 2", "Button 3", "Button 4" };
        for (uint32_t b = 0; b < 5; b++)
            o[n++] = (di_object){ "A36D02F0-C9F3-11CF-BFC7-444553540000", 12 + b, 0x004 | ((3 + b) << 8), bn[b] };
    } else if (kind == DEV_JOYSTICK) {
        static const char *const ax[6] = { "X Axis", "Y Axis", "Z Axis", "X Rotation", "Y Rotation", "Z Rotation" };
        static const char *const axg[6] = { "A36D02E0-C9F3-11CF-BFC7-444553540000", "A36D02E1-C9F3-11CF-BFC7-444553540000", "A36D02E2-C9F3-11CF-BFC7-444553540000",
                                            "A36D02F4-C9F3-11CF-BFC7-444553540000", "A36D02F5-C9F3-11CF-BFC7-444553540000", "A36D02E3-C9F3-11CF-BFC7-444553540000" };
        for (uint32_t a = 0; a < 6; a++) o[n++] = (di_object){ axg[a], JOY_AXIS_OFS(a), 0x002 | (a << 8), ax[a] };   /* DIDFT_ABSAXIS */
        o[n++] = (di_object){ "A36D02F2-C9F3-11CF-BFC7-444553540000", JOY_POV_OFS, 0x010 | (6u << 8), "Hat Switch" };   /* DIDFT_POV */
        static const char *const bn[GP_PAD_BUTTONS] = { "Button 0", "Button 1", "Button 2", "Button 3", "Button 4", "Button 5", "Button 6",
                                                        "Button 7", "Button 8", "Button 9", "Button 10", "Button 11", "Button 12", "Button 13" };
        for (uint32_t b = 0; b < GP_PAD_BUTTONS; b++) o[n++] = (di_object){ "A36D02F0-C9F3-11CF-BFC7-444553540000", JOY_BTN_OFS + b, 0x004 | ((7 + b) << 8), bn[b] };
    } else {
        for (uint32_t dik = 1; dik < 256; dik++)
            if (key_name(dik)) o[n++] = (di_object){ "55728220-D33C-11CF-BFC7-444553540000", dik, 0x0c | (dik << 8), key_name(dik) };
    }
    return n;
}

static void write_object(gaddr inst, const di_object *o)
{
    memset(G(inst), 0, 316);
    wr32(inst, 316);
    write_guid(inst + 4, o->guid);
    wr32(inst + 20, o->ofs); wr32(inst + 24, o->type);
    strcpy((char *)G(inst + 32), o->name);
}

static uint32_t EnumObjects_(gp_thread *t)
{
    /* (this, callback, pvRef, dwFlags); callback(LPCDIDEVICEOBJECTINSTANCEA, pvRef) */
    uint32_t want = A(3) & 0xff;                                  /* DIDFT_* type mask; 0 = all */
    di_object objs_[256];
    int n = device_objects(kind_of(A(0)), objs_);
    gaddr inst = gp_heap_alloc(316, true);
    for (int i = 0; i < n; i++) {
        if (want && !(objs_[i].type & want)) continue;
        write_object(inst, &objs_[i]);
        uint32_t args[2] = { inst, A(2) };
        if (!gp_call_guest(t, A(1), 2, args)) break;              /* DIENUM_STOP */
    }
    gp_heap_free(inst);
    return DI_OK;
}

static uint32_t GetObjectInfo_(gp_thread *t)
{
    /* (this, pdidoi, dwObj, dwHow): DIPH_BYOFFSET 1, DIPH_BYID 2 */
    di_object objs_[256];
    int n = device_objects(kind_of(A(0)), objs_);
    uint32_t key = A(2), how = A(3);
    for (int i = 0; i < n; i++)
        if ((how == 1 && objs_[i].ofs == key) || (how == 2 && (objs_[i].type & 0x00ffff0f) == (key & 0x00ffff0f))) {
            write_object(A(1), &objs_[i]);
            return DI_OK;
        }
    return 0x80070002u;                                          /* DIERR_OBJECTNOTFOUND */
}

static uint32_t GetDeviceInfo_(gp_thread *t) { fill_instance(A(1), kind_of(A(0))); return DI_OK; }
static uint32_t Poll_(gp_thread *t)
{
    gp_pump_events();
    if (kind_of(A(0)) != DEV_JOYSTICK) return DI_NOEFFECT;                    /* keyboard and mouse are not polled devices */
    pthread_mutex_lock(&gp_input_lock);
    joy_poll();
    pthread_mutex_unlock(&gp_input_lock);
    return DI_OK;
}
static uint32_t QueryInterface_(gp_thread *t)
{
    gp_log("DirectInput QueryInterface refused");
    wr32(A(2), 0);
    return E_NOINTERFACE;
}

#undef DLL
#define DLL "dinput8.dll"
const gp_api gp_api_dinput8[] = { API(DirectInput8Create_, "DirectInput8Create", 5), { 0 } };
#undef DLL
#define DLL "IDirectInput8A"
const gp_api gp_api_idirectinput8[] = {
    API(QueryInterface_, "QueryInterface", 3), API(AddRef_, "AddRef", 1), API(Release_, "Release", 1),
    API(CreateDevice_, "CreateDevice", 4), API(EnumDevices_, "EnumDevices", 5), API(GetDeviceStatus_, "GetDeviceStatus", 2),
    { 0 }
};
#undef DLL
#define DLL "IDirectInputDevice8A"
const gp_api gp_api_idirectinputdevice8[] = {
    API(QueryInterface_, "QueryInterface", 3), API(AddRef_, "AddRef", 1), API(Release_, "Release", 1),
    API(GetCapabilities_, "GetCapabilities", 2), API(GetProperty_, "GetProperty", 3), API(SetProperty_, "SetProperty", 3),
    API(Acquire_, "Acquire", 1), API(Unacquire_, "Unacquire", 1), API(GetDeviceState_, "GetDeviceState", 3),
    API(GetDeviceData_, "GetDeviceData", 5), API(SetDataFormat_, "SetDataFormat", 2),
    API(SetCooperativeLevel_, "SetCooperativeLevel", 3), API(EnumObjects_, "EnumObjects", 4), API(GetObjectInfo_, "GetObjectInfo", 4), API(GetDeviceInfo_, "GetDeviceInfo", 2), API(Poll_, "Poll", 1),
    { 0 }
};
