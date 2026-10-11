#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
/* Exercise the joined-result boundary with a transport that is busy for
 * background work. No scheduler timing or real process is involved. */
#include "check.h"
#include "../src/runtime/file_view.c"
#ifndef XODB_METADATA_SOURCE
#define XODB_METADATA_SOURCE "../src/debug/metadata_job.c"
#endif
#include XODB_METADATA_SOURCE

static unsigned background_calls, foreground_calls;
static enum xrt_status answer = XRT_OK;
enum xrt_status xrt_remote_background_file(const struct xrt_target *target,
        const struct xrt_call *call) {
    CHECK(target && call->op == XRT_RPC_FILE_READ && call->args[2] == 0);
    ++background_calls;
    return XRT_DISCOVERY_PENDING;
}
enum xrt_status xrt_remote_call(const struct xrt_target *target,
        const struct xrt_call *call) {
    CHECK(target && call->op == XRT_RPC_FILE_READ && call->args[2] == 0);
    ++foreground_calls;
    return answer;
}
enum xrt_status xrt_file_unchanged(int fd, const struct xrt_file_identity *id) {
    (void)fd; (void)id;
    return answer;
}
void xbo_progress(const struct xbo_object *value, struct xbo_progress *out) {
    (void)value; (void)out; CHECK(0); /* this fixture has no parser/cache */
}
void xjs_ranged_progress(const struct xjs_ranged *value, struct xjs_ranged_progress *out) {
    (void)value; (void)out; CHECK(0); /* this fixture has no parser/cache */
}
void xjs_image_progress(const struct xjs_image *value, struct xjs_image_progress *out) {
    (void)value; (void)out; CHECK(0); /* this fixture has no parser/cache */
}
void xcf_progress(const struct xcf_image *value, struct xcf_progress *out) {
    (void)value; (void)out; CHECK(0); /* this fixture has no parser/cache */
}
void xdi_progress(const struct xdi_index *value, struct xdi_progress *out) {
    (void)value; (void)out; CHECK(0); /* this fixture has no parser/cache */
}
void xbc_progress(const struct xbc_cache *value, struct xbc_progress *out) {
    (void)value; (void)out; CHECK(0); /* this fixture has no parser/cache */
}
int main(int argc, char **argv) {
    (void)argv;
    struct xrt_target target = {0};
    struct xrt_file_view view = {.target = &target, .background = 1, .remote_id = 1};
    struct xmd_job job = {.view = &view, .joined = 1,
        .mutex = PTHREAD_MUTEX_INITIALIZER, .working = {.state = XMD_READY}};
    CHECK(xrt_file_view_validate(&view) == XRT_DISCOVERY_PENDING);
    CHECK(background_calls == 1 && foreground_calls == 0); /* condition reached */
    enum xbo_status status = xmd_validate(&job);
    CHECK(status == (argc == 2 ? XBO_AGAIN : XBO_OK)); /* planted wrong result */
    CHECK(background_calls == 1 && foreground_calls == 1);
    answer = XRT_FILE_CHANGED;
    CHECK(xmd_validate(&job) == XBO_CHANGED);
    CHECK(job.working.state == XMD_FAILED);
    answer = XRT_OK;
    CHECK(xmd_validate(&job) == XBO_CHANGED); /* never resurrect stale bytes */
    CHECK(foreground_calls == 2);
    CHECK(pthread_mutex_destroy(&job.mutex) == 0);
    puts("ready metadata validates in foreground; background contention observed; stale bytes stay refused");
    return 0;
}
