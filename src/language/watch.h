#ifndef XODB_LANGUAGE_WATCH_H
#define XODB_LANGUAGE_WATCH_H
#include <stddef.h>
#include <stdint.h>
#define XLW_ENTRIES 16
#define XLW_EXPRESSION 128
#define XLW_SAMPLE_BYTES 4096
/* Host-side stopped observations only. The runtime adapter resolves the frame
 * and binding anew before feeding a sample; this API never reads a target. */
enum xlw_language { XLW_LUA, XLW_PYTHON, XLW_PERL, XLW_JAVASCRIPT, XLW_RUBY };
enum xlw_result { XLW_OK, XLW_INVALID, XLW_FULL, XLW_NOMEM, XLW_STALE, XLW_NOT_FOUND };
enum xlw_state { XLW_PENDING, XLW_VALUE, XLW_UNAVAILABLE, XLW_RUNNING, XLW_GONE, XLW_CONTEXT_CHANGED };
enum xlw_observation { XLW_COMPLETE, XLW_INCOMPLETE, XLW_FRAME_GONE };
/* Complete bytes at the same observed slot do not prove that the activation
 * survived between stops. Consumers must preserve this qualifier on changes. */
enum xlw_comparison { XLW_NOT_COMPARED, XLW_SAME_SLOT_EQUAL, XLW_SAME_SLOT_DIFFERENT };
/* Location keys, not proof of an activation's lifetime between stops. The
 * adapter defines runtime/frame words and refuses ambiguous matches. Reused
 * frame locations cannot resurrect a watch once absence has been observed. */
struct xlw_scope {
    enum xlw_language language;
    uint64_t session, image, thread;
    uint64_t runtime[4], frame[4];
};
/* Canonical typed bytes are independent of display formatting/truncation.
 * Incomplete previews must use XLW_INCOMPLETE, never XLW_COMPLETE. */
struct xlw_sample {
    uint32_t kind;
    const void *bytes;
    size_t size;
    const char *type, *display;
};
struct xlw_value {
    uint64_t generation;
    uint32_t kind;
    const void *bytes;
    size_t size;
    const char *type, *display;
};
struct xlw_view {
    uint64_t id, observed_generation;
    struct xlw_scope scope;
    enum xlw_state state;
    enum xlw_comparison comparison;
    const char *expression, *reason;
    int changed, has_value, has_previous;
    struct xlw_value current, previous;
};
struct xlw_set;
struct xlw_set *xlw_create(void);
void xlw_destroy(struct xlw_set *);
enum xlw_result xlw_add(struct xlw_set *, const struct xlw_scope *, const char *, uint64_t *id);
enum xlw_result xlw_remove(struct xlw_set *, uint64_t id);
enum xlw_result xlw_feed(struct xlw_set *, uint64_t id, uint64_t generation,
                         const struct xlw_scope *, enum xlw_observation,
                         const struct xlw_sample *, const char *reason);
void xlw_running(struct xlw_set *);
size_t xlw_count(const struct xlw_set *);
/* Borrowed views expire on the next mutation/destruction; copy for UI/MCP. */
enum xlw_result xlw_get(const struct xlw_set *, size_t ordinal, struct xlw_view *);
#endif
