/* gdi32.dll: memory DCs, DIB sections, fonts and text on CoreText.
 * Metrics follow GDI: cell height = OS/2 usWinAscent + usWinDescent scaled to the
 * requested size, text drawn at the top of the cell (TA_TOP), and 32-bpp DIB
 * pixels touched by text get RGB blended by coverage with the alpha byte cleared. */
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#include "gp_api.h"
#include "gp_win.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define DLL "gdi32.dll"

enum { O_NONE, O_DC, O_FONT, O_BITMAP, O_STOCK };
typedef struct {
    int type;
    /* DC */
    uint32_t font, bitmap, text_color, bk_color, bk_mode, map_mode;
    /* font */
    CTFontRef ct;
    int32_t height, ascent, descent, internal_leading, avg_width, max_width, weight;
    bool italic;
    char face[32];
    /* bitmap */
    gaddr bits;
    int32_t w, h, bpp;
    bool bottom_up;
} gobj;

#define MAX_OBJ 1024
#define OBJ_BASE 0x00070000u
static gobj objs[MAX_OBJ];
static pthread_mutex_t gdi_lock = PTHREAD_MUTEX_INITIALIZER;

static uint32_t obj_new(gobj o)
{
    for (uint32_t i = 1; i < MAX_OBJ; i++)
        if (objs[i].type == O_NONE) { objs[i] = o; return OBJ_BASE + 4 * i; }
    gp_fatal("GDI object table full");
}
static gobj *obj(uint32_t h, int type)
{
    if (h < OBJ_BASE || (h - OBJ_BASE) % 4 || (h - OBJ_BASE) / 4 >= MAX_OBJ) return NULL;
    gobj *o = &objs[(h - OBJ_BASE) / 4];
    return (o->type == type || (type == O_NONE && o->type != O_NONE)) ? o : NULL;
}

static uint32_t GetStockObject_(gp_thread *t) { return 0x00080000u | (A(0) & 0xff); }

static uint32_t CreateCompatibleDC_(gp_thread *t)
{
    (void)t;
    pthread_mutex_lock(&gdi_lock);
    uint32_t h = obj_new((gobj){ .type = O_DC, .text_color = 0, .bk_color = 0xffffff, .bk_mode = 2, .map_mode = 1 });
    pthread_mutex_unlock(&gdi_lock);
    return h;
}
static uint32_t DeleteDC_(gp_thread *t)
{
    pthread_mutex_lock(&gdi_lock);
    gobj *o = obj(A(0), O_DC);
    if (o) *o = (gobj){0};
    pthread_mutex_unlock(&gdi_lock);
    return o != NULL;
}

static uint32_t CreateDIBSection_(gp_thread *t)
{
    /* (hdc, BITMAPINFO *, usage, void **ppvBits, hSection, offset) */
    gaddr bi = A(1);
    int32_t w = (int32_t)rd32(bi + 4), h = (int32_t)rd32(bi + 8);
    uint16_t bpp = rd16(bi + 14);
    uint32_t compression = rd32(bi + 16);
    if (A(4)) gp_fatal("CreateDIBSection on a file mapping");
    if (w <= 0 || h == 0) { set_error(t, ERROR_INVALID_PARAMETER); return 0; }   /* as GDI: no bitmap */
    if ((bpp != 32 && bpp != 24 && bpp != 8) || (compression != 0 && compression != 3))
        gp_fatal("CreateDIBSection %dx%d %u bpp compression %u", w, h, bpp, compression);
    uint32_t stride = (((uint32_t)w * bpp + 31) / 32) * 4;
    gaddr bits = gp_heap_alloc(stride * (uint32_t)abs(h), true);
    if (!bits) { set_error(t, ERROR_NOT_ENOUGH_MEMORY); return 0; }
    wr32(A(3), bits);
    pthread_mutex_lock(&gdi_lock);
    uint32_t r = obj_new((gobj){ .type = O_BITMAP, .bits = bits, .w = w, .h = abs(h), .bpp = bpp, .bottom_up = h > 0 });
    pthread_mutex_unlock(&gdi_lock);
    return r;
}

/* ---------------------------------------------------------------- fonts */
static uint32_t AddFontResourceA_(gp_thread *t)
{
    char *host = gp_path_to_host(gstr(A(0)));
    if (!host) { gp_log("AddFontResourceA(%s): path outside the game", gstr(A(0))); return 0; }
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)host, (CFIndex)strlen(host), false);
    CFErrorRef err = NULL;
    bool ok = CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, &err);
    CFArrayRef descs = CTFontManagerCreateFontDescriptorsFromURL(url);
    uint32_t n = descs ? (uint32_t)CFArrayGetCount(descs) : 0;
    if (descs) CFRelease(descs);
    if (!ok) {
        /* already registered by an earlier AddFontResource of the same file */
        CFIndex code = err ? CFErrorGetCode(err) : 0;
        if (code != kCTFontManagerErrorAlreadyRegistered) { gp_log("AddFontResourceA(%s) failed (%ld)", host, (long)code); n = 0; }
    }
    if (err) CFRelease(err);
    CFRelease(url);
    free(host);
    return n;
}
static uint32_t RemoveFontResourceA_(gp_thread *t)
{
    char *host = gp_path_to_host(gstr(A(0)));
    if (!host) return 0;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)host, (CFIndex)strlen(host), false);
    bool ok = CTFontManagerUnregisterFontsForURL(url, kCTFontManagerScopeProcess, NULL);
    CFRelease(url);
    free(host);
    return ok;
}

static int16_t be16(const uint8_t *p) { return (int16_t)((p[0] << 8) | p[1]); }

/* Windows ascent/descent (OS/2 usWinAscent/usWinDescent) in font units; falls back to hhea */
static void win_metrics(CTFontRef f, double *asc, double *desc, double *upem)
{
    *upem = CTFontGetUnitsPerEm(f);
    CFDataRef os2 = CTFontCopyTable(f, kCTFontTableOS2, kCTFontTableOptionNoOptions);
    if (os2 && CFDataGetLength(os2) >= 78) {
        const uint8_t *p = CFDataGetBytePtr(os2);
        *asc = (uint16_t)be16(p + 74); *desc = (uint16_t)be16(p + 76);
        CFRelease(os2);
        return;
    }
    if (os2) CFRelease(os2);
    double s = CTFontGetSize(f);
    *asc = CTFontGetAscent(f) * *upem / s; *desc = CTFontGetDescent(f) * *upem / s;
}

static uint32_t CreateFontIndirectA_(gp_thread *t)
{
    gaddr lf = A(0);
    int32_t height = (int32_t)rd32(lf);
    int32_t weight = (int32_t)rd32(lf + 16);
    bool italic = rd8(lf + 20);
    char face[33];
    memcpy(face, G(lf + 28), 32); face[32] = 0;
    CFStringRef fam = CFStringCreateWithCString(NULL, face[0] ? face : "Arial", kCFStringEncodingWindowsLatin1);
    CFMutableDictionaryRef traits = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    double wt = weight >= 600 ? 0.4 : 0.0;
    CFNumberRef wn = CFNumberCreate(NULL, kCFNumberDoubleType, &wt);
    CFDictionarySetValue(traits, kCTFontWeightTrait, wn);
    uint32_t sym = italic ? kCTFontItalicTrait : 0;
    CFNumberRef sn = CFNumberCreate(NULL, kCFNumberSInt32Type, &sym);
    CFDictionarySetValue(traits, kCTFontSymbolicTrait, sn);
    const void *keys[] = { kCTFontFamilyNameAttribute, kCTFontTraitsAttribute };
    const void *vals[] = { fam, traits };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef d = CTFontDescriptorCreateWithAttributes(attrs);
    CTFontRef probe = CTFontCreateWithFontDescriptor(d, 100.0, NULL);
    double asc, desc, upem;
    win_metrics(probe, &asc, &desc, &upem);
    /* lfHeight < 0: character (em) height; > 0: cell height; 0: default 12 px cell */
    double size = height < 0 ? -height : (height ? height : 12) * upem / (asc + desc);
    CTFontRef f = CTFontCreateWithFontDescriptor(d, size, NULL);
    CFRelease(probe); CFRelease(d); CFRelease(attrs); CFRelease(traits); CFRelease(wn); CFRelease(sn); CFRelease(fam);
    CFStringRef actual = CTFontCopyFamilyName(f);
    char got[128] = "";
    CFStringGetCString(actual, got, sizeof got, kCFStringEncodingUTF8);
    CFRelease(actual);
    if (face[0] && strcasecmp(got, face)) gp_log("font \"%s\" resolved to \"%s\"", face, got);
    if (getenv("GP_TRACE_GDI")) gp_log("font \"%s\" lfHeight %d weight %d -> size %.2f asc %.0f desc %.0f upem %.0f", face, height, weight, size, asc, desc, upem);
    gobj o = { .type = O_FONT, .ct = f, .weight = weight ? weight : 400, .italic = italic };
    snprintf(o.face, sizeof o.face, "%s", face);
    o.ascent = (int32_t)lround(asc * size / upem);
    o.descent = (int32_t)lround(desc * size / upem);
    o.height = o.ascent + o.descent;
    o.internal_leading = o.height - (int32_t)lround(size);
    if (o.internal_leading < 0) o.internal_leading = 0;
    UniChar x = 'x'; CGGlyph g; CGSize adv;
    CTFontGetGlyphsForCharacters(f, &x, &g, 1);
    CTFontGetAdvancesForGlyphs(f, kCTFontOrientationHorizontal, &g, &adv, 1);
    o.avg_width = (int32_t)lround(adv.width);
    o.max_width = (int32_t)lround(CTFontGetBoundingBox(f).size.width);
    pthread_mutex_lock(&gdi_lock);
    uint32_t h = obj_new(o);
    pthread_mutex_unlock(&gdi_lock);
    return h;
}

static uint32_t SelectObject_(gp_thread *t)
{
    pthread_mutex_lock(&gdi_lock);
    gobj *dc = obj(A(0), O_DC), *o = obj(A(1), O_NONE);
    uint32_t prev = 0;
    if (dc && o && o->type == O_FONT) { prev = dc->font; dc->font = A(1); }
    else if (dc && o && o->type == O_BITMAP) { prev = dc->bitmap; dc->bitmap = A(1); }
    else if (dc && (A(1) & 0xffff0000u) == 0x00080000u) { prev = dc->font; dc->font = 0; }   /* stock font */
    pthread_mutex_unlock(&gdi_lock);
    if (!dc) gp_fatal("SelectObject on non-DC 0x%x", A(0));
    return prev ? prev : 0x0008000du;   /* SYSTEM_FONT / default bitmap stand-in */
}
static uint32_t DeleteObject_(gp_thread *t)
{
    pthread_mutex_lock(&gdi_lock);
    gobj *o = obj(A(0), O_NONE);
    if (o) {
        if (o->type == O_FONT && o->ct) CFRelease(o->ct);
        if (o->type == O_BITMAP) gp_heap_free(o->bits);
        *o = (gobj){0};
    }
    pthread_mutex_unlock(&gdi_lock);
    return 1;
}

static gobj *dc_font(gp_thread *t, uint32_t hdc)
{
    gobj *dc = obj(hdc, O_DC);
    if (!dc) gp_fatal("GDI call on non-DC 0x%x from 0x%08x", hdc, rd32(t->cpu._esp));
    gobj *f = obj(dc->font, O_FONT);
    if (!f) gp_fatal("GDI text call with no font selected (DC 0x%x)", hdc);
    return f;
}

static uint32_t SetTextColor_(gp_thread *t) { gobj *dc = obj(A(0), O_DC); if (!dc) return 0xffffffffu; uint32_t o = dc->text_color; dc->text_color = A(1); return o; }
static uint32_t SetBkColor_(gp_thread *t) { gobj *dc = obj(A(0), O_DC); if (!dc) return 0xffffffffu; uint32_t o = dc->bk_color; dc->bk_color = A(1); return o; }
static uint32_t SetBkMode_(gp_thread *t) { gobj *dc = obj(A(0), O_DC); if (!dc) return 0; uint32_t o = dc->bk_mode; dc->bk_mode = A(1); return o; }
static uint32_t SetMapMode_(gp_thread *t)
{
    gobj *dc = obj(A(0), O_DC);
    if (!dc) return 0;
    if (A(1) != 1) gp_fatal("SetMapMode %u (only MM_TEXT is implemented)", A(1));
    uint32_t o = dc->map_mode; dc->map_mode = A(1); return o;
}
static uint32_t GdiFlush_(gp_thread *t) { (void)t; return 1; }

static uint32_t GetTextMetricsA_(gp_thread *t)
{
    gobj *f = dc_font(t, A(0));
    gaddr m = A(1);
    memset(G(m), 0, 56);
    wr32(m, (uint32_t)f->height); wr32(m + 4, (uint32_t)f->ascent); wr32(m + 8, (uint32_t)f->descent);
    wr32(m + 12, (uint32_t)f->internal_leading); wr32(m + 16, 0);
    wr32(m + 20, (uint32_t)f->avg_width); wr32(m + 24, (uint32_t)f->max_width); wr32(m + 28, (uint32_t)f->weight);
    wr32(m + 32, 0); wr32(m + 36, 96); wr32(m + 40, 96);
    wr8(m + 44, 0x20); wr8(m + 45, 0xff); wr8(m + 46, 0x1f); wr8(m + 47, 0x20);
    wr8(m + 48, f->italic); wr8(m + 49, 0); wr8(m + 50, 0);
    wr8(m + 51, 0x06);          /* TMPF_VECTOR | TMPF_TRUETYPE, variable pitch */
    wr8(m + 52, 0);             /* ANSI_CHARSET */
    return 1;
}

static uint32_t GetCharWidth32W_(gp_thread *t)
{
    gobj *f = dc_font(t, A(0));
    uint32_t first = A(1), last = A(2);
    if (last < first || last - first > 0xffff) { set_error(t, ERROR_INVALID_PARAMETER); return 0; }
    for (uint32_t c = first; c <= last; c++) {
        UniChar u = (UniChar)c; CGGlyph g = 0; CGSize adv = {0};
        if (CTFontGetGlyphsForCharacters(f->ct, &u, &g, 1)) CTFontGetAdvancesForGlyphs(f->ct, kCTFontOrientationHorizontal, &g, &adv, 1);
        wr32(A(3) + 4 * (c - first), (uint32_t)lround(adv.width));
    }
    return 1;
}

/* coverage mask of one glyph run, top-down, 1 byte per pixel */
static uint8_t *render_mask(CTFontRef f, const UniChar *s, size_t n, int32_t w, int32_t h, double baseline, double x0)
{
    uint8_t *mask = calloc((size_t)w * (size_t)h, 1);
    if (!mask) gp_fatal("out of host memory");
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef cg = CGBitmapContextCreate(mask, (size_t)w, (size_t)h, 8, (size_t)w, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    CGContextSetGrayFillColor(cg, 1.0, 1.0);
    CGContextSetShouldAntialias(cg, true);
    CGContextSetShouldSmoothFonts(cg, false);
    CGGlyph *glyphs = calloc(n, sizeof *glyphs);
    CGPoint *pos = calloc(n, sizeof *pos);
    CTFontGetGlyphsForCharacters(f, s, glyphs, (CFIndex)n);
    double x = x0;
    for (size_t i = 0; i < n; i++) {
        CGSize adv;
        CTFontGetAdvancesForGlyphs(f, kCTFontOrientationHorizontal, &glyphs[i], &adv, 1);
        pos[i] = CGPointMake(x, h - baseline);    /* CG origin is bottom-left */
        x += round(adv.width);                    /* GDI advances by whole pixels */
    }
    CTFontDrawGlyphs(f, glyphs, pos, n, cg);
    CGContextRelease(cg);
    free(glyphs); free(pos);
    return mask;
}

static uint32_t TextOutW_(gp_thread *t)
{
    uint32_t hdc = A(0);
    int32_t x = (int32_t)A(1), y = (int32_t)A(2);
    gaddr str = A(3);
    int32_t n = (int32_t)A(4);
    gobj *f = dc_font(t, hdc);
    gobj *dc = obj(hdc, O_DC), *bm = obj(dc->bitmap, O_BITMAP);
    if (!bm) gp_fatal("TextOutW into a DC without a DIB section");
    if (bm->bpp != 32 && bm->bpp != 24) gp_fatal("TextOutW into a %d-bpp DIB", bm->bpp);
    uint32_t px_bytes = (uint32_t)bm->bpp / 8;
    if (n <= 0) return 1;
    UniChar *s = malloc(sizeof *s * (size_t)n);
    for (int32_t i = 0; i < n; i++) s[i] = rd16(str + 2 * (uint32_t)i);
    int32_t cell_w = 0;
    for (int32_t i = 0; i < n; i++) {
        CGGlyph g = 0; CGSize adv = {0};
        if (CTFontGetGlyphsForCharacters(f->ct, &s[i], &g, 1)) CTFontGetAdvancesForGlyphs(f->ct, kCTFontOrientationHorizontal, &g, &adv, 1);
        cell_w += (int32_t)lround(adv.width);
    }
    uint8_t *mask = render_mask(f->ct, s, (size_t)n, bm->w, bm->h, y + f->ascent, x);
    free(s);
    uint32_t stride = (((uint32_t)bm->w * (uint32_t)bm->bpp + 31) / 32) * 4;   /* DWORD-aligned rows */
    uint32_t fg = dc->text_color;
    uint32_t bg = ((dc->bk_color & 0xff) << 16) | (dc->bk_color & 0xff00) | ((dc->bk_color >> 16) & 0xff);  /* COLORREF -> BGRA */
    for (int32_t row = 0; row < bm->h; row++) {
        gaddr line = bm->bits + stride * (uint32_t)(bm->bottom_up ? bm->h - 1 - row : row);
        bool in_rows = row >= y && row < y + f->height;
        for (int32_t col = 0; col < bm->w; col++) {
            uint8_t cov = mask[(size_t)row * (size_t)bm->w + (size_t)col];
            bool in_cell = in_rows && col >= x && col < x + cell_w;
            gaddr px = line + px_bytes * (uint32_t)col;
            if (dc->bk_mode == 2 && in_cell) { for (uint32_t c = 0; c < 3; c++) wr8(px + c, (uint8_t)(bg >> (8 * c))); if (px_bytes == 4) wr8(px + 3, 0); }
            if (!cov) continue;
            for (uint32_t c = 0; c < 3; c++) {                    /* DIB is BGR(A), COLORREF is 0x00BBGGRR */
                uint32_t fc = (fg >> (8 * (2 - c))) & 0xff, bc = rd8(px + c);
                wr8(px + c, (uint8_t)((fc * cov + bc * (255u - cov) + 127) / 255));
            }
            if (px_bytes == 4) wr8(px + 3, 0);                    /* alpha byte cleared, as GDI does */
        }
    }
    free(mask);
    return 1;
}

/* GetGlyphOutlineW with GGO_METRICS (0) or GGO_GRAY8_BITMAP (6) */
static uint32_t GetGlyphOutlineW_(gp_thread *t)
{
    gobj *f = dc_font(t, A(0));
    uint32_t ch = A(1), fmt = A(2) & 0x7f;
    gaddr gm = A(3), buf = A(5);
    uint32_t cap = A(4);
    if (fmt != 0 && fmt != 6) gp_fatal("GetGlyphOutlineW format %u", fmt);
    UniChar u = (UniChar)ch; CGGlyph g = 0;
    CTFontGetGlyphsForCharacters(f->ct, &u, &g, 1);
    CGRect box = CTFontGetBoundingRectsForGlyphs(f->ct, kCTFontOrientationHorizontal, &g, NULL, 1);
    CGSize adv;
    CTFontGetAdvancesForGlyphs(f->ct, kCTFontOrientationHorizontal, &g, &adv, 1);
    int32_t x0 = (int32_t)floor(box.origin.x), y1 = (int32_t)ceil(box.origin.y + box.size.height);
    int32_t bw = (int32_t)ceil(box.origin.x + box.size.width) - x0, bh = y1 - (int32_t)floor(box.origin.y);
    if (bw <= 0 || bh <= 0) { bw = 1; bh = 1; x0 = 0; y1 = 0; }
    wr32(gm, (uint32_t)bw); wr32(gm + 4, (uint32_t)bh);
    wr32(gm + 8, (uint32_t)x0); wr32(gm + 12, (uint32_t)y1);            /* gmptGlyphOrigin: upper-left relative to baseline */
    wr16(gm + 16, (uint16_t)(int16_t)lround(adv.width)); wr16(gm + 18, 0);
    uint32_t stride = ((uint32_t)bw + 3) & ~3u, need = stride * (uint32_t)bh;
    if (fmt == 0) return 1;
    if (!buf || !cap) return need;
    if (cap < need) { set_error(t, ERROR_INSUFFICIENT_BUFFER); return 0xffffffffu; }
    uint8_t *mask = render_mask(f->ct, &u, 1, bw, bh, y1, -x0);
    for (int32_t r = 0; r < bh; r++)
        for (int32_t c = 0; c < (int32_t)stride; c++)
            wr8(buf + (uint32_t)r * stride + (uint32_t)c, c < bw ? (uint8_t)((mask[r * bw + c] * 64 + 127) / 255) : 0);  /* 0..64 */
    free(mask);
    return need;
}

const gp_api gp_api_gdi32[] = {
    API(GetStockObject_, "GetStockObject", 1), API(CreateCompatibleDC_, "CreateCompatibleDC", 1), API(DeleteDC_, "DeleteDC", 1),
    API(CreateDIBSection_, "CreateDIBSection", 6), API(AddFontResourceA_, "AddFontResourceA", 1),
    API(RemoveFontResourceA_, "RemoveFontResourceA", 1), API(CreateFontIndirectA_, "CreateFontIndirectA", 1),
    API(SelectObject_, "SelectObject", 2), API(DeleteObject_, "DeleteObject", 1),
    API(SetTextColor_, "SetTextColor", 2), API(SetBkColor_, "SetBkColor", 2), API(SetBkMode_, "SetBkMode", 2),
    API(SetMapMode_, "SetMapMode", 2), API(GdiFlush_, "GdiFlush", 0),
    API(GetTextMetricsA_, "GetTextMetricsA", 2), API(GetCharWidth32W_, "GetCharWidth32W", 4),
    API(TextOutW_, "TextOutW", 5), API(GetGlyphOutlineW_, "GetGlyphOutlineW", 7),
    { 0 }
};
