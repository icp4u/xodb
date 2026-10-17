/* Diagnostic input, opt-in only. No global event posting or Accessibility.
 * One bounded line is retained; no script-sized allocation or per-frame growth.
 * Native tests include the shim to exercise this same translation path. */
#include <stdio.h>
#include <errno.h>
#include <ctype.h>
static FILE *test_file;
static int test_started, test_pending;
static unsigned test_lines;
static uint64_t test_frame, test_previous;
static char test_line[4098], *test_command, *test_text;
static NSTimer *test_drag;

static void test_close(void) {
    if (test_file) fclose(test_file);
    test_file = NULL;
    [test_drag invalidate]; test_drag = nil;
    test_started = test_pending = 0; test_lines = 0; test_previous = 0;
    test_text = NULL;
}
const char *xcocoa_test_text(void) { return test_text ? test_text : ""; }
static char *test_token(char **p) {
    char *s = *p;
    while (isspace((unsigned char)*s)) s++;
    if (!*s) { *p = s; return NULL; }
    char *end = s;
    while (*end && !isspace((unsigned char)*end)) end++;
    if (*end) *end++ = 0;
    *p = end;
    return s;
}
static int test_number(char **p, double *out, double low, double high) {
    char *s = test_token(p), *end;
    if (!s) return 0;
    errno = 0;
    double n = strtod(s, &end);
    if (errno || end == s || *end || !isfinite(n) || n < low || n > high) return 0;
    *out = n; return 1;
}
static NSString *test_chars(const char *s) {
    if (!s) return nil;
    if (!strcmp(s, "CR")) return @"\r";
    if (!strcmp(s, "ESC")) return @"\x1b";
    if (!strcmp(s, "TAB")) return @"\t";
    if (!strcmp(s, "UP")) return @"\uF700";
    if (!strcmp(s, "DOWN")) return @"\uF701";
    if (!strcmp(s, "LEFT")) return @"\uF702";
    if (!strcmp(s, "RIGHT")) return @"\uF703";
    if (!strcmp(s, "-")) return @"";
    return [NSString stringWithUTF8String:s];
}
static void test_key(uint16_t vk, NSString *chars, NSString *unmod, unsigned mods) {
    NSEventModifierFlags flags = (mods & 1 ? NSEventModifierFlagShift : 0) |
        (mods & 2 ? NSEventModifierFlagControl : 0) | (mods & 4 ? NSEventModifierFlagOption : 0) |
        (mods & 8 ? NSEventModifierFlagCommand : 0);
    for (unsigned down = 1; ; down--) {
        NSEvent *event = [NSEvent keyEventWithType:down ? NSEventTypeKeyDown : NSEventTypeKeyUp location:NSZeroPoint
            modifierFlags:flags timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:win.windowNumber context:nil
            characters:chars charactersIgnoringModifiers:unmod isARepeat:NO keyCode:vk];
        // Same order as xcocoa_pump: menu key equivalents (Cmd-Q/W) first.
        if (!(down && [NSApp.mainMenu performKeyEquivalent:event])) handle(event);
        if (!down) break;
    }
}
static void test_mouse(NSEventType type, double x, double y) {
    NSPoint p = NSMakePoint(x, cur_h - y);
    if (view && !offscreen) p = [view convertPoint:p toView:nil];
    handle([NSEvent mouseEventWithType:type location:p modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:win.windowNumber context:nil
        eventNumber:0 clickCount:1 pressure:type == NSEventTypeLeftMouseDown ? 1 : 0]);
}
// A CG scroll event has screen coordinates/no window. Supply only its position
// through a small NSEvent adapter; all deltas/flags still use handle().
@interface XCTestScroll : NSEvent
@property NSEvent *source;
@property NSPoint point;
@end
@implementation XCTestScroll
- (NSEventType)type { return NSEventTypeScrollWheel; }
- (NSTimeInterval)timestamp { return self.source.timestamp; }
- (NSEventModifierFlags)modifierFlags { return self.source.modifierFlags; }
- (NSPoint)locationInWindow { return self.point; }
- (BOOL)hasPreciseScrollingDeltas { return self.source.hasPreciseScrollingDeltas; }
- (CGFloat)scrollingDeltaY { return self.source.scrollingDeltaY; }
@end
static void test_post_drag(NSEventType type, NSPoint screen, int number) {
    if (!win) return;
    NSPoint origin = win.frame.origin;
    NSEvent *event = [NSEvent mouseEventWithType:type location:NSMakePoint(screen.x - origin.x, screen.y - origin.y)
        modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:win.windowNumber context:nil
        eventNumber:number clickCount:1 pressure:type == NSEventTypeLeftMouseUp ? 0 : 1];
    [NSApp postEvent:event atStart:NO];
}
static int test_run(char *line) {
    char *p = line, *cmd = test_token(&p);
    if (!cmd) return -1;
    double x, y, n, precise;
    if (!strcmp(cmd, "state")) return test_token(&p) ? -1 : 2;
    if (!strcmp(cmd, "close")) {
        if (test_token(&p)) return -1;
        push((struct xcocoa_event){ .kind = XCOCOA_EVENT_CLOSE }); return 1;
    }
    if (!strcmp(cmd, "clipset") || !strcmp(cmd, "clipget")) {
        // A script must never touch the user's general pasteboard.
        if (!getenv("XODB_MAC_PRIVATE_PASTEBOARD")) return -1;
        while (isspace((unsigned char)*p)) p++;
        test_text = p;
        if (!strcmp(cmd, "clipget")) return *p ? -1 : 4;
        return 3;
    }
    if (!strcmp(cmd, "key")) {
        if (!test_number(&p, &n, 0, 127) || trunc(n) != n) return -1;
        NSString *chars = test_chars(test_token(&p)), *unmod = test_chars(test_token(&p));
        if (!chars || !unmod || !test_number(&p, &x, 0, 15) || trunc(x) != x || test_token(&p)) return -1;
        test_key((uint16_t)n, chars, unmod, (unsigned)x); return 1;
    }
    if (!strcmp(cmd, "text")) {
        while (isspace((unsigned char)*p)) p++;
        NSString *text = [NSString stringWithUTF8String:p];
        if (!text || text.length > 120) return -1; // Two events per character, below queue capacity.
        for (NSUInteger i = 0; i < text.length;) {
            NSRange range = [text rangeOfComposedCharacterSequenceAtIndex:i];
            NSString *ch = [text substringWithRange:range];
            test_key(0, ch, ch, 0); i = NSMaxRange(range);
        }
        return 1;
    }
    if (!test_number(&p, &x, -16384, 16384) || !test_number(&p, &y, -16384, 16384)) return -1;
    if (!strcmp(cmd, "click") || !strcmp(cmd, "move")) {
        if (test_token(&p)) return -1;
        test_mouse(NSEventTypeMouseMoved, x, y);
        if (!strcmp(cmd, "click")) {
            test_mouse(NSEventTypeLeftMouseDown, x, y);
            test_mouse(NSEventTypeLeftMouseUp, x, y);
        }
        return 1;
    }
    if (!strcmp(cmd, "scroll")) {
        if (!test_number(&p, &n, -16384, 16384) || !test_number(&p, &precise, 0, 1) ||
            trunc(precise) != precise || test_token(&p)) return -1;
        test_mouse(NSEventTypeMouseMoved, x, y);
        CGEventRef event = CGEventCreateScrollWheelEvent(NULL, precise ? kCGScrollEventUnitPixel : kCGScrollEventUnitLine, 1, (int32_t)-n);
        if (!event) return -1;
        XCTestScroll *scroll = [XCTestScroll new];
        scroll.source = [NSEvent eventWithCGEvent:event]; CFRelease(event);
        scroll.point = NSMakePoint(x, cur_h - y);
        if (view && !offscreen) scroll.point = [view convertPoint:scroll.point toView:nil];
        handle(scroll); return 1;
    }
    if (!strcmp(cmd, "resize")) {
        if (x < 1 || y < 1 || trunc(x) != x || trunc(y) != y || test_token(&p)) return -1;
        if (offscreen) {
            cur_w = (uint32_t)x; cur_h = (uint32_t)y;
            layer.frame = CGRectMake(0, 0, x, y);
            xcocoa_set_scale(pixel_scale);
            push((struct xcocoa_event){ .kind = XCOCOA_EVENT_RESIZE, .width = (int32_t)x, .height = (int32_t)y, .scale = cur_scale });
        } else { [win setContentSize:NSMakeSize(x, y)]; note_size(); }
        return 1;
    }
    if (!strcmp(cmd, "dragresize")) {
        if (!test_number(&p, &n, 1, 3600) || trunc(n) != n || test_token(&p) || offscreen || test_drag.valid) return -1;
        NSRect frame = win.frame;
        NSPoint at = NSMakePoint(NSMaxX(frame) - 2, NSMinY(frame) + 2);
        test_post_drag(NSEventTypeLeftMouseDown, at, 0);
        __block int i = 0;
        test_drag = [NSTimer timerWithTimeInterval:1 / 60.0 repeats:YES block:^(NSTimer *timer) {
            @autoreleasepool {
                ++i;
                double k = fmin(i / n, 1);
                test_post_drag(i <= n ? NSEventTypeLeftMouseDragged : NSEventTypeLeftMouseUp, NSMakePoint(at.x + x * k, at.y - y * k), i);
                if (i > n) [timer invalidate];
            }
        }];
        [NSRunLoop.currentRunLoop addTimer:test_drag forMode:NSRunLoopCommonModes];
        return 1;
    }
    return -1; // Includes optional shot, which this client does not implement.
}
int xcocoa_test_step(uint64_t frame, int stopped_presented) {
    @autoreleasepool {
        if (!test_started) {
            test_started = 1;
            const char *path = getenv("XODB_TEST_SCRIPT");
            if (!path) return 0;
            test_file = fopen(path, "r");
            if (!test_file) return -1;
        }
        if (!test_file) return 0;
        while (!test_pending) {
            if (!fgets(test_line, sizeof test_line, test_file)) {
                int failed = ferror(test_file);
                fclose(test_file); test_file = NULL;
                return failed ? -1 : 0;
            }
            if (++test_lines > 4096 || strlen(test_line) > 4096) return -1;
            test_line[strcspn(test_line, "\r\n")] = 0;
            char *comment = strchr(test_line, '#');
            if (comment) *comment = 0;
            char *p = test_line, *s = test_token(&p), *end;
            if (!s) continue;
            errno = 0;
            if (*s < '0' || *s > '9') return -1;
            test_frame = strtoull(s, &end, 10);
            if (errno || *end || test_frame < test_previous) return -1;
            test_previous = test_frame; test_command = p; test_pending = 1;
        }
        if (frame < test_frame || test_drag.valid) return 0;
        if (!strcmp(test_command, "stopped")) {
            if (!stopped_presented) return 0;
            test_pending = 0;
            return 1;
        }
        test_pending = 0;
        return test_run(test_command);
    }
}
