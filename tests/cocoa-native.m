/* Native offscreen contract. Include the implementation to feed real NSEvents
 * through its one translator without adding a production injection API. */
#include "check.h"
#include "../src/platform/cocoa_shim.m"

int main(int argc, char **argv) {
    @autoreleasepool {
        (void)argv;
        CHECK(setenv("XODB_MAC_OFFSCREEN", "1", 1) == 0);
        CHECK(setenv("XODB_MAC_PRIVATE_PASTEBOARD", "1", 1) == 0);
        CHECK(xcocoa_open(1000, 640, "owned Cocoa contract"));
        uint32_t width = 0, height = 0; float scale = 0;
        xcocoa_size(&width, &height, &scale);
        CHECK(width == (argc > 1 ? 999u : 1000u) && height == 640 && scale == 1);
        CHECK(!xcocoa_open(1000, 640, "duplicate"));
        xcocoa_set_scale(2);
        CHECK(layer.drawableSize.width == 2000 && layer.drawableSize.height == 1280);
        xcocoa_set_scale(NAN);
        CHECK(layer.contentsScale == 2);
        struct xcocoa_event event;
        NSEvent *key = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
            modifierFlags:NSEventModifierFlagShift timestamp:1 windowNumber:0 context:nil
            characters:@"Q" charactersIgnoringModifiers:@"Q" isARepeat:NO keyCode:kVK_ANSI_Q];
        handle(key);
        CHECK(xcocoa_next(&event) && event.kind == XCOCOA_EVENT_KEY);
        CHECK(event.code == 16 && event.sym == 'Q' && event.shortcut == 'q');
        CHECK(event.flags == XCOCOA_PRESSED && event.mods == XCOCOA_SHIFT);
        CHECK(event.text_len == 1 && event.text[0] == 'Q');
        key = [NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint
            modifierFlags:0 timestamp:2 windowNumber:0 context:nil
            characters:@"a" charactersIgnoringModifiers:@"a" isARepeat:NO keyCode:kVK_ANSI_A];
        handle(key); // An unpaired release is still a release, never a press.
        CHECK(xcocoa_next(&event) && !event.flags && event.code == 30);
        XCDelegate *test_delegate = [XCDelegate new];
        CHECK([test_delegate applicationShouldTerminate:[NSApplication sharedApplication]] == NSTerminateCancel);
        CHECK(xcocoa_next(&event) && event.kind == XCOCOA_EVENT_CLOSE);
        for (unsigned i = 0; i < QCAP + 5; ++i) push((struct xcocoa_event){ .kind = XCOCOA_EVENT_MOTION });
        [test_delegate requestClose:nil];
        CHECK(xcocoa_next(&event) && event.kind == XCOCOA_EVENT_CLOSE);
        unsigned count = 0;
        while (xcocoa_next(&event)) ++count;
        CHECK(count == QCAP); // Burst, then silence; no later event needed for close.
        VkInstance instance = VK_NULL_HANDLE;
        const char *extensions[] = { "VK_KHR_surface", "VK_EXT_metal_surface" };
        VkInstanceCreateInfo info = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .enabledExtensionCount = 2, .ppEnabledExtensionNames = extensions };
        CHECK(vkCreateInstance(&info, NULL, &instance) == VK_SUCCESS);
        VkSurfaceKHR surface = VK_NULL_HANDLE;
        CHECK(xcocoa_create_surface(instance, (void **)&surface) == VK_SUCCESS && surface);
        vkDestroySurfaceKHR(instance, surface, NULL);
        vkDestroyInstance(instance, NULL);
        xcocoa_close();
        CHECK(xcocoa_open(900, 600, "reopen"));
        CHECK(!xcocoa_next(&event));
        xcocoa_close();
        puts("Cocoa native offscreen: scale, translation, close, bounded queue, Metal surface and reopen passed");
    }
    return 0;
}
