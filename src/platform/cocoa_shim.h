#ifndef XODB_COCOA_SHIM_H
#define XODB_COCOA_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum xcocoa_event_kind {
    XCOCOA_EVENT_NONE = 0,
    XCOCOA_EVENT_KEY,
    XCOCOA_EVENT_BUTTON,
    XCOCOA_EVENT_MOTION,
    XCOCOA_EVENT_SCROLL,
    XCOCOA_EVENT_RESIZE,
    XCOCOA_EVENT_CLOSE,
    XCOCOA_EVENT_FOCUS,
};

enum xcocoa_event_flag {
    XCOCOA_PRESSED = 1u << 0,
    XCOCOA_REPEAT = 1u << 1,
    XCOCOA_PRECISE = 1u << 2,
};

enum xcocoa_modifier {
    XCOCOA_SHIFT = 1u << 0,
    XCOCOA_CTRL = 1u << 1,
    XCOCOA_ALT = 1u << 2,
    XCOCOA_COMMAND = 1u << 3,
    XCOCOA_CAPS = 1u << 4,
    XCOCOA_NUM = 1u << 5,
};

enum xcocoa_clip_status {
    XCOCOA_CLIP_UNAVAILABLE = 0,
    XCOCOA_CLIP_READY = 1,
    XCOCOA_CLIP_TRUNCATED = 2,
};

struct xcocoa_event {
    uint32_t kind;
    uint32_t flags;
    uint32_t time_ms;
    uint32_t code;
    uint32_t sym;
    uint32_t shortcut;
    uint32_t mods;
    float x;
    float y;
    float scroll_y;
    int32_t width;
    int32_t height;
    float scale;
    uint8_t text_len;
    char text[16];
};

/* AppKit owns one window and translates NSEvents into this bounded queue.
 * The Linux skeleton implements the same ABI and returns unavailable. */
int xcocoa_open(uint32_t width, uint32_t height, const char *title);
void xcocoa_close(void);
void xcocoa_pump(int32_t timeout_ms);
int xcocoa_next(struct xcocoa_event *event);
void xcocoa_size(uint32_t *width, uint32_t *height, float *scale);
void xcocoa_set_scale(float scale);
/* Called on the AppKit thread during native resize tracking; never re-enter pump. */
void xcocoa_set_live_resize(void (*draw)(void *), void *context);
void xcocoa_set_title(const char *title);
void xcocoa_set_app_id(const char *app_id);
void xcocoa_set_min_size(int32_t width, int32_t height);
void xcocoa_set_own_frame(int enabled);
void xcocoa_set_cursor(uint32_t cursor);
void xcocoa_minimize(void);
void xcocoa_toggle_maximized(void);
void xcocoa_begin_move(void);
void xcocoa_begin_resize(uint32_t edge);
int xcocoa_clip_set(const char *bytes, size_t size);
int xcocoa_clip_get(char *bytes, size_t capacity, size_t *size);
/* Returns a VkResult value without making the shim header depend on Vulkan. */
int32_t xcocoa_create_surface(void *instance, void **surface);

#ifdef __cplusplus
}
#endif
#endif
