#ifndef XODB_CLIPBOARD_H
#define XODB_CLIPBOARD_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
struct wl_display;
struct xclip;
#define XCLIP_LIMIT 4096
enum xclip_status { XCLIP_IDLE, XCLIP_PENDING, XCLIP_READY, XCLIP_TRUNCATED,
                    XCLIP_UNAVAILABLE, XCLIP_TIMEOUT, XCLIP_FAILED };
struct xclip_result {
    uint64_t destination, epoch;
    enum xclip_status status;
    size_t size;
    unsigned char bytes[XCLIP_LIMIT];
};
/* The display is borrowed. This object owns its protocol objects and pipes;
 * all calls occur on the display's dispatch thread. It never dispatches or
 * reads the display itself. The application's normal pump does that. */
struct xclip *xclip_create(struct wl_display *);
void xclip_destroy(struct xclip *);
/* Changing the active editor cancels both pending and completed old pastes. */
void xclip_focus(struct xclip *, uint64_t destination, uint64_t epoch);
enum xclip_status xclip_request(struct xclip *, bool primary);
bool xclip_take(struct xclip *, struct xclip_result *);
bool xclip_copy(struct xclip *, bool primary, uint32_t serial, const void *, size_t);
/* Nonblocking pipe progress; true requests a redraw. Pending I/O asks the
 * application to pump at most 20 ms apart, including hidden windows. */
bool xclip_tick(struct xclip *);
bool xclip_busy(const struct xclip *);
bool xclip_pending(const struct xclip *);
#endif
