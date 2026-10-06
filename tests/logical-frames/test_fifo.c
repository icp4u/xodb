/* C05-R3 regression: xlf_decode_file on a FIFO. On R2 open(2) blocks
 * when no writer exists, before any cancellation poll, so a job holding an
 * xlf_cancel cannot stop it; and opening the FIFO releases a writer blocked in
 * open(O_WRONLY). The fix: O_PATH pin, type check, reopen of the pinned
 * regular file. */
#define _GNU_SOURCE 1
#include "logical_frames.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int failures, cases;
static void check(int ok, const char *fmt, ...)
{
    char what[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(what, sizeof what, fmt, ap);
    va_end(ap);
    cases++;
    if (!ok)
        failures++;
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    fflush(stdout);
}

#define HEADER                                                                                      \
    "{\"type\":\"header\",\"format\":\"xodb.logical-frames\",\"version\":1,\"draft\":\"C05-1\","        \
    "\"producer\":{\"name\":\"t\",\"version\":\"1\",\"kind\":\"cooperating_in_process\",\"sha256\":null}," \
    "\"source_kind\":\"cooperative_sample\",\"runtime\":{\"language\":\"python\",\"implementation\":\"cpython\"," \
    "\"version\":\"3\",\"build\":null,\"executable\":{\"path\":null,\"sha256\":null,\"gnu_build_id\":null,"  \
    "\"unavailable\":\"test\"},\"library\":null},\"process\":{\"pid\":null,\"start_ticks\":null,\"boot_id\":null," \
    "\"unavailable\":\"test\"},\"clock\":null,\"clock_unavailable\":\"test\",\"command\":null,"           \
    "\"collection\":{\"method\":\"m\",\"trigger\":\"t\",\"interval_ns\":null,\"atomicity\":\"single_thread\"}," \
    "\"frame_order\":\"innermost_first\",\"weight_unit\":\"observation\",\"weight_semantics\":\"test\"}\n"
#define THREAD "{\"type\":\"thread\",\"id\":\"t1\",\"language_id\":null,\"name\":\"one\",\"os_tid\":null,\"os_tid_reason\":\"test\"}\n"
#define MARKER                                                                                       \
    "{\"function\":null,\"kind\":\"unknown\",\"line\":null,\"provenance\":\"runtime\",\"label\":\"m\",\"reason\":\"r\"}"
#define STACK(n, w)                                                                                 \
    "{\"type\":\"acquisition\",\"seq\":" #n ",\"start_ns\":null,\"end_ns\":null,\"stacks\":1}\n"            \
    "{\"type\":\"stack\",\"id\":\"s" #n "\",\"acquisition\":" #n ",\"thread\":\"t1\",\"start_ns\":null,"    \
    "\"end_ns\":null,\"trigger\":\"t\",\"weight\":\"" #w "\",\"state\":\"complete\",\"omitted\":null,"       \
    "\"reason\":null,\"frames\":[" MARKER "," MARKER "]}\n"


static const char doc_text[] = HEADER THREAD STACK(1, 18446744073709551615) STACK(2, 3)
    "{\"type\":\"end\",\"records\":6,\"acquisitions\":2,\"stacks\":2,\"status\":\"complete\"}\n";

/* ---- FIFO input ---- */
struct decode_job {
    const char *path;
    struct xlf_cancel *cancel;
    struct xlf_error err;
    struct xlf_doc *doc;
    int done;
    pthread_mutex_t lock;
};
static void *decode_thread(void *arg)
{
    struct decode_job *j = arg;
    struct xlf_error err;
    struct xlf_doc *d = xlf_decode_file(j->path, NULL, j->cancel, &err);
    pthread_mutex_lock(&j->lock);
    j->err = err;
    j->doc = d;
    j->done = 1;
    pthread_mutex_unlock(&j->lock);
    return NULL;
}
static int job_done(struct decode_job *j)
{
    pthread_mutex_lock(&j->lock);
    int d = j->done;
    pthread_mutex_unlock(&j->lock);
    return d;
}
static void sleep_ms(long ms)
{
    struct timespec t = {ms / 1000, (ms % 1000) * 1000000L};
    while (nanosleep(&t, &t) && errno == EINTR)
        ;
}

static void fifo(const char *dir)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/xlf-r3-fifo-%ld", dir, (long)getpid());
    unlink(path);
    if (mkfifo(path, 0600)) {
        check(0, "fifo: mkfifo %s: %s", path, strerror(errno));
        return;
    }
    /* 1. No writer: the call must return on its own or after cancellation. */
    struct decode_job j = {.path = path, .cancel = xlf_cancel_create(), .lock = PTHREAD_MUTEX_INITIALIZER};
    pthread_t t;
    pthread_create(&t, NULL, decode_thread, &j);
    sleep_ms(200);
    xlf_cancel_request(j.cancel);
    int returned = 0;
    for (int i = 0; i < 40 && !(returned = job_done(&j)); ++i)
        sleep_ms(50);
    if (!returned) {
        /* R2 blocks in open(2): release it by opening the writer side so the test ends. */
        int w = open(path, O_WRONLY | O_NONBLOCK);
        for (int i = 0; i < 100 && !job_done(&j); ++i)
            sleep_ms(20);
        if (w >= 0)
            close(w);
    }
    pthread_join(t, NULL);
    check(returned && !j.doc && (j.err.status == XLF_E_IO || j.err.status == XLF_E_CANCELLED),
          "fifo without writer: returned within 2 s of cancellation (%s, %s)", returned ? "returned" : "BLOCKED",
          xlf_status_name(j.err.status));
    xlf_free(j.doc);
    xlf_cancel_destroy(j.cancel);

    /* 2. A writer blocked in open(O_WRONLY) must not be released by the reader. */
    pid_t pid = fork();
    if (pid == 0) {
        int w = open(path, O_WRONLY); /* blocks until some reader opens */
        _exit(w >= 0 ? 7 : 8);
    }
    sleep_ms(100);
    struct xlf_error err;
    struct xlf_doc *d = xlf_decode_file(path, NULL, NULL, &err);
    sleep_ms(200);
    int status = 0;
    pid_t r = waitpid(pid, &status, WNOHANG);
    int released = r == pid;
    if (!released) {
        int rd = open(path, O_RDONLY | O_NONBLOCK); /* release our own child */
        waitpid(pid, &status, 0);
        if (rd >= 0)
            close(rd);
    }
    check(!d && err.status == XLF_E_IO && !released,
          "fifo with a blocked writer: refused (%s) without opening it (writer %s)", xlf_status_name(err.status),
          released ? "RELEASED" : "still blocked");
    xlf_free(d);
    unlink(path);

    /* 3. A regular file is still read, and the result is unaffected. */
    snprintf(path, sizeof path, "%s/xlf-r3-reg-%ld", dir, (long)getpid());
    FILE *f = fopen(path, "w");
    fputs(doc_text, f);
    fclose(f);
    d = xlf_decode_file(path, NULL, NULL, &err);
    char buf[40] = "";
    if (d)
        xlf_count_format(d->total_weight, buf);
    check(d && d->input_charged && !strcmp(buf, "18446744073709551618"), "regular file still decodes (total %s)", buf);
    xlf_free(d);
    /* 4. A cancellation requested before the call is observed before any open. */
    struct xlf_cancel *c = xlf_cancel_create();
    xlf_cancel_request(c);
    d = xlf_decode_file(path, NULL, c, &err);
    check(!d && err.status == XLF_E_CANCELLED, "pre-requested cancel on a regular file -> cancelled (%s)",
          xlf_status_name(err.status));
    xlf_cancel_destroy(c);
    /* 5. Directories and missing paths stay io_error. */
    d = xlf_decode_file(dir, NULL, NULL, &err);
    check(!d && err.status == XLF_E_IO, "directory -> io_error");
    unlink(path);
    d = xlf_decode_file(path, NULL, NULL, &err);
    check(!d && err.status == XLF_E_IO, "missing file -> io_error");
}

int main(void)
{
    const char *dir = getenv("XLF_TEST_TMPDIR") ? getenv("XLF_TEST_TMPDIR") : getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp";
    fifo(dir);
    printf("%d cases, %d failures\n", cases, failures);
    return failures != 0;
}
