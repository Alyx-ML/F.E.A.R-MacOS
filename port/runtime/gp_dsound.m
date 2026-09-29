/* dsound (via EAX.DLL!EAXDirectSoundCreate8): DirectSound 8 with DS3D and EAX 2.0 reverb.
 * Software mixer at 48 kHz stereo float; dry and reverb-send buses feed AVAudioEngine
 * (the send goes through AVAudioUnitReverb). GP_HEADLESS=1 advances play cursors on a
 * real-time clock without an audio device. */
#import <AVFoundation/AVFoundation.h>
#include <signal.h>
#include "gp_api.h"
#include "gp_win.h"
#include "gp_window.h"
#include "gp_handles.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define DS_OK 0
#define DSERR_INVALIDPARAM 0x80070057u
#define DSERR_INVALIDCALL 0x88780032u
#define DSERR_CONTROLUNAVAIL 0x8878001Eu
#define DSERR_NODRIVER 0x88780078u
#define E_NOINTERFACE 0x80004002u
#define E_NOTIMPL 0x80004001u
#define RATE 48000.0

enum { DSBCAPS_PRIMARYBUFFER = 1, DSBCAPS_STATIC = 2, DSBCAPS_LOCHARDWARE = 4, DSBCAPS_LOCSOFTWARE = 8, DSBCAPS_CTRL3D = 0x10,
       DSBCAPS_CTRLFREQUENCY = 0x20, DSBCAPS_CTRLPAN = 0x40, DSBCAPS_CTRLVOLUME = 0x80, DSBCAPS_CTRLPOSITIONNOTIFY = 0x100,
       DSBCAPS_GETCURRENTPOSITION2 = 0x10000, DSBCAPS_MUTE3DATMAXDISTANCE = 0x20000 };

typedef struct { float x, y, z; } vec3;
typedef struct {
    vec3 pos, vel, cone_orient;
    uint32_t cone_in, cone_out;
    int32_t cone_outside_vol;
    float min_dist, max_dist;
    uint32_t mode;                    /* 0 normal, 1 head-relative, 2 disable */
} ds3d;
typedef struct { vec3 pos, vel, front, top; float distance_factor, rolloff, doppler; } listener3d;
typedef struct { int32_t direct, direct_hf, room, room_hf; float room_rolloff; int32_t obstruction; float obstruction_lf;
                 int32_t occlusion; float occlusion_lf, occlusion_room; int32_t outside_hf; float air_abs; uint32_t flags; } eax_buffer;
typedef struct { int32_t room, room_hf; float room_rolloff, decay, decay_hf; int32_t reflections; float reflections_delay;
                 int32_t reverb; float reverb_delay; uint32_t environment; float size, diffusion, air_hf; uint32_t flags; } eax_listener;

typedef struct {
    bool used, primary;
    uint32_t flags, channels, rate, bits, block, bytes;
    gaddr data;
    double pos;                       /* play position in frames */
    bool playing, looping;
    int32_t volume, pan;
    uint32_t freq;                    /* 0: original */
    ds3d p3, p3_deferred;
    eax_buffer eax;
    struct { uint32_t offset; uint32_t event; } notify[64];
    uint32_t nnotify;
    int refs;                         /* guest COM objects referencing this buffer */
} dsbuf;

#define MAX_BUF 1024
static dsbuf bufs[MAX_BUF];
static listener3d listener = { {0,0,0}, {0,0,0}, {0,0,1}, {0,1,0}, 1.0f, 1.0f, 1.0f }, listener_deferred;
static eax_listener eax_l;
static pthread_mutex_t mix_lock = PTHREAD_MUTEX_INITIALIZER;
static bool deferred_dirty;

/* ------------------------------------------------------------- COM plumbing
   Every interface object is {vtable, refs, buffer index}. */
static const char *const ds_methods[] = { "QueryInterface", "AddRef", "Release", "CreateSoundBuffer", "GetCaps",
    "DuplicateSoundBuffer", "SetCooperativeLevel", "Compact", "GetSpeakerConfig", "SetSpeakerConfig", "Initialize", "VerifyCertification" };
static const char *const buf_methods[] = { "QueryInterface", "AddRef", "Release", "GetCaps", "GetCurrentPosition", "GetFormat",
    "GetVolume", "GetPan", "GetFrequency", "GetStatus", "Initialize", "Lock", "Play", "SetCurrentPosition", "SetFormat",
    "SetVolume", "SetPan", "SetFrequency", "Stop", "Unlock", "Restore", "SetFX", "AcquireResources", "GetObjectInPath" };
static const char *const b3d_methods[] = { "QueryInterface", "AddRef", "Release", "GetAllParameters", "GetConeAngles",
    "GetConeOrientation", "GetConeOutsideVolume", "GetMaxDistance", "GetMinDistance", "GetMode", "GetPosition", "GetVelocity",
    "SetAllParameters", "SetConeAngles", "SetConeOrientation", "SetConeOutsideVolume", "SetMaxDistance", "SetMinDistance",
    "SetMode", "SetPosition", "SetVelocity" };
static const char *const l3d_methods[] = { "QueryInterface", "AddRef", "Release", "GetAllParameters", "GetDistanceFactor",
    "GetDopplerFactor", "GetOrientation", "GetPosition", "GetRolloffFactor", "GetVelocity", "SetAllParameters",
    "SetDistanceFactor", "SetDopplerFactor", "SetOrientation", "SetPosition", "SetRolloffFactor", "SetVelocity", "CommitDeferredSettings" };
static const char *const ks_methods[] = { "QueryInterface", "AddRef", "Release", "Get", "Set", "QuerySupport" };
static const char *const notify_methods[] = { "QueryInterface", "AddRef", "Release", "SetNotificationPositions" };
static gaddr ds_vt, buf_vt, b3d_vt, l3d_vt, ks_vt, notify_vt;

static gaddr new_obj(gaddr vt, uint32_t index)
{
    gaddr o = gp_com_new(vt, 4);
    wr32(o + 8, index);
    if (index < MAX_BUF) bufs[index].refs++;
    return o;
}
static dsbuf *buf(gaddr obj)
{
    uint32_t i = rd32(obj + 8);
    if (i >= MAX_BUF || !bufs[i].used) gp_fatal("invalid DirectSound buffer object 0x%08x", obj);
    return &bufs[i];
}
static bool guid_is(gaddr g, const char *s) { return g && gp_guid_eq(g, s); }

static uint32_t AddRef_(gp_thread *t) { uint32_t r = rd32(A(0) + 4) + 1; wr32(A(0) + 4, r); return r; }
static uint32_t ReleaseBufObj_(gp_thread *t)
{
    uint32_t r = rd32(A(0) + 4) - 1;
    wr32(A(0) + 4, r);
    if (r) return r;
    uint32_t i = rd32(A(0) + 8);
    gp_heap_free(A(0));
    pthread_mutex_lock(&mix_lock);
    if (i < MAX_BUF && --bufs[i].refs == 0 && !bufs[i].primary) {
        gaddr data = bufs[i].data;
        bufs[i] = (dsbuf){0};
        pthread_mutex_unlock(&mix_lock);
        gp_heap_free(data);
        return 0;
    }
    pthread_mutex_unlock(&mix_lock);
    return 0;
}

/* ------------------------------------------------------------- mixer */
static float mb_gain(int32_t mb) { return mb <= -10000 ? 0.0f : powf(10.0f, (float)mb / 2000.0f); }

static float sample_at(const dsbuf *b, uint32_t frame, int ch)
{
    const uint8_t *p = (const uint8_t *)G(b->data) + (size_t)frame * b->block;
    int c = b->channels == 1 ? 0 : ch;
    if (b->bits == 8) return (p[c] - 128) / 128.0f;
    int16_t v; memcpy(&v, p + 2 * c, 2);
    return v / 32768.0f;
}

static void event_set(uint32_t h) { gp_event_set(h); }

/* gains and pitch for a 3D voice in listener space */
static void spatialise(const dsbuf *b, float *gl, float *gr, double *pitch)
{
    const ds3d *s = &b->p3;
    if (!(b->flags & DSBCAPS_CTRL3D) || s->mode == 2) return;
    vec3 d = s->pos;
    if (s->mode == 0) { d.x -= listener.pos.x; d.y -= listener.pos.y; d.z -= listener.pos.z; }
    vec3 f = listener.front, u = listener.top;
    vec3 r = { u.y * f.z - u.z * f.y, u.z * f.x - u.x * f.z, u.x * f.y - u.y * f.x };   /* right in the left-handed DS frame */
    float lx = d.x * r.x + d.y * r.y + d.z * r.z;
    float lz = d.x * f.x + d.y * f.y + d.z * f.z;
    float dist = sqrtf(d.x * d.x + d.y * d.y + d.z * d.z) * listener.distance_factor;
    float mind = s->min_dist * listener.distance_factor, maxd = s->max_dist * listener.distance_factor;
    float att = 1.0f;
    if (dist > mind) {
        float dd = dist > maxd ? maxd : dist;
        att = mind / (mind + listener.rolloff * (dd - mind));
        if (dist > maxd && (b->flags & DSBCAPS_MUTE3DATMAXDISTANCE)) att = 0;
    }
    /* sound cone */
    if (s->cone_in < 360 || s->cone_out < 360) {
        vec3 o = s->cone_orient;
        float ol = sqrtf(o.x * o.x + o.y * o.y + o.z * o.z), dl = sqrtf(d.x * d.x + d.y * d.y + d.z * d.z);
        if (ol > 0 && dl > 0) {
            float cosang = -(o.x * d.x + o.y * d.y + o.z * d.z) / (ol * dl);
            float ang = acosf(fmaxf(-1.0f, fminf(1.0f, cosang))) * 360.0f / (float)M_PI;   /* full angle */
            float outside = mb_gain(s->cone_outside_vol);
            if (ang > (float)s->cone_out) att *= outside;
            else if (ang > (float)s->cone_in) att *= 1.0f + (outside - 1.0f) * (ang - (float)s->cone_in) / (float)(s->cone_out - s->cone_in);
        }
    }
    float pan = dist > 1e-6f ? lx / sqrtf(lx * lx + lz * lz + 1e-12f) : 0.0f;
    *gl *= att * sqrtf((1.0f - pan) * 0.5f);
    *gr *= att * sqrtf((1.0f + pan) * 0.5f);
    /* Doppler: relative velocity along the source-listener axis */
    if (listener.doppler > 0 && dist > 1e-6f) {
        float dl = sqrtf(d.x * d.x + d.y * d.y + d.z * d.z);
        vec3 n = { d.x / dl, d.y / dl, d.z / dl };
        float vs = (s->mode == 0 ? s->vel.x * n.x + s->vel.y * n.y + s->vel.z * n.z : 0) * listener.distance_factor;
        float vl = (listener.vel.x * n.x + listener.vel.y * n.y + listener.vel.z * n.z) * listener.distance_factor;
        const float c = 343.3f;
        float k = listener.doppler;
        double pv = (c + k * vl) / (c + k * vs);
        if (getenv("GP_TRACE_DS") && (pv < 0.95 || pv > 1.05)) {
            static uint64_t last;
            uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            if (now - last > 500000000ull) { last = now; gp_log("doppler pitch x%.3f: source vel %g %g %g listener vel %g %g %g factor %g dist %g", pv, s->vel.x, s->vel.y, s->vel.z, listener.vel.x, listener.vel.y, listener.vel.z, listener.doppler, dist); }
        }
        if (pv > 0.25 && pv < 4.0) *pitch *= pv;
    }
}

/* Debug A/B: kill -USR2 <pid> steps through modes so a listener can find which sound layer causes an artefact.
   0 normal, 1 no reverb send, 2 no 3D positioning/Doppler, 3 mute looping mono, 4 mute looping stereo, 5 mute one-shots */
static volatile int ds_mode = 4;   /* default: looping stereo muted (fixes the warble); F12 steps modes when GP_AUDIO_AB is set */
static volatile sig_atomic_t ds_mode_step;
static void ds_usr2(int sig) { (void)sig; ds_mode_step = 1; }
/* F12 in the game window (see gp_window.m): steps the mode now and returns its description for the window title */
const char *gp_ds_debug_step(void)
{
    static const char *const names[6] = { "audio: normal", "audio: no reverb", "audio: no 3D positioning", "audio: looping mono muted",
                                          "audio: looping stereo muted", "audio: one-shot sounds muted" };
    ds_mode = (ds_mode + 1) % 6;
    return names[ds_mode];
}

static void mix(float *dry, float *wet, uint32_t frames)
{
    if (ds_mode_step) { ds_mode_step = 0; ds_mode = (ds_mode + 1) % 6; }
    memset(dry, 0, sizeof(float) * 2 * frames);
    memset(wet, 0, sizeof(float) * 2 * frames);
    uint32_t fire[64]; int nfire = 0;
    pthread_mutex_lock(&mix_lock);
    float wet_level = mb_gain(eax_l.room);
    for (int i = 0; i < MAX_BUF; i++) {
        dsbuf *b = &bufs[i];
        if (!b->used || b->primary || !b->playing || !b->data) continue;
        if ((ds_mode == 3 && b->looping && b->channels == 1) || (ds_mode == 4 && b->looping && b->channels == 2) || (ds_mode == 5 && !b->looping)) {
            /* muted for the A/B test, but time still advances so streaming buffers keep their schedule */
        }
        uint32_t nframes = b->bytes / b->block;
        if (!nframes) continue;
        float vol = mb_gain(b->volume);
        float gl = vol * (b->pan > 0 ? mb_gain(-b->pan) : 1.0f), gr = vol * (b->pan < 0 ? mb_gain(b->pan) : 1.0f);
        double pitch = (double)(b->freq ? b->freq : b->rate) / RATE;
        if (ds_mode != 2 && (b->flags & DSBCAPS_CTRL3D) && b->channels == 1) { gl = gr = vol; spatialise(b, &gl, &gr, &pitch); }
        bool muted = (ds_mode == 3 && b->looping && b->channels == 1) || (ds_mode == 4 && b->looping && b->channels == 2) || (ds_mode == 5 && !b->looping);
        if (muted) gl = gr = 0;
        float direct = mb_gain(b->eax.direct + b->eax.occlusion + b->eax.obstruction);
        float send = (ds_mode == 1 ? 0.0f : wet_level) * mb_gain(b->eax.room + (int32_t)(b->eax.occlusion * b->eax.occlusion_room));
        double pos = b->pos;
        for (uint32_t f = 0; f < frames; f++) {
            uint32_t i0 = (uint32_t)pos, i1 = i0 + 1;
            if (i1 >= nframes) i1 = b->looping ? 0 : i0;
            float fr = (float)(pos - i0);
            float l = sample_at(b, i0, 0) * (1 - fr) + sample_at(b, i1, 0) * fr;
            float r = sample_at(b, i0, 1) * (1 - fr) + sample_at(b, i1, 1) * fr;
            dry[2 * f] += l * gl * direct; dry[2 * f + 1] += r * gr * direct;
            wet[2 * f] += l * gl * send; wet[2 * f + 1] += r * gr * send;
            double before = pos;
            pos += pitch;
            /* position notifications crossed by this step */
            for (uint32_t k = 0; k < b->nnotify; k++) {
                uint32_t off = b->notify[k].offset;
                if (off == 0xffffffffu) continue;
                double at = (double)(off / b->block);
                if (before <= at && pos > at && nfire < 64) fire[nfire++] = b->notify[k].event;
            }
            if (pos >= nframes) {
                if (b->looping) {
                    pos = fmod(pos, nframes);
                    for (uint32_t k = 0; k < b->nnotify; k++)
                        if (b->notify[k].offset != 0xffffffffu && (double)(b->notify[k].offset / b->block) < pos && nfire < 64) fire[nfire++] = b->notify[k].event;
                } else {
                    b->playing = false; pos = 0;
                    for (uint32_t k = 0; k < b->nnotify; k++) if (b->notify[k].offset == 0xffffffffu && nfire < 64) fire[nfire++] = b->notify[k].event;
                    break;
                }
            }
        }
        b->pos = pos;
    }
    pthread_mutex_unlock(&mix_lock);
    for (int k = 0; k < nfire; k++) event_set(fire[k]);
}

/* ------------------------------------------------------------- output */
static AVAudioEngine *engine;
static AVAudioUnitReverb *reverb;
#define MAX_QUANTUM 8192
static float mix_dry[2 * MAX_QUANTUM], mix_wet[2 * MAX_QUANTUM];   /* fixed: the render thread never allocates */
static uint32_t mix_frames;
static dispatch_source_t headless_timer;

static const AVAudioUnitReverbPreset eax_presets[26] = {
    AVAudioUnitReverbPresetMediumRoom, AVAudioUnitReverbPresetSmallRoom, AVAudioUnitReverbPresetSmallRoom,
    AVAudioUnitReverbPresetSmallRoom, AVAudioUnitReverbPresetMediumRoom, AVAudioUnitReverbPresetMediumRoom,
    AVAudioUnitReverbPresetLargeRoom, AVAudioUnitReverbPresetMediumHall, AVAudioUnitReverbPresetMediumHall,
    AVAudioUnitReverbPresetCathedral, AVAudioUnitReverbPresetMediumRoom, AVAudioUnitReverbPresetMediumRoom,
    AVAudioUnitReverbPresetSmallRoom, AVAudioUnitReverbPresetMediumRoom, AVAudioUnitReverbPresetLargeHall,
    AVAudioUnitReverbPresetMediumRoom, AVAudioUnitReverbPresetLargeRoom, AVAudioUnitReverbPresetPlate,
    AVAudioUnitReverbPresetMediumHall, AVAudioUnitReverbPresetMediumRoom, AVAudioUnitReverbPresetLargeHall,
    AVAudioUnitReverbPresetMediumRoom, AVAudioUnitReverbPresetLargeHall, AVAudioUnitReverbPresetSmallRoom,
    AVAudioUnitReverbPresetLargeRoom, AVAudioUnitReverbPresetMediumChamber };

/* Both source nodes pull one block of the same size per cycle, in an order Core Audio does not promise.
   Whichever runs first mixes; the other reuses that block, so the reverb send is always the same cycle as the dry signal. */
static bool block_for_dry, block_for_wet;
static void render_block(uint32_t frames, bool is_dry)
{
    if (frames > MAX_QUANTUM) frames = MAX_QUANTUM;       /* Core Audio quanta are far smaller */
    bool *mine = is_dry ? &block_for_dry : &block_for_wet, *theirs = is_dry ? &block_for_wet : &block_for_dry;
    if (*mine && mix_frames == frames) { *mine = false; return; }
    *mine = false;
    mix(mix_dry, mix_wet, frames);
    mix_frames = frames;
    *theirs = true;
}

static bool start_output(void)
{
    if (engine || headless_timer) return true;
    if (gp_headless()) {
        headless_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
        dispatch_source_set_timer(headless_timer, DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC, NSEC_PER_MSEC);
        static float d[2 * 480], w[2 * 480];
        dispatch_source_set_event_handler(headless_timer, ^{ mix(d, w, 480); });   /* 10 ms of audio per tick */
        dispatch_resume(headless_timer);
        return true;
    }
    engine = [AVAudioEngine new];
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:RATE channels:2];
    AVAudioSourceNode *dry = [[AVAudioSourceNode alloc] initWithFormat:fmt renderBlock:^OSStatus(BOOL *silence, const AudioTimeStamp *ts, AVAudioFrameCount n, AudioBufferList *out) {
        (void)ts; *silence = NO;
        render_block(n, true);
        float *l = out->mBuffers[0].mData, *r = out->mBuffers[1].mData;
        for (AVAudioFrameCount i = 0; i < n; i++) { l[i] = i < mix_frames ? mix_dry[2 * i] : 0; r[i] = i < mix_frames ? mix_dry[2 * i + 1] : 0; }
        return noErr;
    }];
    AVAudioSourceNode *wet = [[AVAudioSourceNode alloc] initWithFormat:fmt renderBlock:^OSStatus(BOOL *silence, const AudioTimeStamp *ts, AVAudioFrameCount n, AudioBufferList *out) {
        (void)ts; *silence = NO;
        render_block(n, false);
        float *l = out->mBuffers[0].mData, *r = out->mBuffers[1].mData;
        for (AVAudioFrameCount i = 0; i < n; i++) { l[i] = i < mix_frames ? mix_wet[2 * i] : 0; r[i] = i < mix_frames ? mix_wet[2 * i + 1] : 0; }
        return noErr;
    }];
    reverb = [AVAudioUnitReverb new];
    [reverb loadFactoryPreset:AVAudioUnitReverbPresetMediumRoom];
    reverb.wetDryMix = 100;
    [engine attachNode:dry]; [engine attachNode:wet]; [engine attachNode:reverb];
    [engine connect:dry to:engine.mainMixerNode format:fmt];
    [engine connect:wet to:reverb format:fmt];
    [engine connect:reverb to:engine.mainMixerNode format:fmt];
    NSError *err = nil;
    if (![engine startAndReturnError:&err]) { gp_log("audio output failed to start: %s", err.localizedDescription.UTF8String); engine = nil; return false; }
    return true;
}

static void apply_listener_eax(void)
{
    if (!reverb) return;
    uint32_t env = eax_l.environment < 26 ? eax_l.environment : 0;
    [reverb loadFactoryPreset:eax_presets[env]];
}

/* ------------------------------------------------------------- IDirectSound8 */
/* One mixer serves every device object; a second device (Bink opens its own) must not reset the shared EAX state. */
static uint32_t create_ds(gaddr out, gaddr outer)
{
    signal(SIGUSR2, ds_usr2);
    static bool created;
    if (outer) return 0x80040110u;                            /* CLASS_E_NOAGGREGATION */
    if (!start_output()) return DSERR_NODRIVER;
    if (!ds_vt) {
        ds_vt = gp_com_vtable("IDirectSound8", ds_methods, 12); buf_vt = gp_com_vtable("IDirectSoundBuffer8", buf_methods, 24);
        b3d_vt = gp_com_vtable("IDirectSound3DBuffer", b3d_methods, 21); l3d_vt = gp_com_vtable("IDirectSound3DListener", l3d_methods, 18);
        ks_vt = gp_com_vtable("IKsPropertySet", ks_methods, 6); notify_vt = gp_com_vtable("IDirectSoundNotify", notify_methods, 4);
    }
    if (!created) eax_l = (eax_listener){ -1000, -100, 0.0f, 1.49f, 0.83f, -2602, 0.007f, 200, 0.011f, 0, 7.5f, 1.0f, -5.0f, 0x3f };
    created = true;
    wr32(out, new_obj(ds_vt, MAX_BUF));
    return DS_OK;
}
static uint32_t EAXDirectSoundCreate8_(gp_thread *t)
{
    /* (lpcGuidDevice, LPDIRECTSOUND8 *, pUnkOuter) */
    (void)t;
    return create_ds(A(1), A(2));
}
static uint32_t DirectSoundCreate_(gp_thread *t)
{
    /* dsound.dll DirectSoundCreate(lpcGuidDevice, LPDIRECTSOUND *, pUnkOuter): IDirectSound is a prefix of IDirectSound8 */
    (void)t;
    return create_ds(A(1), A(2));
}
static uint32_t DsQueryInterface_(gp_thread *t) { wr32(A(2), 0); return E_NOINTERFACE; }
static uint32_t DsRelease_(gp_thread *t) { uint32_t r = rd32(A(0) + 4) - 1; wr32(A(0) + 4, r); return r; }
static uint32_t SetCooperativeLevel_(gp_thread *t) { (void)t; return DS_OK; }
static uint32_t GetSpeakerConfig_(gp_thread *t) { wr32(A(1), 0x00050004u); return DS_OK; }   /* stereo, wide geometry */
static uint32_t SetSpeakerConfig_(gp_thread *t) { (void)t; return DS_OK; }
static uint32_t Compact_(gp_thread *t) { (void)t; return DS_OK; }
static uint32_t DsGetCaps_(gp_thread *t)
{
    gaddr c = A(1);
    uint32_t size = rd32(c);
    memset(G(c + 4), 0, size - 4);
    wr32(c + 4, 0x00000f5f);                                   /* PRIMARY/SECONDARY 8/16 bit mono/stereo, CONTINUOUSRATE, CERTIFIED */
    wr32(c + 8, 100); wr32(c + 12, 200000);                    /* min/max secondary sample rate */
    wr32(c + 16, 1);                                           /* primary buffers */
    wr32(c + 20, 256); wr32(c + 24, 256); wr32(c + 28, 256);   /* max hw mixing buffers (all/static/streaming) */
    wr32(c + 32, 256); wr32(c + 36, 256); wr32(c + 40, 256);   /* free */
    wr32(c + 44, 128); wr32(c + 48, 128); wr32(c + 52, 128);   /* max/free 3D buffers */
    return DS_OK;
}

static uint32_t alloc_buf(void)
{
    for (uint32_t i = 0; i < MAX_BUF; i++) if (!bufs[i].used) return i;
    gp_fatal("more than %d DirectSound buffers", MAX_BUF);
}

static uint32_t CreateSoundBuffer_(gp_thread *t)
{
    /* (this, LPCDSBUFFERDESC, LPDIRECTSOUNDBUFFER *, pUnkOuter): DSBUFFERDESC {dwSize, dwFlags, dwBufferBytes, dwReserved, lpwfxFormat, guid3DAlgorithm} */
    gaddr d = A(1);
    uint32_t flags = rd32(d + 4), bytes = rd32(d + 8), wfx = rd32(d + 16);
    pthread_mutex_lock(&mix_lock);
    uint32_t i = alloc_buf();
    dsbuf *b = &bufs[i];
    *b = (dsbuf){ .used = true, .flags = flags };
    b->p3 = (ds3d){ .cone_in = 360, .cone_out = 360, .min_dist = 1.0f, .max_dist = 1e9f };
    b->p3_deferred = b->p3;
    b->eax = (eax_buffer){ 0, 0, 0, 0, 0.0f, 0, 0.25f, 0, 0.25f, 1.5f, 0, 1.0f, 7 };
    if (flags & DSBCAPS_PRIMARYBUFFER) {
        b->primary = true; b->channels = 2; b->rate = 44100; b->bits = 16; b->block = 4;
    } else {
        if (!wfx || bytes < 4) { *b = (dsbuf){0}; pthread_mutex_unlock(&mix_lock); return DSERR_INVALIDPARAM; }
        uint16_t tag = rd16(wfx);
        b->channels = rd16(wfx + 2); b->rate = rd32(wfx + 4); b->block = rd16(wfx + 12); b->bits = rd16(wfx + 14);
        if ((tag != 1 && tag != 0xfffe) || (b->bits != 8 && b->bits != 16) || b->channels < 1 || b->channels > 2 || !b->block) {
            gp_log("DirectSound: unsupported buffer format tag %u, %u bits, %u channels", tag, b->bits, b->channels);
            *b = (dsbuf){0};
            pthread_mutex_unlock(&mix_lock);
            return DSERR_INVALIDPARAM;
        }
        if ((flags & DSBCAPS_CTRL3D) && b->channels != 1) { *b = (dsbuf){0}; pthread_mutex_unlock(&mix_lock); return DSERR_INVALIDPARAM; }
        b->bytes = bytes - bytes % b->block;
        b->data = gp_heap_alloc(b->bytes, true);
    }
    pthread_mutex_unlock(&mix_lock);
    wr32(A(2), new_obj(buf_vt, i));
    return DS_OK;
}
static uint32_t DuplicateSoundBuffer_(gp_thread *t)
{
    dsbuf *src = buf(A(1));
    pthread_mutex_lock(&mix_lock);
    uint32_t i = alloc_buf();
    bufs[i] = *src;
    bufs[i].refs = 0; bufs[i].playing = false; bufs[i].pos = 0; bufs[i].nnotify = 0;
    bufs[i].data = gp_heap_alloc(src->bytes, false);
    memcpy(G(bufs[i].data), G(src->data), src->bytes);     /* D3D docs: shares memory; a copy is identical while unchanged */
    pthread_mutex_unlock(&mix_lock);
    wr32(A(2), new_obj(buf_vt, i));
    return DS_OK;
}

/* ------------------------------------------------------------- IDirectSoundBuffer8 */
static uint32_t BufQueryInterface_(gp_thread *t)
{
    uint32_t i = rd32(A(0) + 8);
    dsbuf *b = buf(A(0));
    gaddr iid = A(1);
    gaddr vt = 0;
    if (guid_is(iid, "6825A449-7524-4D82-920F-50E36AB3AB1E") || guid_is(iid, "279AFA85-4981-11CE-A521-0020AF0BE560")) vt = buf_vt;
    else if (guid_is(iid, "279AFA86-4981-11CE-A521-0020AF0BE560") && (b->flags & DSBCAPS_CTRL3D) && !b->primary) vt = b3d_vt;
    else if (guid_is(iid, "279AFA84-4981-11CE-A521-0020AF0BE560") && b->primary && (b->flags & DSBCAPS_CTRL3D)) vt = l3d_vt;
    else if (guid_is(iid, "31EFAC30-515C-11D0-A9AA-00AA0061BE93")) vt = ks_vt;
    else if (guid_is(iid, "B0210783-89CD-11D0-AF08-00A0C925CD16") && (b->flags & DSBCAPS_CTRLPOSITIONNOTIFY)) vt = notify_vt;
    if (!vt) { wr32(A(2), 0); return E_NOINTERFACE; }
    wr32(A(2), new_obj(vt, i));
    return DS_OK;
}
static uint32_t BufGetCaps_(gp_thread *t)
{
    dsbuf *b = buf(A(0));
    gaddr c = A(1);
    wr32(c + 4, b->flags | DSBCAPS_LOCSOFTWARE); wr32(c + 8, b->bytes); wr32(c + 12, 0); wr32(c + 16, 0);
    return DS_OK;
}
static uint32_t cursor_bytes(const dsbuf *b) { return (uint32_t)b->pos * b->block; }
static uint32_t GetCurrentPosition_(gp_thread *t)
{
    dsbuf *b = buf(A(0));
    pthread_mutex_lock(&mix_lock);
    uint32_t play = b->primary ? 0 : cursor_bytes(b);
    /* The write cursor is the first byte an application may safely overwrite. The mixer reads whole blocks and the
       output has its own latency, so it must lead the play cursor by more than a block: 50 ms. A streaming
       application writes at this cursor; a smaller lead lets the mixer play ring data that was not yet refilled. */
    uint32_t lead = ((uint32_t)(b->rate / 20) * b->block);
    uint32_t write = b->bytes ? (play + (b->playing ? lead : 0)) % b->bytes : 0;
    pthread_mutex_unlock(&mix_lock);
    if (A(1)) wr32(A(1), play);
    if (A(2)) wr32(A(2), write);
    return DS_OK;
}
static uint32_t GetFormat_(gp_thread *t)
{
    dsbuf *b = buf(A(0));
    if (A(1)) {
        gaddr w = A(1);
        wr16(w, 1); wr16(w + 2, (uint16_t)b->channels); wr32(w + 4, b->rate); wr32(w + 8, b->rate * b->block);
        wr16(w + 12, (uint16_t)b->block); wr16(w + 14, (uint16_t)b->bits); if (A(2) >= 18) wr16(w + 16, 0);
    }
    if (A(3)) wr32(A(3), 18);
    return DS_OK;
}
static uint32_t SetFormat_(gp_thread *t)
{
    dsbuf *b = buf(A(0));
    if (!b->primary) return DSERR_INVALIDCALL;
    gaddr w = A(1);
    b->channels = rd16(w + 2); b->rate = rd32(w + 4); b->block = rd16(w + 12); b->bits = rd16(w + 14);
    return DS_OK;                                              /* the mixer runs at 48 kHz float regardless */
}
static uint32_t GetVolume_(gp_thread *t) { wr32(A(1), (uint32_t)buf(A(0))->volume); return DS_OK; }
static uint32_t GetPan_(gp_thread *t) { wr32(A(1), (uint32_t)buf(A(0))->pan); return DS_OK; }
static uint32_t GetFrequency_(gp_thread *t) { dsbuf *b = buf(A(0)); wr32(A(1), b->freq ? b->freq : b->rate); return DS_OK; }
static uint32_t GetStatus_(gp_thread *t)
{
    dsbuf *b = buf(A(0));
    pthread_mutex_lock(&mix_lock);
    uint32_t s = (b->playing ? 1 : 0) | (b->playing && b->looping ? 4 : 0) | 8;   /* LOCSOFTWARE */
    pthread_mutex_unlock(&mix_lock);
    wr32(A(1), s);
    return DS_OK;
}
static uint32_t Lock_(gp_thread *t)
{
    /* (this, offset, bytes, ptr1, len1, ptr2, len2, flags) */
    dsbuf *b = buf(A(0));
    if (b->primary) return DSERR_INVALIDCALL;
    uint32_t off = A(1), n = A(2), flags = A(7);
    if (flags & 1) { uint32_t w; pthread_mutex_lock(&mix_lock); w = (cursor_bytes(b) + (b->playing ? (b->rate / 20) * b->block : 0)) % b->bytes; pthread_mutex_unlock(&mix_lock); off = w; }
    if (flags & 2) n = b->bytes;
    if (off >= b->bytes || n > b->bytes || !n) return DSERR_INVALIDPARAM;
    uint32_t first = n < b->bytes - off ? n : b->bytes - off;
    wr32(A(3), b->data + off); wr32(A(4), first);
    if (A(5)) wr32(A(5), first < n ? b->data : 0);
    if (A(6)) wr32(A(6), n - first);
    return DS_OK;
}
static uint32_t Unlock_(gp_thread *t) { (void)t; return DS_OK; }   /* the mixer reads guest memory directly */
static double ds_t0;
static uint32_t Play_(gp_thread *t)
{
    { static int shown; if (shown != ds_mode) { shown = ds_mode; gp_log("DS A/B mode %d", ds_mode); } }
    if (!ds_t0) ds_t0 = (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
    dsbuf *b = buf(A(0));
    pthread_mutex_lock(&mix_lock);
    b->playing = true;
    b->looping = (A(3) & 1) != 0;
    if (getenv("GP_TRACE_DS")) gp_log("DS[%.1fs] Play buf %u: %uch %uHz %ubit %u bytes flags 0x%x freq %u looping %d volume %d", (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9 - ds_t0, rd32(A(0) + 8), b->channels, b->rate, b->bits, b->bytes, b->flags, b->freq, b->looping, b->volume);
    pthread_mutex_unlock(&mix_lock);
    return DS_OK;
}
static uint32_t Stop_(gp_thread *t)
{
    dsbuf *b = buf(A(0));
    uint32_t ev[64]; int n = 0;
    pthread_mutex_lock(&mix_lock);
    if (b->playing) for (uint32_t k = 0; k < b->nnotify; k++) if (b->notify[k].offset == 0xffffffffu && n < 64) ev[n++] = b->notify[k].event;
    if (b->playing && getenv("GP_TRACE_DS")) gp_log("DS[%.1fs] Stop buf %u", (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9 - ds_t0, rd32(A(0) + 8));
    b->playing = false;
    pthread_mutex_unlock(&mix_lock);
    for (int k = 0; k < n; k++) event_set(ev[k]);
    return DS_OK;
}
static uint32_t SetCurrentPosition_(gp_thread *t)
{
    dsbuf *b = buf(A(0));
    if (A(1) >= b->bytes) return DSERR_INVALIDPARAM;
    pthread_mutex_lock(&mix_lock); b->pos = A(1) / b->block; pthread_mutex_unlock(&mix_lock);
    return DS_OK;
}
static uint32_t SetVolume_(gp_thread *t) { int32_t v = (int32_t)A(1); if (v > 0 || v < -10000) return DSERR_INVALIDPARAM; buf(A(0))->volume = v; return DS_OK; }
static uint32_t SetPan_(gp_thread *t) { int32_t v = (int32_t)A(1); if (v > 10000 || v < -10000) return DSERR_INVALIDPARAM; buf(A(0))->pan = v; return DS_OK; }
static uint32_t SetFrequency_(gp_thread *t) { uint32_t f = A(1); if (f && (f < 100 || f > 200000)) return DSERR_INVALIDPARAM; buf(A(0))->freq = f; return DS_OK; }
static uint32_t Restore_(gp_thread *t) { (void)t; return DS_OK; }

/* ------------------------------------------------------------- 3D buffer */
static bool deferred(uint32_t apply) { return apply == 1; }   /* DS3D_DEFERRED */
static ds3d *p3w(dsbuf *b, uint32_t apply) { if (deferred(apply)) { deferred_dirty = true; return &b->p3_deferred; } return &b->p3; }
static void rdvec(gaddr a, vec3 *v) { memcpy(v, G(a), 12); }
static void wrvec(gaddr a, const vec3 *v) { memcpy(G(a), v, 12); }
static vec3 vargs(gp_thread *t, int i) { vec3 v; uint32_t x = A(i), y = A(i + 1), z = A(i + 2); memcpy(&v.x, &x, 4); memcpy(&v.y, &y, 4); memcpy(&v.z, &z, 4); return v; }
static float farg(gp_thread *t, int i) { float f; uint32_t u = A(i); memcpy(&f, &u, 4); return f; }

static uint32_t B3SetPosition_(gp_thread *t) { dsbuf *b = buf(A(0)); pthread_mutex_lock(&mix_lock); ds3d *p = p3w(b, A(4)); p->pos = vargs(t, 1); if (!deferred(A(4))) b->p3_deferred.pos = p->pos; pthread_mutex_unlock(&mix_lock); return DS_OK; }
static uint32_t B3SetVelocity_(gp_thread *t) { dsbuf *b = buf(A(0)); pthread_mutex_lock(&mix_lock); ds3d *p = p3w(b, A(4)); p->vel = vargs(t, 1); if (!deferred(A(4))) b->p3_deferred.vel = p->vel; pthread_mutex_unlock(&mix_lock); return DS_OK; }
static uint32_t B3SetMinDistance_(gp_thread *t) { dsbuf *b = buf(A(0)); pthread_mutex_lock(&mix_lock); ds3d *p = p3w(b, A(2)); p->min_dist = farg(t, 1); if (!deferred(A(2))) b->p3_deferred.min_dist = p->min_dist; pthread_mutex_unlock(&mix_lock); return DS_OK; }
static uint32_t B3SetMaxDistance_(gp_thread *t) { dsbuf *b = buf(A(0)); pthread_mutex_lock(&mix_lock); ds3d *p = p3w(b, A(2)); p->max_dist = farg(t, 1); if (!deferred(A(2))) b->p3_deferred.max_dist = p->max_dist; pthread_mutex_unlock(&mix_lock); return DS_OK; }
static uint32_t B3SetMode_(gp_thread *t) { dsbuf *b = buf(A(0)); pthread_mutex_lock(&mix_lock); ds3d *p = p3w(b, A(2)); p->mode = A(1); if (!deferred(A(2))) b->p3_deferred.mode = p->mode; pthread_mutex_unlock(&mix_lock); return DS_OK; }
static uint32_t B3SetConeAngles_(gp_thread *t) { dsbuf *b = buf(A(0)); pthread_mutex_lock(&mix_lock); ds3d *p = p3w(b, A(3)); p->cone_in = A(1); p->cone_out = A(2); if (!deferred(A(3))) b->p3_deferred = *p; pthread_mutex_unlock(&mix_lock); return DS_OK; }
static uint32_t B3SetConeOrientation_(gp_thread *t) { dsbuf *b = buf(A(0)); pthread_mutex_lock(&mix_lock); ds3d *p = p3w(b, A(4)); p->cone_orient = vargs(t, 1); if (!deferred(A(4))) b->p3_deferred.cone_orient = p->cone_orient; pthread_mutex_unlock(&mix_lock); return DS_OK; }
static uint32_t B3SetConeOutsideVolume_(gp_thread *t) { dsbuf *b = buf(A(0)); pthread_mutex_lock(&mix_lock); ds3d *p = p3w(b, A(2)); p->cone_outside_vol = (int32_t)A(1); if (!deferred(A(2))) b->p3_deferred.cone_outside_vol = p->cone_outside_vol; pthread_mutex_unlock(&mix_lock); return DS_OK; }
static uint32_t B3SetAllParameters_(gp_thread *t)
{
    /* DS3DBUFFER: dwSize, vPosition, vVelocity, dwInsideConeAngle, dwOutsideConeAngle, vConeOrientation, lConeOutsideVolume, flMinDistance, flMaxDistance, dwMode */
    dsbuf *b = buf(A(0));
    gaddr p = A(1);
    pthread_mutex_lock(&mix_lock);
    ds3d *d = p3w(b, A(2));
    rdvec(p + 4, &d->pos); rdvec(p + 16, &d->vel); d->cone_in = rd32(p + 28); d->cone_out = rd32(p + 32);
    rdvec(p + 36, &d->cone_orient); d->cone_outside_vol = (int32_t)rd32(p + 48);
    memcpy(&d->min_dist, G(p + 52), 4); memcpy(&d->max_dist, G(p + 56), 4); d->mode = rd32(p + 60);
    if (!deferred(A(2))) b->p3_deferred = *d;
    pthread_mutex_unlock(&mix_lock);
    return DS_OK;
}
static uint32_t B3GetAllParameters_(gp_thread *t)
{
    dsbuf *b = buf(A(0));
    gaddr p = A(1);
    ds3d *d = &b->p3;
    wr32(p, 64); wrvec(p + 4, &d->pos); wrvec(p + 16, &d->vel); wr32(p + 28, d->cone_in); wr32(p + 32, d->cone_out);
    wrvec(p + 36, &d->cone_orient); wr32(p + 48, (uint32_t)d->cone_outside_vol);
    memcpy(G(p + 52), &d->min_dist, 4); memcpy(G(p + 56), &d->max_dist, 4); wr32(p + 60, d->mode);
    return DS_OK;
}
static uint32_t B3GetPosition_(gp_thread *t) { wrvec(A(1), &buf(A(0))->p3.pos); return DS_OK; }
static uint32_t B3GetMinDistance_(gp_thread *t) { memcpy(G(A(1)), &buf(A(0))->p3.min_dist, 4); return DS_OK; }
static uint32_t B3GetMaxDistance_(gp_thread *t) { memcpy(G(A(1)), &buf(A(0))->p3.max_dist, 4); return DS_OK; }
static uint32_t B3GetMode_(gp_thread *t) { wr32(A(1), buf(A(0))->p3.mode); return DS_OK; }

/* ------------------------------------------------------------- listener */
static listener3d *lw(uint32_t apply) { if (deferred(apply)) { deferred_dirty = true; return &listener_deferred; } return &listener; }
static void sync_deferred_listener(uint32_t apply) { if (!deferred(apply)) listener_deferred = listener; }
static uint32_t L3SetPosition_(gp_thread *t) { pthread_mutex_lock(&mix_lock); lw(A(4))->pos = vargs(t, 1); sync_deferred_listener(A(4)); pthread_mutex_unlock(&mix_lock); return DS_OK; }
static uint32_t L3SetVelocity_(gp_thread *t) { pthread_mutex_lock(&mix_lock); lw(A(4))->vel = vargs(t, 1); sync_deferred_listener(A(4)); pthread_mutex_unlock(&mix_lock); return DS_OK; }
static uint32_t L3SetOrientation_(gp_thread *t)
{
    pthread_mutex_lock(&mix_lock);
    listener3d *l = lw(A(7));
    l->front = vargs(t, 1); l->top = vargs(t, 4);
    sync_deferred_listener(A(7));
    pthread_mutex_unlock(&mix_lock);
    return DS_OK;
}
static uint32_t L3SetDistanceFactor_(gp_thread *t) { pthread_mutex_lock(&mix_lock); lw(A(2))->distance_factor = farg(t, 1); sync_deferred_listener(A(2)); pthread_mutex_unlock(&mix_lock); return DS_OK; }
static uint32_t L3SetRolloffFactor_(gp_thread *t) { pthread_mutex_lock(&mix_lock); lw(A(2))->rolloff = farg(t, 1); sync_deferred_listener(A(2)); pthread_mutex_unlock(&mix_lock); return DS_OK; }
static uint32_t L3SetDopplerFactor_(gp_thread *t) { pthread_mutex_lock(&mix_lock); lw(A(2))->doppler = farg(t, 1); sync_deferred_listener(A(2)); pthread_mutex_unlock(&mix_lock); return DS_OK; }
static uint32_t L3SetAllParameters_(gp_thread *t)
{
    /* DS3DLISTENER: dwSize, vPosition, vVelocity, vOrientFront, vOrientTop, flDistanceFactor, flRolloffFactor, flDopplerFactor */
    gaddr p = A(1);
    pthread_mutex_lock(&mix_lock);
    listener3d *l = lw(A(2));
    rdvec(p + 4, &l->pos); rdvec(p + 16, &l->vel); rdvec(p + 28, &l->front); rdvec(p + 40, &l->top);
    memcpy(&l->distance_factor, G(p + 52), 4); memcpy(&l->rolloff, G(p + 56), 4); memcpy(&l->doppler, G(p + 60), 4);
    sync_deferred_listener(A(2));
    pthread_mutex_unlock(&mix_lock);
    return DS_OK;
}
static uint32_t L3GetAllParameters_(gp_thread *t)
{
    gaddr p = A(1);
    wr32(p, 64); wrvec(p + 4, &listener.pos); wrvec(p + 16, &listener.vel); wrvec(p + 28, &listener.front); wrvec(p + 40, &listener.top);
    memcpy(G(p + 52), &listener.distance_factor, 4); memcpy(G(p + 56), &listener.rolloff, 4); memcpy(G(p + 60), &listener.doppler, 4);
    return DS_OK;
}
static uint32_t L3CommitDeferredSettings_(gp_thread *t)
{
    (void)t;
    pthread_mutex_lock(&mix_lock);
    if (deferred_dirty) {
        listener = listener_deferred;
        for (int i = 0; i < MAX_BUF; i++) if (bufs[i].used) bufs[i].p3 = bufs[i].p3_deferred;
        deferred_dirty = false;
    }
    pthread_mutex_unlock(&mix_lock);
    return DS_OK;
}

/* ------------------------------------------------------------- EAX 2.0 (IKsPropertySet) */
#define EAX2_LISTENER "0306A6A8-B224-11D2-99E5-0000E8D8C722"
#define EAX2_BUFFER "0306A6A7-B224-11D2-99E5-0000E8D8C722"
static uint32_t KsQuerySupport_(gp_thread *t)
{
    bool ok = guid_is(A(1), EAX2_LISTENER) || guid_is(A(1), EAX2_BUFFER);
    if (!ok) return E_NOTIMPL;                                /* EAX 3/4 are not provided by this device */
    wr32(A(3), 3);                                            /* KSPROPERTY_SUPPORT_GET | SET */
    return DS_OK;
}
static uint32_t eax_listener_io(uint32_t id, gaddr data, uint32_t len, bool set)
{
    static const uint8_t off[16] = { 0, 0, 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52 };
    id &= 0x7fffffff;                                         /* DEFERRED flag */
    if (id == 0) return DS_OK;
    uint8_t *base = (uint8_t *)&eax_l;
    if (id == 1) {                                            /* ALLPARAMETERS */
        if (len < 56) return DSERR_INVALIDPARAM;
        if (set) memcpy(base, G(data), 56); else memcpy(G(data), base, 56);
    } else if (id < 16) {
        if (len < 4) return DSERR_INVALIDPARAM;
        if (set) memcpy(base + off[id], G(data), 4); else memcpy(G(data), base + off[id], 4);
    } else return DSERR_INVALIDPARAM;
    if (set) apply_listener_eax();
    return DS_OK;
}
static uint32_t eax_buffer_io(dsbuf *b, uint32_t id, gaddr data, uint32_t len, bool set)
{
    static const uint8_t off[15] = { 0, 0, 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48 };
    id &= 0x7fffffff;
    if (id == 0) return DS_OK;
    uint8_t *base = (uint8_t *)&b->eax;
    pthread_mutex_lock(&mix_lock);
    uint32_t r = DS_OK;
    if (id == 1) { if (len < 52) r = DSERR_INVALIDPARAM; else if (set) memcpy(base, G(data), 52); else memcpy(G(data), base, 52); }
    else if (id < 15) { if (len < 4) r = DSERR_INVALIDPARAM; else if (set) memcpy(base + off[id], G(data), 4); else memcpy(G(data), base + off[id], 4); }
    else r = DSERR_INVALIDPARAM;
    pthread_mutex_unlock(&mix_lock);
    return r;
}
static uint32_t KsSet_(gp_thread *t)
{
    /* (this, guid, id, pInstanceData, cbInstance, pPropData, cbPropData) */
    if (guid_is(A(1), EAX2_LISTENER)) return eax_listener_io(A(2), A(5), A(6), true);
    if (guid_is(A(1), EAX2_BUFFER)) return eax_buffer_io(buf(A(0)), A(2), A(5), A(6), true);
    return E_NOTIMPL;
}
static uint32_t KsGet_(gp_thread *t)
{
    /* (this, guid, id, pInstanceData, cbInstance, pPropData, cbPropData, pcbReturned) */
    uint32_t r = E_NOTIMPL, n = 0;
    if (guid_is(A(1), EAX2_LISTENER)) { r = eax_listener_io(A(2), A(5), A(6), false); n = (A(2) & 0x7fffffff) == 1 ? 56 : 4; }
    else if (guid_is(A(1), EAX2_BUFFER)) { r = eax_buffer_io(buf(A(0)), A(2), A(5), A(6), false); n = (A(2) & 0x7fffffff) == 1 ? 52 : 4; }
    if (A(7)) wr32(A(7), r == DS_OK ? n : 0);
    return r;
}

/* ------------------------------------------------------------- notify */
static uint32_t SetNotificationPositions_(gp_thread *t)
{
    dsbuf *b = buf(A(0));
    uint32_t n = A(1);
    if (n > 64) gp_fatal("more than 64 DirectSound notification positions");
    pthread_mutex_lock(&mix_lock);
    if (b->playing) { pthread_mutex_unlock(&mix_lock); return DSERR_INVALIDCALL; }
    b->nnotify = n;
    for (uint32_t i = 0; i < n; i++) { b->notify[i].offset = rd32(A(2) + 8 * i); b->notify[i].event = rd32(A(2) + 8 * i + 4); }
    pthread_mutex_unlock(&mix_lock);
    return DS_OK;
}

#undef DLL
#define DLL "dsound.dll"
const gp_api gp_api_dsound[] = { API(DirectSoundCreate_, "DirectSoundCreate", 3), API(DirectSoundCreate_, "#1", 3), { 0 } };
#undef DLL
#define DLL "eax.dll"
const gp_api gp_api_eax[] = { API(EAXDirectSoundCreate8_, "#6", 3), API(EAXDirectSoundCreate8_, "EAXDirectSoundCreate8", 3), { 0 } };
#undef DLL
#define DLL "IDirectSound8"
const gp_api gp_api_idirectsound8[] = {
    API(DsQueryInterface_, "QueryInterface", 3), API(AddRef_, "AddRef", 1), API(DsRelease_, "Release", 1),
    API(CreateSoundBuffer_, "CreateSoundBuffer", 4), API(DsGetCaps_, "GetCaps", 2), API(DuplicateSoundBuffer_, "DuplicateSoundBuffer", 3),
    API(SetCooperativeLevel_, "SetCooperativeLevel", 3), API(Compact_, "Compact", 1), API(GetSpeakerConfig_, "GetSpeakerConfig", 2),
    API(SetSpeakerConfig_, "SetSpeakerConfig", 2), { 0 } };
#undef DLL
#define DLL "IDirectSoundBuffer8"
const gp_api gp_api_idirectsoundbuffer8[] = {
    API(BufQueryInterface_, "QueryInterface", 3), API(AddRef_, "AddRef", 1), API(ReleaseBufObj_, "Release", 1),
    API(BufGetCaps_, "GetCaps", 2), API(GetCurrentPosition_, "GetCurrentPosition", 3), API(GetFormat_, "GetFormat", 4),
    API(GetVolume_, "GetVolume", 2), API(GetPan_, "GetPan", 2), API(GetFrequency_, "GetFrequency", 2), API(GetStatus_, "GetStatus", 2),
    API(Lock_, "Lock", 8), API(Play_, "Play", 4), API(SetCurrentPosition_, "SetCurrentPosition", 2), API(SetFormat_, "SetFormat", 2),
    API(SetVolume_, "SetVolume", 2), API(SetPan_, "SetPan", 2), API(SetFrequency_, "SetFrequency", 2), API(Stop_, "Stop", 1),
    API(Unlock_, "Unlock", 5), API(Restore_, "Restore", 1), { 0 } };
#undef DLL
#define DLL "IDirectSound3DBuffer"
const gp_api gp_api_idirectsound3dbuffer[] = {
    API(BufQueryInterface_, "QueryInterface", 3), API(AddRef_, "AddRef", 1), API(ReleaseBufObj_, "Release", 1),
    API(B3GetAllParameters_, "GetAllParameters", 2), API(B3GetMaxDistance_, "GetMaxDistance", 2), API(B3GetMinDistance_, "GetMinDistance", 2),
    API(B3GetMode_, "GetMode", 2), API(B3GetPosition_, "GetPosition", 2),
    API(B3SetAllParameters_, "SetAllParameters", 3), API(B3SetConeAngles_, "SetConeAngles", 4), API(B3SetConeOrientation_, "SetConeOrientation", 5),
    API(B3SetConeOutsideVolume_, "SetConeOutsideVolume", 3), API(B3SetMaxDistance_, "SetMaxDistance", 3), API(B3SetMinDistance_, "SetMinDistance", 3),
    API(B3SetMode_, "SetMode", 3), API(B3SetPosition_, "SetPosition", 5), API(B3SetVelocity_, "SetVelocity", 5), { 0 } };
#undef DLL
#define DLL "IDirectSound3DListener"
const gp_api gp_api_idirectsound3dlistener[] = {
    API(BufQueryInterface_, "QueryInterface", 3), API(AddRef_, "AddRef", 1), API(ReleaseBufObj_, "Release", 1),
    API(L3GetAllParameters_, "GetAllParameters", 2), API(L3SetAllParameters_, "SetAllParameters", 3),
    API(L3SetDistanceFactor_, "SetDistanceFactor", 3), API(L3SetDopplerFactor_, "SetDopplerFactor", 3),
    API(L3SetOrientation_, "SetOrientation", 8), API(L3SetPosition_, "SetPosition", 5), API(L3SetRolloffFactor_, "SetRolloffFactor", 3),
    API(L3SetVelocity_, "SetVelocity", 5), API(L3CommitDeferredSettings_, "CommitDeferredSettings", 1), { 0 } };
#undef DLL
#define DLL "IKsPropertySet"
const gp_api gp_api_ikspropertyset[] = {
    API(BufQueryInterface_, "QueryInterface", 3), API(AddRef_, "AddRef", 1), API(ReleaseBufObj_, "Release", 1),
    API(KsGet_, "Get", 8), API(KsSet_, "Set", 7), API(KsQuerySupport_, "QuerySupport", 4), { 0 } };
#undef DLL
#define DLL "IDirectSoundNotify"
const gp_api gp_api_idirectsoundnotify[] = {
    API(BufQueryInterface_, "QueryInterface", 3), API(AddRef_, "AddRef", 1), API(ReleaseBufObj_, "Release", 1),
    API(SetNotificationPositions_, "SetNotificationPositions", 3), { 0 } };
