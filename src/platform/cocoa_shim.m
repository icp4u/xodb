// AppKit owns the window and native event translation; Zig owns the frame loop.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Carbon/Carbon.h> // Header-only kVK constants; do not link Carbon.
#define VK_USE_PLATFORM_METAL_EXT 1
#include <vulkan/vulkan.h>
#include "cocoa_shim.h"
#include "../runtime/xrt_log.h"
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <mach/mach.h>

extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *);
void *xcocoa_pool_push(void) { return objc_autoreleasePoolPush(); }
void xcocoa_pool_pop(void *pool) { objc_autoreleasePoolPop(pool); }
uint64_t xcocoa_resident_bytes(void) {
    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.resident_size;
}

// Diagnostic only, from the window's own occlusion notification. Never query
// the window server in-process (CGWindowList*): that call holds the connection's
// transaction lock and stalls the main thread's commit that shows the window.
static double startup_start_ms; // 0: not tracing, or already reported
static double monotonic_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}
static void startup_trace_begin(void) {
    startup_start_ms = 0;
    if (!getenv("XODB_STARTUP_TRACE")) return;
    struct kinfo_proc process = {0}; size_t size = sizeof process;
    int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    struct timeval wall;
    if (sysctl(mib, 4, &process, &size, NULL, 0) || size != sizeof process || gettimeofday(&wall, NULL)) return;
    startup_start_ms = monotonic_ms() - ((wall.tv_sec - process.kp_proc.p_starttime.tv_sec) * 1000.0 +
        (wall.tv_usec - process.kp_proc.p_starttime.tv_usec) / 1000.0);
}

@interface XCView : NSView
@end
@implementation XCView
- (BOOL)wantsUpdateLayer { return YES; }
- (CALayer *)makeBackingLayer { return [CAMetalLayer layer]; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (void)keyDown:(NSEvent *)event { (void)event; }
@end

#define QCAP 256
static struct xcocoa_event queue[QCAP];
static unsigned q_head, q_count;
static int close_pending, release_pending, offscreen, resize_drawing;
static NSWindow *win;
static XCView *view;
static CAMetalLayer *layer;
static uint32_t cur_w, cur_h;
static float cur_scale = 1, pixel_scale = 1;
static void (*resize_draw)(void *);
static void *resize_context;
static void test_close(void);

static void push(struct xcocoa_event event) {
    // A close must survive a full input queue, even after the producer goes idle.
    if (event.kind == XCOCOA_EVENT_CLOSE) { close_pending = 1; return; }
    if (event.kind == XCOCOA_EVENT_RELEASE_POINTER) { release_pending = 1; return; }
    if (q_count == QCAP) return;
    queue[(q_head + q_count++) % QCAP] = event;
}
int xcocoa_next(struct xcocoa_event *event) {
    if (close_pending) {
        close_pending = 0;
        *event = (struct xcocoa_event){ .kind = XCOCOA_EVENT_CLOSE };
        return 1;
    }
    if (!q_count) {
        if (!release_pending) return 0;
        release_pending = 0;
        *event = (struct xcocoa_event){ .kind = XCOCOA_EVENT_RELEASE_POINTER };
        return 1;
    }
    *event = queue[q_head]; q_head = (q_head + 1) % QCAP; q_count--;
    return 1;
}
static void note_size(void) {
    if (offscreen) return;
    NSSize size = view.bounds.size;
    float scale = (float)win.backingScaleFactor;
    if ((uint32_t)size.width == cur_w && (uint32_t)size.height == cur_h && scale == cur_scale) return;
    cur_w = (uint32_t)size.width; cur_h = (uint32_t)size.height; cur_scale = scale;
    layer.contentsScale = pixel_scale;
    layer.drawableSize = CGSizeMake(cur_w * pixel_scale, cur_h * pixel_scale);
    push((struct xcocoa_event){ .kind = XCOCOA_EVENT_RESIZE, .width = (int32_t)cur_w, .height = (int32_t)cur_h, .scale = scale });
}
@interface XCDelegate : NSObject <NSWindowDelegate, NSApplicationDelegate>
- (void)requestClose:(id)sender;
@end
@implementation XCDelegate
- (void)requestClose:(id)sender { (void)sender; push((struct xcocoa_event){ .kind = XCOCOA_EVENT_CLOSE }); }
- (BOOL)windowShouldClose:(NSWindow *)window { (void)window; [self requestClose:nil]; return NO; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    (void)app; [self requestClose:nil]; return NSTerminateCancel;
}
- (void)windowDidResize:(NSNotification *)notification {
    (void)notification; note_size();
    if (win.inLiveResize && resize_draw && !resize_drawing) {
        resize_drawing = 1; resize_draw(resize_context); resize_drawing = 0;
    }
}
- (void)windowDidEndLiveResize:(NSNotification *)notification {
    (void)notification; note_size();
    // AppKit consumes the resize mouse-up, so release our held pointer state.
    push((struct xcocoa_event){ .kind = XCOCOA_EVENT_RELEASE_POINTER });
}
- (void)windowDidChangeBackingProperties:(NSNotification *)notification { (void)notification; note_size(); }
- (void)windowDidChangeOcclusionState:(NSNotification *)notification {
    (void)notification;
    if (!startup_start_ms || !(win.occlusionState & NSWindowOcclusionStateVisible)) return;
    xrt_log(XRT_LOG_INFO, XRT_LOG_WINDOW, "xodb: own window visible in %.3f ms since process start (occlusion notification, ~10-17 ms after the window server)\n", monotonic_ms() - startup_start_ms);
    startup_start_ms = 0;
}
- (void)windowDidBecomeKey:(NSNotification *)notification {
    (void)notification; push((struct xcocoa_event){ .kind = XCOCOA_EVENT_FOCUS, .flags = XCOCOA_PRESSED });
}
- (void)windowDidResignKey:(NSNotification *)notification {
    (void)notification; push((struct xcocoa_event){ .kind = XCOCOA_EVENT_FOCUS });
}
@end
static XCDelegate *delegate;

// macOS virtual key (ANSI position) -> evdev code.
static uint16_t evdev_of(uint16_t vk) {
    static const struct { uint16_t vk, ev; } t[] = {
        {kVK_ANSI_A,30},{kVK_ANSI_S,31},{kVK_ANSI_D,32},{kVK_ANSI_F,33},{kVK_ANSI_H,35},{kVK_ANSI_G,34},{kVK_ANSI_Z,44},{kVK_ANSI_X,45},
        {kVK_ANSI_C,46},{kVK_ANSI_V,47},{kVK_ANSI_B,48},{kVK_ANSI_Q,16},{kVK_ANSI_W,17},{kVK_ANSI_E,18},{kVK_ANSI_R,19},{kVK_ANSI_Y,21},
        {kVK_ANSI_T,20},{kVK_ANSI_1,2},{kVK_ANSI_2,3},{kVK_ANSI_3,4},{kVK_ANSI_4,5},{kVK_ANSI_6,7},{kVK_ANSI_5,6},{kVK_ANSI_Equal,13},
        {kVK_ANSI_9,10},{kVK_ANSI_7,8},{kVK_ANSI_Minus,12},{kVK_ANSI_8,9},{kVK_ANSI_0,11},{kVK_ANSI_RightBracket,27},{kVK_ANSI_O,24},
        {kVK_ANSI_U,22},{kVK_ANSI_LeftBracket,26},{kVK_ANSI_I,23},{kVK_ANSI_P,25},{kVK_Return,28},{kVK_ANSI_L,38},{kVK_ANSI_J,36},
        {kVK_ANSI_Quote,40},{kVK_ANSI_K,37},{kVK_ANSI_Semicolon,39},{kVK_ANSI_Backslash,43},{kVK_ANSI_Comma,51},{kVK_ANSI_Slash,53},
        {kVK_ANSI_N,49},{kVK_ANSI_M,50},{kVK_ANSI_Period,52},{kVK_Tab,15},{kVK_Space,57},{kVK_ANSI_Grave,41},{kVK_Delete,14},{kVK_Escape,1},
        {kVK_Command,125},{kVK_RightCommand,126},{kVK_Shift,42},{kVK_RightShift,54},{kVK_CapsLock,58},{kVK_Option,56},{kVK_RightOption,100},
        {kVK_Control,29},{kVK_RightControl,97},{kVK_F1,59},{kVK_F2,60},{kVK_F3,61},{kVK_F4,62},{kVK_F5,63},{kVK_F6,64},{kVK_F7,65},{kVK_F8,66},
        {kVK_F9,67},{kVK_F10,68},{kVK_F11,87},{kVK_F12,88},{kVK_Home,102},{kVK_End,107},{kVK_PageUp,104},{kVK_PageDown,109},
        {kVK_ForwardDelete,111},{kVK_LeftArrow,105},{kVK_RightArrow,106},{kVK_DownArrow,108},{kVK_UpArrow,103},{kVK_ANSI_KeypadEnter,96},
        {kVK_ISO_Section,86} };
    for (size_t i = 0; i < sizeof t / sizeof t[0]; i++) if (t[i].vk == vk) return t[i].ev;
    return 0;
}
// Keys whose keysym does not come from the produced character.
static uint32_t special_sym(uint16_t vk) {
    switch (vk) {
    case kVK_Return: return 0xff0d; case kVK_ANSI_KeypadEnter: return 0xff8d; case kVK_Tab: return 0xff09;
    case kVK_Delete: return 0xff08; case kVK_ForwardDelete: return 0xffff; case kVK_Escape: return 0xff1b;
    case kVK_Home: return 0xff50; case kVK_LeftArrow: return 0xff51; case kVK_UpArrow: return 0xff52;
    case kVK_RightArrow: return 0xff53; case kVK_DownArrow: return 0xff54; case kVK_PageUp: return 0xff55;
    case kVK_PageDown: return 0xff56; case kVK_End: return 0xff57;
    case kVK_F1: return 0xffbe; case kVK_F2: return 0xffbf; case kVK_F3: return 0xffc0; case kVK_F4: return 0xffc1;
    case kVK_F5: return 0xffc2; case kVK_F6: return 0xffc3; case kVK_F7: return 0xffc4; case kVK_F8: return 0xffc5;
    case kVK_F9: return 0xffc6; case kVK_F10: return 0xffc7; case kVK_F11: return 0xffc8; case kVK_F12: return 0xffc9;
    case kVK_Shift: return 0xffe1; case kVK_RightShift: return 0xffe2; case kVK_Control: return 0xffe3; case kVK_RightControl: return 0xffe4;
    case kVK_CapsLock: return 0xffe5; case kVK_Option: return 0xffe9; case kVK_RightOption: return 0xffea;
    case kVK_Command: return 0xffeb; case kVK_RightCommand: return 0xffec;
    }
    return 0;
}
static uint32_t sym_of_char(uint32_t cp) {
    if (cp < 0x20 || cp == 0x7f) return 0;
    if (cp >= 0xF700 && cp <= 0xF8FF) return 0; // AppKit function-key private use
    return cp < 0x100 ? cp : 0x01000000u + cp;
}
static uint32_t first_cp(NSString *s) {
    if (!s || [s length] == 0) return 0;
    UTF32Char cp = 0;
    [s getBytes:&cp maxLength:4 usedLength:NULL encoding:NSUTF32LittleEndianStringEncoding options:0 range:[s rangeOfComposedCharacterSequenceAtIndex:0] remainingRange:NULL];
    return cp;
}
static uint32_t mods_of(NSEventModifierFlags f) {
    return (f & NSEventModifierFlagShift ? XCOCOA_SHIFT : 0) | (f & NSEventModifierFlagControl ? XCOCOA_CTRL : 0) |
           (f & NSEventModifierFlagOption ? XCOCOA_ALT : 0) | (f & NSEventModifierFlagCommand ? XCOCOA_COMMAND : 0) |
           (f & NSEventModifierFlagCapsLock ? XCOCOA_CAPS : 0);
}
static void where(NSEvent *e, struct xcocoa_event *x) {
    NSPoint p = [e locationInWindow];
    if (view && !offscreen) p = [view convertPoint:p fromView:nil];
    x->x = (float)p.x; x->y = (float)(cur_h - p.y);
}

// The one translation path, for window-server events and injected ones alike.
static void handle(NSEvent *e) {
    struct xcocoa_event x = { 0 };
    x.time_ms = (uint32_t)([e timestamp] * 1000.0);
    x.mods = mods_of([e modifierFlags]);
    switch ([e type]) {
    case NSEventTypeKeyDown: case NSEventTypeKeyUp: {
        uint16_t vk = [e keyCode];
        x.kind = XCOCOA_EVENT_KEY; x.flags = [e type] == NSEventTypeKeyDown ? XCOCOA_PRESSED : 0; if ((x.flags & XCOCOA_PRESSED) && [e isARepeat]) x.flags |= XCOCOA_REPEAT;
        x.code = evdev_of(vk);
        uint32_t sp = special_sym(vk);
        uint32_t ch = first_cp([e characters]), base = first_cp([e charactersIgnoringModifiers]);
        x.sym = sp ? sp : sym_of_char(ch);
        if (!x.sym) x.sym = sym_of_char(base); // Ctrl+letter yields a control character
        uint32_t low = base;
        if (low < 0x80) { if (low >= 'A' && low <= 'Z') low += 32; }
        else low = first_cp([[e charactersIgnoringModifiers] lowercaseString]);
        x.shortcut = sp ? sp : sym_of_char(low);
        // Text: what the press typed, unless a command chord. Dead keys and input
        // methods need NSTextInputClient; composition is not implemented yet.
        if ((x.flags & XCOCOA_PRESSED) && !sp && !(x.mods & (XCOCOA_CTRL | XCOCOA_COMMAND)) && ch >= 0x20 && ch != 0x7f && !(ch >= 0xF700 && ch <= 0xF8FF)) {
            const char *u = [[e characters] UTF8String]; size_t n = u ? strlen(u) : 0;
            if (n > 0 && n <= sizeof x.text) { memcpy(x.text, u, n); x.text_len = (uint8_t)n; }
        }
        push(x); break; }
    case NSEventTypeFlagsChanged: {
        uint16_t vk = [e keyCode]; uint32_t bit = 0;
        switch (vk) { case kVK_Shift: case kVK_RightShift: bit = XCOCOA_SHIFT; break; case kVK_Control: case kVK_RightControl: bit = XCOCOA_CTRL; break;
            case kVK_Option: case kVK_RightOption: bit = XCOCOA_ALT; break; case kVK_Command: case kVK_RightCommand: bit = XCOCOA_COMMAND; break;
            case kVK_CapsLock: bit = XCOCOA_CAPS; break; }
        x.kind = XCOCOA_EVENT_KEY; x.code = evdev_of(vk); x.sym = x.shortcut = special_sym(vk);
        x.flags = (x.mods & bit) ? XCOCOA_PRESSED : 0; // left and right of one modifier are not told apart here
        push(x); break; }
    case NSEventTypeLeftMouseDown: case NSEventTypeLeftMouseUp: case NSEventTypeRightMouseDown: case NSEventTypeRightMouseUp:
    case NSEventTypeOtherMouseDown: case NSEventTypeOtherMouseUp: {
        NSEventType t = [e type];
        x.kind = XCOCOA_EVENT_BUTTON; where(e, &x);
        x.flags = (t == NSEventTypeLeftMouseDown || t == NSEventTypeRightMouseDown || t == NSEventTypeOtherMouseDown) ? XCOCOA_PRESSED : 0;
        x.code = (t == NSEventTypeLeftMouseDown || t == NSEventTypeLeftMouseUp) ? 272 : (t == NSEventTypeRightMouseDown || t == NSEventTypeRightMouseUp) ? 273 : 274;
        if (x.x < 0 || x.x >= cur_w || x.y < 0 || x.y >= cur_h) break; // native border/title bar
        push(x); break; }
    case NSEventTypeMouseMoved: case NSEventTypeLeftMouseDragged: case NSEventTypeRightMouseDragged: case NSEventTypeOtherMouseDragged:
        x.kind = XCOCOA_EVENT_MOTION; where(e, &x); push(x); break;
    case NSEventTypeScrollWheel:
        x.kind = XCOCOA_EVENT_SCROLL; where(e, &x); x.flags = [e hasPreciseScrollingDeltas] ? XCOCOA_PRECISE : 0; x.scroll_y = -(float)[e scrollingDeltaY]; push(x); break;
    default: break;
    }
}


int xcocoa_open(uint32_t width, uint32_t height, const char *title) {
    @autoreleasepool {
        if (layer || !width || !height || width > 16384 || height > 16384) return 0;
        q_head = q_count = 0; close_pending = release_pending = 0;
        cur_w = width; cur_h = height; pixel_scale = cur_scale = 1;
        offscreen = getenv("XODB_MAC_OFFSCREEN") != NULL;
        if (offscreen) {
            layer = [CAMetalLayer layer];
            layer.frame = CGRectMake(0, 0, width, height);
            layer.drawableSize = CGSizeMake(width, height);
            layer.contentsGravity = kCAGravityTopLeft;
            return layer != nil;
        }
        [NSApplication sharedApplication];
        if (![[NSScreen screens] count]) return 0;
        if (![[NSBundle mainBundle].bundlePath hasSuffix:@".app"])
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        const NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
            NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
        NSRect visible = [NSScreen mainScreen].visibleFrame;
        NSRect available = [NSWindow contentRectForFrameRect:visible styleMask:style];
        NSRect rect = NSMakeRect(visible.origin.x, visible.origin.y,
            fmin(width, available.size.width), fmin(height, available.size.height));
        win = [[NSWindow alloc] initWithContentRect:rect styleMask:style backing:NSBackingStoreBuffered defer:NO];
        if (!win) return 0;
        startup_trace_begin();
        delegate = [XCDelegate new];
        win.delegate = delegate; NSApp.delegate = delegate;
        win.releasedWhenClosed = NO; win.acceptsMouseMovedEvents = YES;
        if (title) win.title = [NSString stringWithUTF8String:title] ?: @"xodb";
        view = [[XCView alloc] initWithFrame:NSMakeRect(0, 0, rect.size.width, rect.size.height)];
        view.wantsLayer = YES; win.contentView = view;
        [win makeFirstResponder:view];
        layer = (CAMetalLayer *)view.layer;
        layer.contentsGravity = kCAGravityTopLeft;
        cur_scale = pixel_scale = (float)win.backingScaleFactor;
        cur_w = 0; note_size();
        NSMenu *menu = [NSMenu new], *application = [NSMenu new];
        NSMenuItem *application_item = [NSMenuItem new];
        application_item.submenu = application; [menu addItem:application_item];
        for (NSString *key in @[@"q", @"w"]) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[key isEqualToString:@"q"] ? @"Quit xodb" : @"Close Window"
                action:@selector(requestClose:) keyEquivalent:key];
            item.target = delegate; item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
            [application addItem:item];
        }
        NSApp.mainMenu = menu;
        [NSApp finishLaunching];
        [win makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        // Commit the new window before fonts, image metadata or replay parsing.
        xcocoa_pump(0);
        xrt_log(XRT_LOG_DEBUG, XRT_LOG_WINDOW, "Cocoa window requested=%ux%u actual=%ux%u backing=%.2f\n",
            width, height, cur_w, cur_h, (double)cur_scale);
        xrt_log(XRT_LOG_INFO, XRT_LOG_WINDOW, "xodb: window on screen %ux%u points, os scale %.2f, pixel scale %.2f\n",
            cur_w, cur_h, (double)cur_scale, (double)pixel_scale);
        return 1;
    }
}
void xcocoa_close(void) {
    @autoreleasepool {
        startup_start_ms = 0;
        resize_draw = NULL; resize_context = NULL;
        test_close();
        if (win) { win.delegate = nil; [win close]; }
        if (NSApp.delegate == delegate) NSApp.delegate = nil;
        NSApp.mainMenu = nil;
        win = nil; view = nil; layer = nil; delegate = nil;
        q_head = q_count = 0; close_pending = release_pending = 0; resize_drawing = 0;
    }
}
void xcocoa_pump(int32_t timeout_ms) {
    @autoreleasepool {
        if (offscreen) {
            if (timeout_ms > 0 && !q_count && !close_pending)
                [NSThread sleepForTimeInterval:timeout_ms / 1000.0];
            return;
        }
        NSDate *until = timeout_ms > 0 && !q_count && !close_pending ?
            [NSDate dateWithTimeIntervalSinceNow:timeout_ms / 1000.0] : [NSDate distantPast];
        NSEvent *event;
        while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode dequeue:YES])) {
            until = [NSDate distantPast];
            if (event.type == NSEventTypeKeyDown && [NSApp.mainMenu performKeyEquivalent:event]) continue;
            handle(event);
            if (event.type != NSEventTypeKeyDown && event.type != NSEventTypeKeyUp) [NSApp sendEvent:event];
        }
        [NSApp updateWindows]; note_size();
    }
}
void xcocoa_size(uint32_t *width, uint32_t *height, float *scale) {
    if (width) *width = cur_w;
    if (height) *height = cur_h;
    if (scale) *scale = cur_scale;
}
void xcocoa_set_scale(float scale) {
    if (!isfinite(scale) || scale < 0.5f || scale > 4) return;
    pixel_scale = scale; layer.contentsScale = scale;
    layer.drawableSize = CGSizeMake(cur_w * scale, cur_h * scale);
}
void xcocoa_set_live_resize(void (*draw)(void *), void *context) { resize_draw = draw; resize_context = context; }
void xcocoa_set_title(const char *title) { if (title && win) win.title = [NSString stringWithUTF8String:title] ?: @"xodb"; }
void xcocoa_set_app_id(const char *app_id) { (void)app_id; } // Bundle identifier comes from Info.plist.
void xcocoa_set_min_size(int32_t width, int32_t height) {
    if (width > 0 && height > 0) win.contentMinSize = NSMakeSize(width, height);
}
void xcocoa_set_own_frame(int enabled) {
    // Keep the native titled window; hiding chrome must not switch to borderless.
    win.titleVisibility = enabled ? NSWindowTitleHidden : NSWindowTitleVisible;
    win.titlebarAppearsTransparent = enabled != 0;
}
void xcocoa_set_cursor(uint32_t cursor) { if (!offscreen) [(cursor == 1 ? NSCursor.resizeLeftRightCursor : NSCursor.arrowCursor) set]; }
void xcocoa_minimize(void) { [win miniaturize:nil]; }
void xcocoa_toggle_maximized(void) { [win zoom:nil]; }
void xcocoa_begin_move(void) { if (NSApp.currentEvent) [win performWindowDragWithEvent:NSApp.currentEvent]; }
void xcocoa_begin_resize(uint32_t edge) { (void)edge; } // Native frame owns resize tracking.
static NSPasteboard *board(void) {
    static NSPasteboard *private_board;
    if (!getenv("XODB_MAC_PRIVATE_PASTEBOARD")) return NSPasteboard.generalPasteboard;
    if (!private_board) private_board = [NSPasteboard pasteboardWithUniqueName];
    return private_board;
}
int xcocoa_clip_set(const char *bytes, size_t size) {
    @autoreleasepool {
        if (size > 4096 || (!bytes && size)) return 0;
        NSString *text = [[NSString alloc] initWithBytes:bytes length:size encoding:NSUTF8StringEncoding];
        if (!text) return 0;
        NSPasteboard *pasteboard = board();
        [pasteboard clearContents];
        return [pasteboard setString:text forType:NSPasteboardTypeString] ? 1 : 0;
    }
}
int xcocoa_clip_get(char *bytes, size_t capacity, size_t *size) {
    @autoreleasepool {
        if (!size || (!bytes && capacity)) return XCOCOA_CLIP_UNAVAILABLE;
        *size = 0;
        NSString *text = [board() stringForType:NSPasteboardTypeString];
        const char *utf8 = text.UTF8String;
        if (!utf8) return XCOCOA_CLIP_UNAVAILABLE;
        size_t length = strlen(utf8);
        *size = length < capacity ? length : capacity;
        if (*size) memcpy(bytes, utf8, *size);
        return length > capacity ? XCOCOA_CLIP_TRUNCATED : XCOCOA_CLIP_READY;
    }
}
int32_t xcocoa_create_surface(void *instance, void **surface) {
    if (!surface) return VK_ERROR_INITIALIZATION_FAILED;
    *surface = NULL;
    if (!layer || !instance) return VK_ERROR_INITIALIZATION_FAILED;
    VkMetalSurfaceCreateInfoEXT info = { .sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT, .pLayer = layer };
    return vkCreateMetalSurfaceEXT((VkInstance)instance, &info, NULL, (VkSurfaceKHR *)surface);
}

#include "cocoa_script.inc"
