/* App launcher: finds the player's game folder, converts the game on first launch (or after the game or the
   converter changed), then hands the cache to the runtime. The converter is a Python tool shipped in the
   app's Resources; it uses the LLVM tools and Python bundled in the app's converter/toolchain. */
#import <AppKit/AppKit.h>
#include "gp.h"
#include "gp_window.h"
#include "gp_gamepad.h"

#define APP_NAME @"FEAR Native"
#define DEFAULTS_KEY @"GameFolder"

static NSString *support_dir(void)
{
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *dir = [dirs.firstObject stringByAppendingPathComponent:APP_NAME];
    NSError *err = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&err])
        gp_fatal("cannot create %s: %s", dir.UTF8String, err.localizedDescription.UTF8String);
    return dir;
}

static void alert_and_exit(NSString *title, NSString *text)
{
    NSAlert *a = [NSAlert new];
    a.messageText = title;
    a.informativeText = text;
    a.alertStyle = NSAlertStyleCritical;
    [a runModal];
    exit(1);
}

static bool valid_game_folder(NSString *dir)
{
    BOOL isdir = NO;
    return dir && [NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:@"FEAR.exe"] isDirectory:&isdir] && !isdir;
}

static NSTask *converter_task(NSString *converter, NSArray *args, NSPipe *out)
{
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:[converter stringByAppendingPathComponent:@"toolchain/python/bin/python3"]];
    t.arguments = [@[[converter stringByAppendingPathComponent:@"tools/convert.py"]] arrayByAddingObjectsFromArray:args];
    t.standardOutput = out; t.standardError = out;
    t.currentDirectoryURL = [NSURL fileURLWithPath:converter];
    return t;
}

static bool cache_is_valid(NSString *converter, NSString *game, NSString *cache)
{
    NSPipe *out = [NSPipe pipe];
    NSTask *t = converter_task(converter, @[@"--check", game, cache], out);
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) alert_and_exit(@"Cannot run the converter", err.localizedDescription);
    [out.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    return t.terminationStatus == 0;
}

static void convert_with_progress(NSString *converter, NSString *game, NSString *cache)
{
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 460, 130)
                                              styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    w.title = APP_NAME;
    NSTextField *label = [NSTextField labelWithString:@"Preparing the game for this Mac. This happens once and can take a long time."];
    label.frame = NSMakeRect(20, 80, 420, 34);
    label.lineBreakMode = NSLineBreakByWordWrapping;
    NSTextField *status = [NSTextField labelWithString:@"Starting"];
    status.frame = NSMakeRect(20, 52, 420, 18);
    NSProgressIndicator *bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 24, 420, 20)];
    bar.indeterminate = NO; bar.minValue = 0; bar.maxValue = 1;
    [w.contentView addSubview:label]; [w.contentView addSubview:status]; [w.contentView addSubview:bar];
    [w center];
    [w makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    NSPipe *out = [NSPipe pipe];
    NSTask *t = converter_task(converter, @[game, cache], out);
    NSMutableString *other = [NSMutableString string];      // converter output that is not progress: error details
    NSMutableString *partial = [NSMutableString string];
    __block bool eof = false;
    void (^consume)(NSData *) = ^(NSData *data) {
        [partial appendString:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @""];
        NSRange r;
        while ((r = [partial rangeOfString:@"\n"]).location != NSNotFound) {
            NSString *line = [partial substringToIndex:r.location];
            [partial deleteCharactersInRange:NSMakeRange(0, r.location + 1)];
            if ([line hasPrefix:@"PROGRESS "]) {
                NSArray *parts = [[line substringFromIndex:9] componentsSeparatedByString:@" "];
                bar.doubleValue = [parts.firstObject doubleValue];
                status.stringValue = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@" "];
            } else [other appendFormat:@"%@\n", line];
        }
    };
    // Reads happen off the main thread; the main run loop keeps the window alive during long silent stages.
    out.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *data = h.availableData;
        if (!data.length) { h.readabilityHandler = nil; dispatch_async(dispatch_get_main_queue(), ^{ eof = true; }); return; }
        dispatch_async(dispatch_get_main_queue(), ^{ consume(data); });
    };
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) alert_and_exit(@"Cannot run the converter", err.localizedDescription);
    while (!eof || t.isRunning)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    [t waitUntilExit];
    [w orderOut:nil];
    if (t.terminationStatus != 0) {
        NSString *tail = other.length > 1500 ? [other substringFromIndex:other.length - 1500] : other;
        alert_and_exit(@"The game could not be prepared", tail.length ? tail : @"The converter stopped without a message.");
    }
}

/* ------------------------------------------------------------ finding the game */
static bool folder_is_supported_game(NSString *converter, NSString *dir)
{
    if (!valid_game_folder(dir)) return false;
    NSPipe *out = [NSPipe pipe];
    NSTask *t = converter_task(converter, @[@"--supported", dir], out);
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) return false;
    [out.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    return t.terminationStatus == 0;
}

/* Spotlight finds FEAR.exe anywhere it is indexed; the usual Steam and GOG folders are tried as well.
   Every candidate is checked against the exact supported version before it is offered. */
static NSString *find_game(NSString *converter)
{
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:DEFAULTS_KEY];
    if (saved) [candidates addObject:saved];
    NSPipe *out = [NSPipe pipe];
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/mdfind"];
    t.arguments = @[@"-name", @"FEAR.exe"];
    t.standardOutput = out; t.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *err = nil;
    if ([t launchAndReturnError:&err]) {
        NSData *data = [out.fileHandleForReading readDataToEndOfFile];
        [t waitUntilExit];
        for (NSString *line in [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] componentsSeparatedByString:@"\n"])
            if ([line.lastPathComponent caseInsensitiveCompare:@"FEAR.exe"] == NSOrderedSame) [candidates addObject:line.stringByDeletingLastPathComponent];
    }
    NSString *home = NSHomeDirectory();
    NSArray *roots = @[[home stringByAppendingPathComponent:@"Library/Application Support/Steam/steamapps/common"],
                       [home stringByAppendingPathComponent:@"Games"], [home stringByAppendingPathComponent:@"Downloads"],
                       [home stringByAppendingPathComponent:@"Desktop"], @"/Applications"];
    for (NSString *root in roots)
        for (NSString *sub in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]) {
            NSString *dir = [root stringByAppendingPathComponent:sub];
            [candidates addObject:dir];
            [candidates addObject:[dir stringByAppendingPathComponent:@"F.E.A.R. Platinum Collection"]];
        }
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *dir in candidates) {
        if ([seen containsObject:dir]) continue;
        [seen addObject:dir];
        if (folder_is_supported_game(converter, dir)) return dir;
    }
    return nil;
}

/* ------------------------------------------------------------ settings
   MetalFX and HDR are read by the renderer from these preferences (gp_present.m). The resolution is the game's own
   setting: it lives in the game's settings.cfg in the user folder, which is edited here. */
static NSString *settings_cfg_path(void)
{
    return [NSString stringWithFormat:@"%s/Shared Documents/Monolith Productions/FEAR/settings.cfg", gp_user_root()];
}
static void write_resolution(int w, int h)
{
    NSString *path = settings_cfg_path();
    NSString *dir = path.stringByDeletingLastPathComponent;
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *l in [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"])
        if (l.length && ![l hasPrefix:@"\"ScreenWidth\""] && ![l hasPrefix:@"\"ScreenHeight\""] && ![l hasPrefix:@"\"BitDepth\""]) [lines addObject:l];
    [lines addObject:@"\"BitDepth\" \"32\""];
    [lines addObject:[NSString stringWithFormat:@"\"ScreenWidth\" \"%d\"", w]];
    [lines addObject:[NSString stringWithFormat:@"\"ScreenHeight\" \"%d\"", h]];
    NSError *err = nil;
    if (![[[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err])
        alert_and_exit(@"Cannot save the settings", err.localizedDescription);
}
static void current_resolution(int *w, int *h)
{
    *w = 1920; *h = 1080;
    for (NSString *l in [[NSString stringWithContentsOfFile:settings_cfg_path() encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"]) {
        NSArray *p = [l componentsSeparatedByString:@"\""];               // "Key" "Value"
        if (p.count >= 4 && [p[1] isEqualToString:@"ScreenWidth"]) *w = [p[3] intValue];
        if (p.count >= 4 && [p[1] isEqualToString:@"ScreenHeight"]) *h = [p[3] intValue];
    }
}

/* ------------------------------------------------------------ launcher window */
@interface LauncherController : NSObject
@property (strong) NSWindow *window;
@property (strong) NSTextField *gamePath;
@property (strong) NSPopUpButton *resolution;
@property (strong) NSButton *metalfx, *hdr, *playButton;
@property (copy) NSString *game;
@property BOOL play;
@end
@implementation LauncherController
- (void)playPressed:(id)sender { (void)sender; self.play = YES; [NSApp stopModal]; }
- (void)quitPressed:(id)sender { (void)sender; [NSApp stopModal]; }
- (void)changeGame:(id)sender
{
    (void)sender;
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES; p.canChooseFiles = NO;
    p.message = @"Choose your F.E.A.R. game folder (the one containing FEAR.exe).";
    p.prompt = @"Choose";
    if ([p runModal] != NSModalResponseOK) return;
    NSString *converter = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"converter"];
    if (!folder_is_supported_game(converter, p.URL.path)) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"This is not a supported copy of F.E.A.R.";
        a.informativeText = @"The folder must contain FEAR.exe from the F.E.A.R. Platinum Collection (version 1.08) with its game files.";
        [a runModal];
        return;
    }
    self.game = p.URL.path;
    self.gamePath.stringValue = self.game;
    self.playButton.enabled = YES;
}
@end

static NSTextField *label(NSString *text, NSRect frame, BOOL bold)
{
    NSTextField *f = [NSTextField labelWithString:text];
    f.frame = frame;
    if (bold) f.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    return f;
}

/* shows the launcher; returns the chosen game folder when Play is pressed, exits when the window is closed */
static NSString *run_launcher_window(NSString *found_game)
{
    LauncherController *c = [LauncherController new];
    c.game = found_game;
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 360)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    w.title = APP_NAME;
    NSView *v = w.contentView;
    [v addSubview:label(@"F.E.A.R.", NSMakeRect(24, 314, 472, 26), YES)];
    [v addSubview:label(@"Game folder", NSMakeRect(24, 284, 472, 18), NO)];
    c.gamePath = [NSTextField labelWithString:found_game ?: @"F.E.A.R. was not found. Choose the folder that contains FEAR.exe."];
    c.gamePath.frame = NSMakeRect(24, 262, 380, 18);
    c.gamePath.lineBreakMode = NSLineBreakByTruncatingMiddle;
    c.gamePath.textColor = found_game ? NSColor.labelColor : NSColor.systemRedColor;
    [v addSubview:c.gamePath];
    NSButton *change = [NSButton buttonWithTitle:@"Change…" target:c action:@selector(changeGame:)];
    change.frame = NSMakeRect(412, 256, 84, 28);
    [v addSubview:change];

    [v addSubview:label(@"Graphics", NSMakeRect(24, 224, 472, 18), YES)];
    [v addSubview:label(@"Resolution", NSMakeRect(24, 196, 100, 18), NO)];
    c.resolution = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(130, 190, 200, 28) pullsDown:NO];
    static const int sizes[][2] = { {1280,720}, {1600,900}, {1920,1080}, {2560,1440}, {3840,2160} };
    int cw, ch;
    current_resolution(&cw, &ch);
    NSInteger sel = 2;
    for (int i = 0; i < 5; i++) {
        [c.resolution addItemWithTitle:[NSString stringWithFormat:@"%d × %d", sizes[i][0], sizes[i][1]]];
        if (sizes[i][0] == cw && sizes[i][1] == ch) sel = i;
    }
    [c.resolution selectItemAtIndex:sel];
    [v addSubview:c.resolution];

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    c.metalfx = [NSButton checkboxWithTitle:@"MetalFX upscaling (render at the game's resolution, upscale to the window)" target:nil action:nil];
    c.metalfx.frame = NSMakeRect(24, 156, 472, 20);
    c.metalfx.state = [d boolForKey:@"MetalFX"] ? NSControlStateValueOn : NSControlStateValueOff;
    [v addSubview:c.metalfx];
    c.hdr = [NSButton checkboxWithTitle:@"HDR (expands bright highlights on an HDR display; the game itself is not HDR)" target:nil action:nil];
    c.hdr.frame = NSMakeRect(24, 128, 472, 20);
    c.hdr.state = [d boolForKey:@"HDR"] ? NSControlStateValueOn : NSControlStateValueOff;
    [v addSubview:c.hdr];
    NSTextField *note = label(@"Controller: plug in or pair an Xbox or PlayStation controller before you press Play. Its buttons are in gamepad.cfg.", NSMakeRect(24, 82, 472, 36), NO);
    note.textColor = NSColor.secondaryLabelColor; note.lineBreakMode = NSLineBreakByWordWrapping;
    [v addSubview:note];

    c.playButton = [NSButton buttonWithTitle:@"Play" target:c action:@selector(playPressed:)];
    c.playButton.frame = NSMakeRect(396, 24, 100, 32);
    c.playButton.keyEquivalent = @"\r";
    c.playButton.enabled = found_game != nil;
    [v addSubview:c.playButton];
    NSButton *quit = [NSButton buttonWithTitle:@"Quit" target:c action:@selector(quitPressed:)];
    quit.frame = NSMakeRect(288, 24, 100, 32);
    [v addSubview:quit];

    [w center];
    [w makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    c.window = w;
    [NSApp runModalForWindow:w];
    [w orderOut:nil];
    if (!c.play || !c.game) exit(0);
    [d setBool:c.metalfx.state == NSControlStateValueOn forKey:@"MetalFX"];
    [d setBool:c.hdr.state == NSControlStateValueOn forKey:@"HDR"];
    [d setObject:c.game forKey:DEFAULTS_KEY];
    write_resolution(sizes[c.resolution.indexOfSelectedItem][0], sizes[c.resolution.indexOfSelectedItem][1]);
    return c.game;
}

void gp_launcher_prepare(char *game_out, size_t game_cap, char *cache_out, size_t cache_cap)
{
    @autoreleasepool {
        gp_app_init();
        NSString *converter = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"converter"];
        if (![NSFileManager.defaultManager fileExistsAtPath:[converter stringByAppendingPathComponent:@"tools/convert.py"]])
            alert_and_exit(@"Incomplete app", @"The converter is missing from this app. Run the runtime from a terminal with a cache and game folder, or rebuild the app.");
        NSString *game = run_launcher_window(find_game(converter));
        NSString *cache = [support_dir() stringByAppendingPathComponent:@"cache"];
        if (!cache_is_valid(converter, game, cache)) {
            convert_with_progress(converter, game, cache);
        }
        snprintf(game_out, game_cap, "%s", game.UTF8String);
        snprintf(cache_out, cache_cap, "%s", cache.UTF8String);
    }
}
