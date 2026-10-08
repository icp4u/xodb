#define _GNU_SOURCE 1
#include "../src/debug/metadata_job.h"
#include "../src/runtime/xrt_remote.h"
#include "../src/runtime/remote_internal.h"
#include <assert.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv) {
    assert(argc == 6);
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *path = argv[1], *agent = argv[2], *mode = argv[3], *cache = argv[4];
    uint64_t expected = strtoull(argv[5], NULL, 16);
    int fd = open(path, !strcmp(mode, "mutation") ? O_RDWR | O_CLOEXEC : O_RDONLY | O_CLOEXEC);
    assert(fd >= 0);
    struct stat st; assert(fstat(fd, &st) == 0);
    struct xrt_file_request request = {.kind = XRT_FILE_MAPPED,
        .mapping = {.start = 4096, .end = 8192, .device_major = major(st.st_dev),
                    .device_minor = minor(st.st_dev), .inode = st.st_ino, .path = path}};
    struct xrt_target *target;
    int remote = strcmp(agent, "-") != 0;
    if (remote) {
        const char *command[] = {agent, "--stdio", NULL};
        assert(xrt_target_remote(command, &target) == XRT_OK);
    } else target = xrt_target_create();
    assert(target);
    struct xrt_file_view *view;
    assert(xrt_target_file_view_open(target, &request, &view) == XRT_OK);
    int cache_fd = strcmp(cache, "-") ? open(cache, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600) : -1;
    if (strcmp(cache, "-")) assert(cache_fd >= 0);
    if (remote) assert(xrt_remote_call(target, &(struct xrt_call){.op = XRT_RPC_VIEW}) == XRT_OK);
    struct xmd_job *job;
    assert(xmd_start_javascript_dwarf(view, cache_fd, UINT64_C(8) * 1024 * 1024 * 1024, &job) == XBO_OK);
    if (cache_fd >= 0) close(cache_fd);
    uint64_t start = xbo_now_ns(), max_poll = 0, max_rpc = 0, polls = 0, rpcs = 0;
    int cancel_sent = 0;
    struct xmd_snapshot snapshot;
    for (;;) {
        uint64_t before = xbo_now_ns();
        xmd_poll(job, &snapshot);
        uint64_t elapsed = xbo_now_ns() - before;
        if (elapsed > max_poll) max_poll = elapsed;
        ++polls;
        if (!strcmp(mode, "cancel") && !cancel_sent && snapshot.slices >= 2) {
            xmd_cancel(job); cancel_sent = 1;
        }
        if (snapshot.state == XMD_READY || snapshot.state == XMD_FAILED || snapshot.state == XMD_CANCELLED) break;
        assert(!snapshot.profile.fields && !snapshot.profile.frame_config);
        if (remote && rpcs < 20) {
            before = xbo_now_ns();
            enum xrt_status observed = xrt_remote_call(target, &(struct xrt_call){.op = XRT_RPC_VIEW});
            assert(observed == XRT_OK || (!strcmp(mode, "protocol") && observed == XRT_PROTOCOL_ERROR));
            elapsed = xbo_now_ns() - before;
            if (elapsed > max_rpc) max_rpc = elapsed;
            ++rpcs;
        }
        struct timespec pause = {.tv_nsec = 1000000};
        nanosleep(&pause, NULL);
        assert(xbo_now_ns() - start < UINT64_C(120000000000));
    }
    while (xmd_join(job) == XBO_AGAIN) {
        struct timespec pause = {.tv_nsec = 1000000}; nanosleep(&pause, NULL);
    }
    if (!strcmp(mode, "protocol")) {
        assert(snapshot.state == XMD_FAILED && snapshot.runtime_status == XRT_PROTOCOL_ERROR && !snapshot.profile.fields);
    } else if (!strcmp(mode, "cancel")) {
        assert(cancel_sent && snapshot.state == XMD_CANCELLED && !snapshot.profile.fields);
    } else {
        if (snapshot.state != XMD_READY) fprintf(stderr, "job failed: %s status=%d runtime=%d\n",
            snapshot.reason ? snapshot.reason : "no reason", snapshot.status, snapshot.runtime_status);
        assert(snapshot.state == XMD_READY && snapshot.profile.fields == expected);
        assert(xmd_validate(job) == XBO_OK);
        if (!strcmp(mode, "mutation")) {
            struct timespec times[2] = {st.st_atim, st.st_mtim};
            ++times[1].tv_sec; assert(futimens(fd, times) == 0);
            assert(xmd_validate(job) == XBO_CHANGED);
            times[1] = st.st_mtim; assert(futimens(fd, times) == 0);
            assert(xmd_validate(job) == XBO_CHANGED);
            xmd_poll(job, &snapshot);
            assert(snapshot.state == XMD_FAILED && !snapshot.profile.fields);
        }
    }
    /* This bounds caller work, not scheduling latency on a loaded host. */
    assert(max_poll < UINT64_C(100000000));
    if (remote) assert(max_rpc < UINT64_C(500000000));
    printf("state=%u fields=%" PRIx64 " polls=%" PRIu64 " max_poll_ms=%.3f rpcs=%" PRIu64
           " max_rpc_ms=%.3f source_bytes=%" PRIu64 " cache_bytes=%" PRIu64 " slices=%" PRIu64 " seconds=%.3f\n",
        snapshot.state, snapshot.profile.fields, polls, max_poll / 1e6, rpcs, max_rpc / 1e6,
        snapshot.source_bytes, snapshot.cache_bytes, snapshot.slices, (xbo_now_ns() - start) / 1e9);
    xmd_destroy(job);
    assert(xrt_target_destroy(target) == XRT_OK);
    close(fd);
    return 0;
}
