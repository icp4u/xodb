#define _GNU_SOURCE 1
#include "xrt_fdactivity.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>
static pid_t child;
static int shared_mode;
static void cleanup(void)
{
    if (child > 0) {
        kill(child, SIGKILL);
        while (waitpid(child, 0, 0) < 0 && errno == EINTR) {
        }
        child = 0;
    }
}
static uint64_t start(pid_t p)
{
    char name[64], buf[4096];
    snprintf(name, sizeof name, "/proc/%d/stat", p);
    FILE *f = fopen(name, "r");
    assert(f);
    assert(fgets(buf, sizeof buf, f));
    fclose(f);
    char *q = strrchr(buf, ')') + 2;
    for (unsigned n = 3; n < 22; n++)
        q = strchr(q, ' ') + 1;
    return strtoull(q, 0, 10);
}
struct capture {
    struct xrt_fdevent *direct;
    struct xrt_fdactivity *owner;
    struct xrt_fdevent_row rows[4096];
    int expected_fd;
};
static enum xrt_status request_until_ready(struct xrt_fdactivity *owner,
                                           const struct xrt_fdactivity_request *request)
{
    for (unsigned n = 0; n < 100; n++) {
        enum xrt_status status = xrt_fdactivity_request(owner, request);
        if (status != XRT_STALE_SNAPSHOT)
            return status;
        usleep(1000);
    }
    return XRT_STALE_SNAPSHOT;
}
static enum xrt_status capture_open(const struct xrt_fdevent_options *opts, struct capture **out,
                                    struct xrt_perf_failure *failure)
{
    struct capture *c = calloc(1, sizeof *c);
    assert(c);
    if (!shared_mode) {
        struct xrt_fdevent_options wrong = *opts;
        wrong.expected_start++;
        struct xrt_fdevent *bad = 0;
        assert(xrt_fdevent_open(&wrong, &bad, failure) == XRT_PROCESS_GONE && !bad);
        enum xrt_status result = xrt_fdevent_open(opts, &c->direct, failure);
        if (result == XRT_OK)
            *out = c;
        else
            free(c);
        return result;
    }
    assert(xrt_fdactivity_create(&c->owner) == XRT_OK);
    struct xrt_fdactivity_request request = {
        .interval_ms = 250, .event_pid = opts->pid, .event_start = opts->expected_start};
    assert(request_until_ready(c->owner, &request) == XRT_OK);
    for (unsigned n = 0; n < 200; n++) {
        struct xrt_fdactivity_view v;
        if (xrt_fdactivity_acquire(c->owner, &v)) {
            int ready = v.event_generation && v.event_status == XRT_OK && v.event.started_ns &&
                        v.event.running;
            *failure = v.event_failure;
            xrt_fdactivity_release(c->owner);
            if (ready) {
                struct xrt_fdactivity_request conflict = request;
                conflict.event_start++;
                assert(request_until_ready(c->owner, &conflict) == XRT_INVALID_STATE);
                struct xrt_fdactivity_request peer = {.interval_ms = 1000};
                assert(request_until_ready(c->owner, &peer) == XRT_OK);
                *out = c;
                return XRT_OK;
            }
        }
        usleep(10000);
    }
    xrt_fdactivity_destroy(c->owner);
    free(c);
    return XRT_FILE_UNAVAILABLE;
}
static enum xrt_status capture_drain(struct capture *c, struct xrt_fdevent_snapshot *out)
{
    if (c->direct)
        return xrt_fdevent_drain(c->direct, out);
    for (unsigned n = 0; n < 200; n++) {
        struct xrt_fdactivity_view v;
        if (xrt_fdactivity_acquire(c->owner, &v)) {
            *out = v.event;
            assert(out->row_count <= 4096);
            memcpy(c->rows, out->rows, out->row_count * sizeof(*c->rows));
            out->rows = c->rows;
            xrt_fdactivity_release(c->owner);
            if (out->invalid || out->lost)
                return XRT_OK;
            for (unsigned i = 0; i < out->row_count; i++)
                if (out->rows[i].fd == c->expected_fd && out->rows[i].read_bytes >= 13 &&
                    out->rows[i].write_bytes >= 9)
                    return XRT_OK;
        }
        usleep(10000);
    }
    return XRT_STALE_SNAPSHOT;
}
static void capture_close(struct capture *c)
{
    if (c->direct) {
        xrt_fdevent_close(c->direct);
        free(c);
        return;
    }
    int expired = 0;
    for (unsigned n = 0; n < 500 && !expired; n++) {
        struct xrt_fdactivity_view v;
        if (xrt_fdactivity_acquire(c->owner, &v)) {
            expired = !v.event_requested && !v.event.running;
            if (expired) {
                assert(v.event.row_count > 0 && v.poll && v.poll->sequence > 1 &&
                       v.interval_ms == 1000);
                printf(
                    "shared owner expired with retained counts; poll sequence=%llu CPU=%llu ns\n",
                    (unsigned long long)v.poll->sequence, (unsigned long long)v.owner_cpu_ns);
            }
            xrt_fdactivity_release(c->owner);
        }
        if (!expired)
            usleep(10000);
    }
    assert(expired);
    xrt_fdactivity_destroy(c->owner);
    free(c);
}
int main(int argc, char **argv)
{
    assert(argc == 3);
    shared_mode = !strcmp(argv[2], "shared");
    atexit(cleanup);
    int file = open(argv[1], O_RDWR | O_CREAT | O_TRUNC, 0600);
    assert(file >= 0);
    assert(write(file, "abcdefgh", 8) == 8);
    assert(lseek(file, 0, SEEK_SET) == 0);
    char other[4096];
    assert(snprintf(other, sizeof other, "%s.other", argv[1]) < (int)sizeof other);
    int seed = open(other, O_RDWR | O_CREAT | O_TRUNC, 0600);
    assert(seed >= 0);
    assert(write(seed, "different file", 14) == 14);
    close(seed);
    int go[2], ready[2];
    assert(pipe(go) == 0 && pipe(ready) == 0);
    child = fork();
    assert(child >= 0);
    if (!child) {
        prctl(PR_SET_PDEATHSIG, SIGKILL);
        close(go[1]);
        close(ready[0]);
        char buf[64];
        assert(write(ready[1], "r", 1) == 1);
        assert(read(go[0], buf, 1) == 1);
        assert(read(file, buf, 3) == 3);
        assert(pread(file, buf, 4, 3) == 4);
        assert(read(file, buf, 64) == 5);
        assert(read(file, buf, 1) == 0);
        assert(write(file, "12345", 5) == 5);
        assert(pwrite(file, "xy", 2, 0) == 2);
        assert(read(-1, buf, 1) == -1);
        int dupfd = dup(file);
        assert(dupfd >= 0);
        assert(close(dupfd) == 0);
        assert(close(file) == 0);
        int next = open(other, O_RDWR);
        assert(next == file);
        assert(read(next, buf, 1) == 1);
        assert(write(next, "ZZ", 2) == 2);
        assert(write(ready[1], "d", 1) == 1);
        assert(read(go[0], buf, 1) == 1);
        _exit(0);
    }
    close(go[0]);
    close(ready[1]);
    char c;
    assert(read(ready[0], &c, 1) == 1);
    struct xrt_fdevent_options opts = {.pid = child, .expected_start = start(child)};
    struct xrt_perf_failure failure = {0};
    struct capture *capture = 0;
    enum xrt_status status = capture_open(&opts, &capture, &failure);
    if (status != XRT_OK) {
        fprintf(stderr, "open status %d kind %d errno %d detail %s\n", status, failure.kind,
                failure.error, failure.detail);
        return 1;
    }
    capture->expected_fd = file;
    assert(write(go[1], "g", 1) == 1);
    assert(read(ready[0], &c, 1) == 1);
    usleep(20000);
    struct xrt_fdevent_snapshot s;
    assert(capture_drain(capture, &s) == XRT_OK);
    printf(
        "records=%llu flags=%u lost=%llu invalid=%llu unpaired=%llu rows=%u running=%d reason=%s\n",
        (unsigned long long)s.records, s.flags, (unsigned long long)s.lost,
        (unsigned long long)s.invalid, (unsigned long long)s.unpaired, s.row_count, s.running,
        s.reason);
    const struct xrt_fdevent_row *found = 0;
    for (unsigned i = 0; i < s.row_count; i++) {
        const struct xrt_fdevent_row *r = &s.rows[i];
        printf("fd=%d read=%llu write=%llu opens=%llu closes=%llu dups=%llu\n", r->fd,
               (unsigned long long)r->read_bytes, (unsigned long long)r->write_bytes,
               (unsigned long long)r->open_returns, (unsigned long long)r->close_successes,
               (unsigned long long)r->dup_returns);
        if (r->fd == file)
            found = r;
    }
    fflush(stdout);
    assert(s.running && !s.pending && !s.lost && !s.invalid);
    assert((s.flags & ~XRT_FDEVENT_UNPAIRED) == 0);
    assert(found && found->read_bytes == 13 && found->write_bytes == 9 &&
           found->open_returns == 1 && found->close_successes == 1);
    assert(s.dup_returns == 1);
    if (shared_mode)
        capture_close(capture);
    assert(write(go[1], "q", 1) == 1);
    int code;
    assert(waitpid(child, &code, 0) == child);
    child = 0;
    assert(WIFEXITED(code) && WEXITSTATUS(code) == 0);
    if (!shared_mode) {
        assert(capture_drain(capture, &s) == XRT_OK);
        assert(!s.running && !s.invalid && (s.flags & XRT_FDEVENT_SCOPE_CHANGED));
        capture_close(capture);
        puts("PASS selected task exit closes the scope without invalid records");
    }
    close(file);
    close(go[1]);
    close(ready[0]);
    unlink(argv[1]);
    unlink(other);
    usleep(100000);
    puts("PASS live exact bytes, short read, error, dup and fd reuse");
}
