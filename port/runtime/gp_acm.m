/* msacm32.dll: Audio Compression Manager with the codecs a Windows XP install provides:
 * PCM converter, MPEG Layer-3 decoder (AudioToolbox), IMA ADPCM decoder. */
#import <AudioToolbox/AudioToolbox.h>
#include "gp_api.h"
#include "gp_win.h"
#include <stdlib.h>
#include <string.h>

#define DLL "msacm32.dll"
#define MMSYSERR_NOERROR 0
#define MMSYSERR_INVALHANDLE 5
#define MMSYSERR_NOTSUPPORTED 8
#define MMSYSERR_INVALPARAM 11
#define ACMERR_NOTPOSSIBLE 512

enum { TAG_PCM = 1, TAG_IMA = 0x11, TAG_MP3 = 0x55 };
typedef struct { uint16_t tag; const char *short_name, *long_name, *copyright; uint16_t mid, pid; } drv;
static const drv drivers[] = {
    { TAG_PCM, "Microsoft PCM Converter", "Microsoft PCM Converter", "Copyright (C) 1992-1996 Microsoft Corporation", 1, 13 },
    { TAG_MP3, "MPEG Layer-3 Codec", "Fraunhofer IIS MPEG Layer-3 Codec (decode only)", "Copyright 1996-1999 Fraunhofer-Gesellschaft", 172, 9 },
    { TAG_IMA, "Microsoft IMA ADPCM", "Microsoft IMA ADPCM CODEC", "Copyright (C) 1992-1996 Microsoft Corporation", 1, 34 },
};
#define NDRV (sizeof drivers / sizeof *drivers)
#define HADID(i) (0x000A0010u + 4u * (uint32_t)(i))     /* driver ids */
#define HAD(i) (0x000A0110u + 4u * (uint32_t)(i))       /* open driver handles */
static int drv_of(uint32_t h)
{
    for (size_t i = 0; i < NDRV; i++) if (h == HADID(i) || h == HAD(i)) return (int)i;
    return -1;
}

typedef struct { uint16_t tag, ch; uint32_t rate, avg; uint16_t block, bits, cb; } wfx_t;
static wfx_t read_wfx(gaddr a)
{
    wfx_t w = { rd16(a), rd16(a + 2), rd32(a + 4), rd32(a + 8), rd16(a + 12), rd16(a + 14), 0 };
    if (w.tag != TAG_PCM) w.cb = rd16(a + 16);
    return w;
}
static void write_pcm(gaddr a, uint16_t ch, uint32_t rate, uint16_t bits)
{
    wr16(a, TAG_PCM); wr16(a + 2, ch); wr32(a + 4, rate); wr16(a + 12, (uint16_t)(ch * bits / 8));
    wr32(a + 8, rate * ch * bits / 8); wr16(a + 14, bits);
}

/* ------------------------------------------------------------- drivers */
static uint32_t acmDriverEnum_(gp_thread *t)
{
    /* (callback(hadid, dwInstance, fdwSupport), dwInstance, fdwEnum) */
    for (size_t i = 0; i < NDRV; i++) {
        uint32_t args[3] = { HADID(i), A(1), drivers[i].tag == TAG_PCM ? 0x2u : 0x1u };   /* CONVERTER / CODEC */
        if (!gp_call_guest(t, A(0), 3, args)) break;
    }
    return MMSYSERR_NOERROR;
}
static uint32_t acmDriverDetailsA_(gp_thread *t)
{
    int d = drv_of(A(0));
    if (d < 0) return MMSYSERR_INVALHANDLE;
    gaddr p = A(1);
    uint32_t cb = rd32(p);
    memset(G(p + 4), 0, cb > 4 ? cb - 4 : 0);
    wr32(p + 4, 0x63647561);                                  /* 'audc' */
    wr16(p + 12, drivers[d].mid); wr16(p + 14, drivers[d].pid);
    wr32(p + 16, 0x03320000); wr32(p + 20, 0x01000000);
    wr32(p + 24, drivers[d].tag == TAG_PCM ? 0x2u : 0x1u);
    wr32(p + 28, drivers[d].tag == TAG_PCM ? 1 : 2);          /* format tags */
    if (cb >= 72) snprintf((char *)G(p + 40), 32, "%s", drivers[d].short_name);
    if (cb >= 200) snprintf((char *)G(p + 72), 128, "%s", drivers[d].long_name);
    if (cb >= 280) snprintf((char *)G(p + 200), 80, "%s", drivers[d].copyright);
    return MMSYSERR_NOERROR;
}
static uint32_t acmDriverOpen_(gp_thread *t)
{
    int d = drv_of(A(1));
    if (d < 0) return MMSYSERR_INVALHANDLE;
    wr32(A(0), HAD(d));
    return MMSYSERR_NOERROR;
}
static uint32_t acmDriverClose_(gp_thread *t) { return drv_of(A(0)) < 0 ? MMSYSERR_INVALHANDLE : MMSYSERR_NOERROR; }
static uint32_t acmDriverAddA_(gp_thread *t) { (void)t; return MMSYSERR_NOTSUPPORTED; }   /* installing external codec DLLs */

static uint32_t acmMetrics_(gp_thread *t)
{
    switch (A(1)) {
    case 1: case 2: case 3: wr32(A(2), NDRV); return MMSYSERR_NOERROR;   /* COUNT_DRIVERS / CODECS / CONVERTERS */
    case 50: wr32(A(2), 30); return MMSYSERR_NOERROR;                  /* MAX_SIZE_FORMAT: MPEGLAYER3WAVEFORMAT */
    }
    gp_fatal("acmMetrics metric %u", A(1));
}

/* formats each driver can produce/accept */
typedef struct { uint16_t tag, ch, bits; uint32_t rate; } fmtent;
static int driver_formats(int d, fmtent *out)
{
    static const uint32_t rates[] = { 8000, 11025, 16000, 22050, 32000, 44100, 48000 };
    int n = 0;
    for (size_t r = 0; r < sizeof rates / sizeof *rates; r++)
        for (uint16_t ch = 1; ch <= 2; ch++) {
            if (drivers[d].tag == TAG_PCM) { out[n++] = (fmtent){ TAG_PCM, ch, 8, rates[r] }; out[n++] = (fmtent){ TAG_PCM, ch, 16, rates[r] }; }
            else if (drivers[d].tag == TAG_MP3) out[n++] = (fmtent){ TAG_MP3, ch, 0, rates[r] };
            else out[n++] = (fmtent){ TAG_IMA, ch, 4, rates[r] };
        }
    return n;
}
static uint32_t acmFormatEnumA_(gp_thread *t)
{
    /* (had, ACMFORMATDETAILSA *, callback(hadid, pafd, dwInstance, fdwSupport), dwInstance, fdwEnum) */
    gaddr fd = A(1);
    uint32_t flags = A(4);
    gaddr want = rd32(fd + 16);
    wfx_t w = want ? read_wfx(want) : (wfx_t){0};
    for (size_t d = 0; d < NDRV; d++) {
        if (A(0) && drv_of(A(0)) != (int)d) continue;
        fmtent f[64];
        int n = driver_formats((int)d, f);
        for (int i = 0; i < n; i++) {
            if ((flags & 0x10000) && f[i].tag != w.tag) continue;
            if ((flags & 0x20000) && f[i].ch != w.ch) continue;
            if ((flags & 0x40000) && f[i].rate != w.rate) continue;
            if ((flags & 0x80000) && f[i].bits != w.bits) continue;
            gaddr x = rd32(fd + 16);
            if (f[i].tag == TAG_PCM) write_pcm(x, f[i].ch, f[i].rate, f[i].bits);
            else { wr16(x, f[i].tag); wr16(x + 2, f[i].ch); wr32(x + 4, f[i].rate); wr16(x + 14, f[i].bits); wr16(x + 16, 0); }
            wr32(fd + 4, (uint32_t)i); wr32(fd + 8, f[i].tag); wr32(fd + 12, drivers[d].tag == TAG_PCM ? 0x2u : 0x1u);
            snprintf((char *)G(fd + 24), 128, "%u Hz, %u Bit, %s", f[i].rate, f[i].bits, f[i].ch == 1 ? "Mono" : "Stereo");
            uint32_t args[4] = { HADID(d), fd, A(3), rd32(fd + 12) };
            if (!gp_call_guest(t, A(2), 4, args)) return MMSYSERR_NOERROR;
        }
    }
    return MMSYSERR_NOERROR;
}
static uint32_t acmFormatSuggest_(gp_thread *t)
{
    /* (had, pwfxSrc, pwfxDst, cbwfxDst, fdwSuggest) */
    wfx_t s = read_wfx(A(1));
    if (A(3) < 16) return MMSYSERR_INVALPARAM;
    uint32_t flags = A(4);
    /* ACM_FORMATSUGGESTF_*: WFORMATTAG 0x10000, NCHANNELS 0x20000, NSAMPLESPERSEC 0x40000, WBITSPERSAMPLE 0x80000;
       every field the caller does not constrain is suggested from the source */
    if ((flags & 0x10000) && rd16(A(2)) != TAG_PCM) return ACMERR_NOTPOSSIBLE;     /* only PCM can be suggested */
    uint16_t ch = (flags & 0x20000) ? rd16(A(2) + 2) : s.ch;
    uint32_t rate = (flags & 0x40000) ? rd32(A(2) + 4) : s.rate;
    uint16_t bits = (flags & 0x80000) ? rd16(A(2) + 14) : (s.tag == TAG_PCM ? s.bits : 16);
    write_pcm(A(2), ch, rate, bits);
    return MMSYSERR_NOERROR;
}

/* ------------------------------------------------------------- streams */
typedef struct {
    wfx_t src, dst;
    AudioConverterRef mp3;
    /* MP3: complete frames handed to the converter */
    const uint8_t *in; uint32_t in_len, in_used;
    AudioStreamPacketDescription pkt;
    bool eos;
    uint32_t skipped, converted_in, converted_out;   /* diagnostics: bytes dropped while resyncing, totals */
    int16_t ima_state[2]; int8_t ima_index[2];
} stream;
#define MAX_STREAMS 256
static stream *streams[MAX_STREAMS];
#define HSTREAM(i) (0x000A1000u + 4u * (uint32_t)(i))
static stream *stream_of(uint32_t h) { uint32_t i = (h - 0x000A1000u) / 4; return h >= 0x000A1000u && i < MAX_STREAMS ? streams[i] : NULL; }

/* MPEG audio frame length in bytes from its 4-byte header; 0 if not a valid header */
static uint32_t mp3_frame_len(const uint8_t *h, uint32_t *samples)
{
    if (h[0] != 0xff || (h[1] & 0xe0) != 0xe0) return 0;
    int ver = (h[1] >> 3) & 3, layer = (h[1] >> 1) & 3, br = h[2] >> 4, sr = (h[2] >> 2) & 3, pad = (h[2] >> 1) & 1;
    if (ver == 1 || layer != 1 || br == 0 || br == 15 || sr == 3) return 0;        /* Layer III only */
    static const int rate1[3] = { 44100, 48000, 32000 };
    static const int br1[16] = { 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 };
    static const int br2[16] = { 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 };
    int rate = rate1[sr] >> (ver == 3 ? 0 : ver == 2 ? 1 : 2);
    int kbps = ver == 3 ? br1[br] : br2[br];
    *samples = ver == 3 ? 1152 : 576;
    return (uint32_t)((ver == 3 ? 144 : 72) * kbps * 1000 / rate + pad);
}

static OSStatus mp3_input(AudioConverterRef c, UInt32 *packets, AudioBufferList *data, AudioStreamPacketDescription **desc, void *user)
{
    (void)c;
    stream *s = user;
    uint32_t samples;
    /* resync to the next frame header */
    while (s->in_used + 4 <= s->in_len && !mp3_frame_len(s->in + s->in_used, &samples)) { s->in_used++; s->skipped++; }
    uint32_t len = s->in_used + 4 <= s->in_len ? mp3_frame_len(s->in + s->in_used, &samples) : 0;
    if (!len || s->in_used + len > s->in_len) { *packets = 0; data->mBuffers[0].mDataByteSize = 0; return 1; }   /* need more input */
    data->mBuffers[0].mData = (void *)(s->in + s->in_used);
    data->mBuffers[0].mDataByteSize = len;
    s->pkt = (AudioStreamPacketDescription){ 0, 0, len };
    if (desc) *desc = &s->pkt;
    *packets = 1;
    s->in_used += len;
    return noErr;
}

static uint32_t acmStreamOpen_(gp_thread *t)
{
    /* (phas, had, pwfxSrc, pwfxDst, pwfltr, dwCallback, dwInstance, fdwOpen) */
    wfx_t s = read_wfx(A(2)), d = read_wfx(A(3));
    if (getenv("GP_TRACE_ACM"))
        gp_log("acmStreamOpen src tag 0x%x %uch %uHz %ubit block %u avg %u cb %u -> dst tag 0x%x %uch %uHz %ubit flags 0x%x filter %u",
               s.tag, s.ch, s.rate, s.bits, s.block, s.avg, s.cb, d.tag, d.ch, d.rate, d.bits, A(7), A(4));
    if (getenv("GP_TRACE_ACM"))
        gp_log("  dst bytes at 0x%08x: %08x %08x %08x %08x  src bytes: %08x %08x %08x %08x %08x", A(3), rd32(A(3)), rd32(A(3) + 4), rd32(A(3) + 8), rd32(A(3) + 12),
               rd32(A(2)), rd32(A(2) + 4), rd32(A(2) + 8), rd32(A(2) + 12), rd32(A(2) + 16));
    if (A(4)) return MMSYSERR_NOTSUPPORTED;
    if (d.tag != TAG_PCM || (d.bits != 8 && d.bits != 16) || (s.tag != TAG_PCM && s.tag != TAG_MP3 && s.tag != TAG_IMA)) return ACMERR_NOTPOSSIBLE;
    if (s.tag != TAG_PCM && (s.ch != d.ch || s.rate != d.rate)) return ACMERR_NOTPOSSIBLE;   /* codecs decode; they do not resample */
    if (A(7) & 1) return MMSYSERR_NOERROR;                   /* ACM_STREAMOPENF_QUERY */
    if (A(7) & 2) gp_fatal("asynchronous ACM stream");
    stream *st = calloc(1, sizeof *st);
    st->src = s; st->dst = d;
    if (s.tag == TAG_MP3) {
        AudioStreamBasicDescription in = { .mSampleRate = s.rate, .mFormatID = kAudioFormatMPEGLayer3, .mChannelsPerFrame = s.ch,
                                           .mFramesPerPacket = s.rate >= 32000 ? 1152 : 576 };
        AudioStreamBasicDescription out = { .mSampleRate = d.rate, .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, .mBytesPerPacket = d.block,
            .mFramesPerPacket = 1, .mBytesPerFrame = d.block, .mChannelsPerFrame = d.ch, .mBitsPerChannel = d.bits };
        if (d.bits != 16 || AudioConverterNew(&in, &out, &st->mp3) != noErr) { free(st); return ACMERR_NOTPOSSIBLE; }
    }
    for (int i = 0; i < MAX_STREAMS; i++)
        if (!streams[i]) { streams[i] = st; wr32(A(0), HSTREAM(i)); return MMSYSERR_NOERROR; }
    gp_fatal("too many ACM streams");
}
static uint32_t acmStreamClose_(gp_thread *t)
{
    stream *s = stream_of(A(0));
    if (!s) return MMSYSERR_INVALHANDLE;
    if (s->mp3) AudioConverterDispose(s->mp3);
    streams[(A(0) - 0x000A1000u) / 4] = NULL;
    free(s);
    return MMSYSERR_NOERROR;
}
static uint32_t acmStreamSize_(gp_thread *t)
{
    /* (has, cbInput, pdwOutputBytes, fdwSize: 0 SOURCE -> dst bytes, 1 DESTINATION -> src bytes) */
    stream *s = stream_of(A(0));
    if (!s) return MMSYSERR_INVALHANDLE;
    uint32_t n = A(1), r;
    if (s->src.tag == TAG_IMA) {
        uint32_t per = (s->src.block - 4u * s->src.ch) * 2 / s->src.ch + 1, out_block = per * s->src.ch * 2;
        r = A(3) == 0 ? (n / s->src.block) * out_block : ((n + out_block - 1) / out_block) * s->src.block;
        wr32(A(2), r);
        return MMSYSERR_NOERROR;
    }
    double ratio;
    if (s->src.tag == TAG_MP3) ratio = (double)s->dst.rate * s->dst.block / (s->src.avg ? s->src.avg : 16000);
    else ratio = (double)s->dst.rate * s->dst.block / ((double)s->src.rate * s->src.block);
    if (A(3) == 0) r = (uint32_t)(n * ratio) + (s->src.tag == TAG_MP3 ? 1152u * s->dst.block * 2 : 0);   /* room for whole decoded frames */
    else r = (uint32_t)(n / ratio);
    r -= r % s->dst.block;
    wr32(A(2), r);
    return MMSYSERR_NOERROR;
}
static uint32_t acmStreamPrepareHeader_(gp_thread *t) { wr32(A(1) + 4, rd32(A(1) + 4) | 0x20000u); return stream_of(A(0)) ? MMSYSERR_NOERROR : MMSYSERR_INVALHANDLE; }
static uint32_t acmStreamUnprepareHeader_(gp_thread *t) { wr32(A(1) + 4, rd32(A(1) + 4) & ~0x20000u); return stream_of(A(0)) ? MMSYSERR_NOERROR : MMSYSERR_INVALHANDLE; }

static const int ima_steps[89] = { 7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,
    130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,
    2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,
    18500,20350,22385,24623,27086,29794,32767 };
static const int ima_index_adj[16] = { -1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8 };
static int16_t ima_nibble(int16_t *pred, int8_t *index, uint8_t n)
{
    int step = ima_steps[*index], diff = step >> 3;
    if (n & 1) diff += step >> 2;
    if (n & 2) diff += step >> 1;
    if (n & 4) diff += step;
    int v = *pred + ((n & 8) ? -diff : diff);
    *pred = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
    int i = *index + ima_index_adj[n];
    *index = (int8_t)(i < 0 ? 0 : i > 88 ? 88 : i);
    return *pred;
}

static uint32_t acmStreamConvert_(gp_thread *t)
{
    /* (has, ACMSTREAMHEADER *, fdwConvert) */
    stream *s = stream_of(A(0));
    if (!s) return MMSYSERR_INVALHANDLE;
    gaddr h = A(1);
    const uint8_t *src = G(rd32(h + 12));
    uint32_t slen = rd32(h + 16), dlen = rd32(h + 32);
    uint8_t *dst = G(rd32(h + 28));
    uint32_t used = 0, made = 0;
    if (s->src.tag == TAG_MP3) {
        if (A(2) & 0x10) {
            AudioConverterReset(s->mp3);                       /* ACM_STREAMCONVERTF_START */
            if (getenv("GP_TRACE_ACM")) {
                uint32_t o = 0, sm;
                while (o + 4 <= slen && !mp3_frame_len(src + o, &sm)) o++;
                if (o + 4 <= slen) {
                    const uint8_t *hd = src + o;
                    static const int r1[3] = { 44100, 48000, 32000 };
                    int ver = (hd[1] >> 3) & 3, sr = (hd[2] >> 2) & 3, mode = hd[3] >> 6;
                    int rate = sr == 3 ? 0 : r1[sr] >> (ver == 3 ? 0 : ver == 2 ? 1 : 2);
                    gp_log("MP3 stream start: declared %uch %uHz; first frame at +%u: MPEG%s %dHz %s; dst %uch %uHz", s->src.ch, s->src.rate, o,
                           ver == 3 ? "1" : ver == 2 ? "2" : "2.5", rate, mode == 3 ? "mono" : "stereo", s->dst.ch, s->dst.rate);
                } else gp_log("MP3 stream start: no frame header in the first %u bytes", slen);
            }
        }
        s->in = src; s->in_len = slen; s->in_used = 0;
        UInt32 frames = dlen / s->dst.block;
        AudioBufferList out = { 1, { { s->dst.ch, dlen, dst } } };
        OSStatus e = AudioConverterFillComplexBuffer(s->mp3, mp3_input, s, &frames, &out, NULL);
        if (e != noErr && e != 1) gp_log("MP3 decode error %d", (int)e);
        made = frames * s->dst.block;
        used = s->in_used;
        s->converted_in += used; s->converted_out += made;
        if (getenv("GP_TRACE_ACM") && (s->skipped || made < dlen / 2))
            gp_log("MP3 convert: in %u used %u -> out %u of %u bytes, skipped %u so far, total in %u out %u", slen, used, made, dlen, s->skipped, s->converted_in, s->converted_out);
    } else if (s->src.tag == TAG_IMA) {
        uint32_t block = s->src.block, ch = s->src.ch;
        uint32_t per = (block - 4 * ch) * 2 / ch + 1;             /* samples per channel in one block */
        while (used + block <= slen && made + per * ch * 2 <= dlen) {
            const uint8_t *b = src + used;
            int16_t *o = (int16_t *)(dst + made);
            for (uint32_t c = 0; c < ch; c++) {
                s->ima_state[c] = (int16_t)(b[4 * c] | (b[4 * c + 1] << 8));
                s->ima_index[c] = (int8_t)(b[4 * c + 2] > 88 ? 88 : b[4 * c + 2]);
                o[c] = s->ima_state[c];
            }
            const uint8_t *d = b + 4 * ch;
            uint32_t k = 1;
            while (k < per) {                                      /* 8 samples per channel per 4-byte group */
                for (uint32_t c = 0; c < ch; c++)
                    for (uint32_t i = 0; i < 8 && k + i < per; i++) {
                        uint8_t byte = d[4 * c + i / 2];
                        o[(k + i) * ch + c] = ima_nibble(&s->ima_state[c], &s->ima_index[c], (uint8_t)((i & 1) ? byte >> 4 : byte & 15));
                    }
                d += 4 * ch; k += 8;
            }
            used += block; made += per * ch * 2;
        }
        if (s->dst.bits != 16) gp_fatal("IMA ADPCM to %u-bit PCM", s->dst.bits);
    } else {
        /* PCM to PCM: bit depth and channel conversion at the same rate */
        if (s->src.rate != s->dst.rate) gp_fatal("ACM PCM resampling %u -> %u Hz", s->src.rate, s->dst.rate);
        uint32_t frames = slen / s->src.block;
        if (frames > dlen / s->dst.block) frames = dlen / s->dst.block;
        for (uint32_t f = 0; f < frames; f++)
            for (uint32_t c = 0; c < s->dst.ch; c++) {
                uint32_t sc = c < s->src.ch ? c : 0;
                int32_t v = s->src.bits == 8 ? (src[f * s->src.block + sc] - 128) << 8 : (int16_t)(src[f * s->src.block + 2 * sc] | (src[f * s->src.block + 2 * sc + 1] << 8));
                if (s->src.ch == 2 && s->dst.ch == 1) {
                    int32_t v2 = s->src.bits == 8 ? (src[f * s->src.block + 1] - 128) << 8 : (int16_t)(src[f * s->src.block + 2] | (src[f * s->src.block + 3] << 8));
                    v = (v + v2) / 2;
                }
                if (s->dst.bits == 8) dst[f * s->dst.block + c] = (uint8_t)((v >> 8) + 128);
                else { dst[f * s->dst.block + 2 * c] = (uint8_t)v; dst[f * s->dst.block + 2 * c + 1] = (uint8_t)(v >> 8); }
            }
        used = frames * s->src.block; made = frames * s->dst.block;
    }
    wr32(h + 20, used);                                        /* cbSrcLengthUsed */
    wr32(h + 36, made);                                        /* cbDstLengthUsed */
    wr32(h + 4, rd32(h + 4) | 0x10000u);                       /* ACMSTREAMHEADER_STATUSF_DONE */
    return MMSYSERR_NOERROR;
}

const gp_api gp_api_msacm32[] = {
    API(acmDriverEnum_, "acmDriverEnum", 3), API(acmDriverDetailsA_, "acmDriverDetailsA", 3), API(acmDriverOpen_, "acmDriverOpen", 3),
    API(acmDriverClose_, "acmDriverClose", 2), API(acmDriverAddA_, "acmDriverAddA", 5), API(acmMetrics_, "acmMetrics", 3),
    API(acmFormatEnumA_, "acmFormatEnumA", 5), API(acmFormatSuggest_, "acmFormatSuggest", 5), API(acmStreamOpen_, "acmStreamOpen", 8),
    API(acmStreamClose_, "acmStreamClose", 2), API(acmStreamSize_, "acmStreamSize", 4),
    API(acmStreamPrepareHeader_, "acmStreamPrepareHeader", 3), API(acmStreamUnprepareHeader_, "acmStreamUnprepareHeader", 3),
    API(acmStreamConvert_, "acmStreamConvert", 3),
    { 0 }
};
