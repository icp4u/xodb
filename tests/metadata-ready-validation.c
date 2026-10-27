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
static unsigned opens, closes;
static struct xrt_file_identity reopened_identity;
static unsigned parser_releases, cache_releases, lease_releases;
void xbo_destroy(struct xbo_object *value) { CHECK(!value); ++parser_releases; }
void xbc_destroy(struct xbc_cache *value) { CHECK(!value); ++cache_releases; }
void xcp_release(struct xcp_entry *value) { CHECK(!value); ++lease_releases; }
static enum xrt_status answer = XRT_OK;
uint64_t xbo_now_ns(void) { return 1; }
enum xrt_status xrt_remote_background_file(const struct xrt_target *target,
        const struct xrt_call *call) {
    CHECK(target && call->op == XRT_RPC_FILE_READ && call->args[2] == 0);
    ++background_calls;
    return XRT_DISCOVERY_PENDING;
}
enum xrt_status xrt_remote_call(const struct xrt_target *target,
        const struct xrt_call *call) {
    CHECK(target);
    if (call->op == XRT_RPC_FILE_CLOSE) {
        CHECK(call->args[0]);
        ++closes;
        return XRT_OK;
    }
    if (call->op == XRT_RPC_FILE_OPEN) {
        CHECK(call->args[0] == XRT_RPC_FILE_SYMBOLS);
        ++opens;
        *call->value = 2;
        struct xrt_codec wire = xrt_codec(call->out, call->capacity, false);
        bool regular = true;
        xrt_codec_bool(&wire, &regular);
        xrt_wire_file_identity(&wire, &reopened_identity);
        CHECK(wire.ok);
        *call->length = wire.at;
        return XRT_OK;
    }
    CHECK(target && call->op == XRT_RPC_FILE_READ && call->args[2] == 0);
    ++foreground_calls;
    return answer;
}
enum xrt_status xrt_remote_fail(const struct xrt_target *target, enum xrt_status status) {
    (void)target;
    return status;
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
    /* A cached slice must not sleep for another slice's refused source RPC.
     * A refusal made during the new slice still records real contention. */
    job.working.runtime_status = XRT_DISCOVERY_PENDING;
    struct xbo_budget slice = budget(&job);
    CHECK(job.working.runtime_status == XRT_OK && slice.bytes_left == 262144);
    CHECK(runtime_status(&job, XRT_DISCOVERY_PENDING) == XBO_AGAIN);
    CHECK(job.working.runtime_status == XRT_DISCOVERY_PENDING);
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
    job.kind = JOB_CACHED_FILE;
    job.image_fd = -1;
    job.cache_fd = dup(STDIN_FILENO);
    CHECK(job.cache_fd >= 0);
    const int cache_fd = job.cache_fd;
    fail(&job, XBO_CANCELLED, NULL);
    CHECK(job.working.state == XMD_CANCELLED && job.snapshot.state == XMD_CANCELLED);
    CHECK(job.cache_fd == -1 && fcntl(cache_fd, F_GETFD) == -1 && errno == EBADF);
    CHECK(parser_releases == 1 && cache_releases == 1 && lease_releases == 1);
    CHECK(view.remote_id == 0 && closes == 1); /* cancelled image releases its slot */
    view.failure = XRT_OK;
    view.identity = reopened_identity = (struct xrt_file_identity){.device = 1, .inode = 2, .size = 4096};
    CHECK(xrt_file_view_validate_foreground(&view) == XRT_OK);
    CHECK(view.remote_id == 0 && opens == 1 && closes == 2);
    ++reopened_identity.ctime_ns;
    CHECK(xrt_file_view_validate_foreground(&view) == XRT_FILE_CHANGED);
    CHECK(opens == 2 && closes == 3); /* even a mismatched reopen releases its slot */
    --reopened_identity.ctime_ns;
    CHECK(xrt_file_view_validate_foreground(&view) == XRT_FILE_CHANGED);
    CHECK(opens == 2 && closes == 3); /* never resurrect the changed image */
    CHECK(pthread_mutex_destroy(&job.mutex) == 0);
    puts("ready metadata validates in foreground; background contention observed; stale bytes stay refused");
    return 0;
}
