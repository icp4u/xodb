/* Native build stub for -Dplatform=cocoa. The AppKit implementation replaces
 * this file once a Mac build/test lane is available. */
#include "cocoa_shim.h"

int xcocoa_open(uint32_t width, uint32_t height, const char *title) {
    (void)width; (void)height; (void)title;
    return 0;
}
void xcocoa_close(void) {}
void xcocoa_pump(int32_t timeout_ms) { (void)timeout_ms; }
int xcocoa_next(struct xcocoa_event *event) { (void)event; return 0; }
void xcocoa_size(uint32_t *width, uint32_t *height, float *scale) {
    if (width) *width = 0;
    if (height) *height = 0;
    if (scale) *scale = 1.0f;
}
void xcocoa_set_scale(float scale) { (void)scale; }
void xcocoa_set_live_resize(void (*draw)(void *), void *context) { (void)draw; (void)context; }
void *xcocoa_pool_push(void) { return 0; }
void xcocoa_pool_pop(void *pool) { (void)pool; }
int xcocoa_test_step(uint64_t frame, int presented_state) { (void)frame; (void)presented_state; return 0; }
const char *xcocoa_test_text(void) { return ""; }
uint64_t xcocoa_resident_bytes(void) { return 0; }
void xcocoa_set_title(const char *title) { (void)title; }
void xcocoa_set_app_id(const char *app_id) { (void)app_id; }
void xcocoa_set_min_size(int32_t width, int32_t height) { (void)width; (void)height; }
void xcocoa_set_own_frame(int enabled) { (void)enabled; }
void xcocoa_set_cursor(uint32_t cursor) { (void)cursor; }
void xcocoa_minimize(void) {}
void xcocoa_toggle_maximized(void) {}
void xcocoa_begin_move(void) {}
void xcocoa_begin_resize(uint32_t edge) { (void)edge; }
int xcocoa_clip_set(const char *bytes, size_t size) { (void)bytes; (void)size; return 0; }
int xcocoa_clip_get(char *bytes, size_t capacity, size_t *size) {
    (void)bytes; (void)capacity;
    if (size) *size = 0;
    return XCOCOA_CLIP_UNAVAILABLE;
}
int32_t xcocoa_create_surface(void *instance, void **surface) {
    (void)instance;
    if (surface) *surface = 0;
    return -7; /* VK_ERROR_EXTENSION_NOT_PRESENT */
}
