/* C05-R4 regression: bytes read by
 * xlf_decode_file while another process rewrites the file in place (same size)
 * must never be presented as one version of the file.
 *   test-stable DIR [ITERATIONS]
 * runs in DIR (report its filesystem type; torn reads were accepted on
 * XFS before) with owned temporary files only:
 *   1. a writer that keeps the file open and alternates two same-size versions
 *      : every accepted document is one whole version;
 *   2. a writer process that opens, rewrites and closes the file in a loop:
 *      accepted documents are whole versions; reads labelled "leased" happen;
 *      the lease-break signal never reaches this process (SIGIO keeps its
 *      default action, which would terminate it);
 *   3. a MAP_SHARED writable mapping whose descriptor was closed: refused;
 *   4. labels: caller bytes, quiet file leased, lease disabled -> unverified, and
 *      no torn read is ever labelled leased.
 * On a reader without xlf_read_stable (C05-R3) only the torn counts of 1 and 2
 * are measured (and fail when torn bytes are accepted). */
#define _GNU_SOURCE 1
#include "logical_frames.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifdef XLF_HAVE_READ_STABLE
void xlf_test_disable_lease(bool off);
#endif
static int failures, cases;
static void check(int ok, const char *fmt, ...)
{
    char what[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(what, sizeof what, fmt, ap);
    va_end(ap);
    cases++;
    failures += !ok;
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

/* Two valid documents of identical size that differ in every stack weight. */
static char *make_doc(size_t stacks, char weight, size_t *len)
{
    size_t cap = 512 + 2048 + stacks * 400;
    char *s = malloc(cap), *p = s;
    p += sprintf(p, "%s%s", HEADER, THREAD);
    for (size_t i = 1; i <= stacks; ++i)
        p += sprintf(p,
                     "{\"type\":\"acquisition\",\"seq\":%zu,\"start_ns\":null,\"end_ns\":null,\"stacks\":1}\n"
                     "{\"type\":\"stack\",\"id\":\"s%zu\",\"acquisition\":%zu,\"thread\":\"t1\",\"start_ns\":null,"
                     "\"end_ns\":null,\"trigger\":\"t\",\"weight\":\"%c\",\"state\":\"complete\",\"omitted\":null,"
                     "\"reason\":null,\"frames\":[" MARKER "]}\n",
                     i, i, i, weight);
    p += sprintf(p, "{\"type\":\"end\",\"records\":%zu,\"acquisitions\":%zu,\"stacks\":%zu,\"status\":\"complete\"}\n",
                 2 * stacks + 2, stacks, stacks);
    *len = (size_t)(p - s);
    return s;
}
static char *A, *B, hash_a[65], hash_b[65];
static size_t SZ;
static const char *path;
static atomic_int stop;

static void put(const char *s)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0 || write(fd, s, SZ) != (ssize_t)SZ)
        exit(3);
    close(fd);
}
static void pass(int fd, int v)
{
    for (size_t o = 0; o < SZ; o += 1 << 20) {
        size_t n = SZ - o < (1u << 20) ? SZ - o : 1u << 20;
        if (pwrite(fd, (v ? B : A) + o, n, (off_t)o) != (ssize_t)n)
            exit(4);
    }
}
static void *held_writer(void *arg)
{
    (void)arg;
    int fd = open(path, O_WRONLY);
    for (int v = 0; !atomic_load(&stop); v ^= 1)
        pass(fd, v);
    close(fd);
    return NULL;
}
struct tally {
    int whole, refused, other, torn, leased_whole, leased_torn, unverified_torn;
};
static void decode_once(struct tally *t)
{
    struct xlf_error err;
    struct xlf_doc *d = xlf_decode_file(path, NULL, NULL, &err);
    if (d) {
        int whole = !strcmp(d->sha256_hex, hash_a) || !strcmp(d->sha256_hex, hash_b);
        whole ? t->whole++ : t->torn++;
#ifdef XLF_HAVE_READ_STABLE
        if (d->input_stability == XLF_STABILITY_LEASED)
            whole ? t->leased_whole++ : t->leased_torn++;
        else if (!whole)
            t->unverified_torn++;
#endif
    } else if (err.status == XLF_E_IO)
        t->refused++;
    else
        t->other++; /* torn bytes that failed to parse */
    xlf_free(d);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: test-stable DIR [ITERATIONS]\n");
        return 2;
    }
    int iters = argc > 2 ? atoi(argv[2]) : 150;
    struct statfs fs;
    const char *fsname = "other";
    if (!statfs(argv[1], &fs))
        fsname = fs.f_type == 0x58465342 ? "xfs" : fs.f_type == 0xEF53 ? "ext2/3/4" : fs.f_type == 0x9123683E ? "btrfs"
                 : fs.f_type == 0x01021994 ? "tmpfs" : "other";
    printf("directory filesystem: %s (f_type 0x%lx)\n", fsname, (unsigned long)fs.f_type);
    char p[4096];
    snprintf(p, sizeof p, "%s/c05-stable-%ld.c05", argv[1], (long)getpid());
    path = p;
    size_t lb;
    A = make_doc(20000, '1', &SZ);
    B = make_doc(20000, '2', &lb);
    struct xlf_error err;
    struct xlf_doc *d = xlf_decode(A, SZ, NULL, NULL, &err);
    if (!d || lb != SZ) {
        printf("FAIL fixture: %s\n", d ? "sizes differ" : err.message);
        return 1;
    }
    strcpy(hash_a, d->sha256_hex);
#ifdef XLF_HAVE_READ_STABLE
    check(d->input_stability == XLF_STABILITY_CALLER, "xlf_decode labels caller bytes (%s)",
          xlf_stability_name(d->input_stability));
#endif
    xlf_free(d);
    d = xlf_decode(B, SZ, NULL, NULL, &err);
    strcpy(hash_b, d->sha256_hex);
    xlf_free(d);
    printf("two same-size versions of %zu bytes\n", SZ);

    /* 1. writer holds the file open */
    put(A);
    struct tally t = {0};
    pthread_t th;
    pthread_create(&th, NULL, held_writer, NULL);
    for (int i = 0; i < iters; i++)
        decode_once(&t);
    atomic_store(&stop, 1);
    pthread_join(th, NULL);
    check(!t.torn, "writer holding the file open (%d reads): %d whole, %d refused, %d unparsable, %d TORN accepted", iters,
          t.whole, t.refused, t.other, t.torn);

    /* 2. writer process reopens per pass */
    put(A);
    pid_t child = fork();
    if (!child) {
        for (int v = 1;; v ^= 1) {
            int fd = open(path, O_WRONLY);
            if (fd < 0)
                _exit(5);
            pass(fd, v);
            close(fd);
            usleep(3000);
        }
    }
    memset(&t, 0, sizeof t);
    int n = 0;
    for (; n < iters * 4 && (n < iters || t.whole < 10); n++)
        decode_once(&t);
    kill(child, SIGKILL);
    waitpid(child, NULL, 0);
#ifdef XLF_HAVE_READ_STABLE
    check(!t.torn && t.leased_whole > 0,
          "writer process reopening per pass (%d reads): %d whole (%d leased), %d refused, %d unparsable, %d TORN accepted; "
          "the lease-break signal never reached this process",
          n, t.whole, t.leased_whole, t.refused, t.other, t.torn);
#else
    check(!t.torn, "writer process reopening per pass (%d reads): %d whole, %d refused, %d unparsable, %d TORN accepted",
          n, t.whole, t.refused, t.other, t.torn);
#endif

#ifdef XLF_HAVE_READ_STABLE
    /* 3. writable shared mapping, descriptor closed */
    put(A);
    int fd = open(path, O_RDWR);
    char *m = mmap(NULL, SZ, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    d = xlf_decode_file(path, NULL, NULL, &err);
    check(!d && err.status == XLF_E_IO, "file with a writable MAP_SHARED mapping (descriptor closed) refused (%s: %s)",
          xlf_status_name(err.status), err.message);
    xlf_free(d);
    munmap(m, SZ);

    /* 4. labels */
    d = xlf_decode_file(path, NULL, NULL, &err);
    check(d && d->input_stability == XLF_STABILITY_LEASED, "quiet file owned by the caller: %s",
          d ? xlf_stability_name(d->input_stability) : err.message);
    xlf_free(d);
    xlf_test_disable_lease(true);
    d = xlf_decode_file(path, NULL, NULL, &err);
    check(d && d->input_stability == XLF_STABILITY_UNVERIFIED, "no lease possible: decoded and labelled %s",
          d ? xlf_stability_name(d->input_stability) : err.message);
    xlf_free(d);
    memset(&t, 0, sizeof t);
    atomic_store(&stop, 0);
    pthread_create(&th, NULL, held_writer, NULL);
    for (int i = 0; i < iters; i++)
        decode_once(&t);
    atomic_store(&stop, 1);
    pthread_join(th, NULL);
    xlf_test_disable_lease(false);
    check(!t.leased_whole && !t.leased_torn,
          "no lease possible, writer holding the file open (%d reads): every accepted read labelled unverified "
          "(%d whole, %d torn — torn bytes are possible here and are never labelled leased)",
          iters, t.whole, t.unverified_torn);
#endif
    unlink(path);
    printf("%d cases, %d failures\n", cases, failures);
    return failures != 0;
}
