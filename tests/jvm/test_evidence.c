/* C05-R3 owned evidence bundle (jvm_evidence.h) through the C API:
 *  - a cancellation requested before the call is observed before the path is
 *    touched (FIFO and missing paths return cancelled, never block or io_error);
 *  - citations resolve from the retained bytes after the source file is
 *    rewritten and deleted;
 *  - the whole-operation budget is exact: the reported whole peak succeeds, one
 *    byte less and a sweep of smaller limits fail with memory_limit (LeakSanitizer
 *    checks every failure path in sanitizer builds);
 *  - cancellation at every importer/adapter poll point fails cleanly;
 *  - Thread.print tails placed against a PROT_NONE page import without reading
 *    past the input (compiler-independent overread check);
 *  - JIT inlining, Java native methods, heuristic text, virtual threads, loader
 *    identity and coroutine parents survive to the typed accessors.
 *   test-evidence REGRESS_DIR TMPDIR
 *   test-evidence --mutate FILE SOURCE TMPDIR   (any capture: citations after
 *       its copy is rewritten and deleted; SOURCE jfr-json|thread-dump-json|
 *       thread-print|coroutine-probes; JFR uses export depth 2048) */
#define _GNU_SOURCE 1
#include "jvm_evidence_internal.h"
#include "sha256.h"
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *regress, *tmp;
static int failures, cases;
static void check(int ok, const char *fmt, ...)
{
    char what[600];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(what, sizeof what, fmt, ap);
    va_end(ap);
    cases++;
    failures += !ok;
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    fflush(stdout);
}
static char *slurp(const char *path, size_t *n)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return NULL;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *s = malloc((size_t)size + 1);
    if (fread(s, 1, (size_t)size, f) != (size_t)size)
        size = 0;
    fclose(f);
    s[size] = 0;
    *n = (size_t)size;
    return s;
}
static void spit(const char *path, const char *s, size_t n)
{
    FILE *f = fopen(path, "wb");
    fwrite(s, 1, n, f);
    fclose(f);
}

static void pre_cancel(void)
{
    struct xlf_cancel *c = xlf_cancel_create();
    xlf_cancel_request(c);
    char fifo[4096], missing[4096];
    snprintf(fifo, sizeof fifo, "%s/ev-fifo-%ld", tmp, (long)getpid());
    snprintf(missing, sizeof missing, "%s/ev-missing-%ld", tmp, (long)getpid());
    unlink(fifo);
    mkfifo(fifo, 0600);
    struct jvm_evidence *ev;
    struct xlf_error err;
    enum xlf_status a = jvm_evidence_import(fifo, JVM_SOURCE_JFR_JSON, NULL, NULL, c, &ev, &err);
    enum xlf_status b = jvm_evidence_import(missing, JVM_SOURCE_JFR_JSON, NULL, NULL, c, &ev, &err);
    enum xlf_status d = jvm_evidence_import_bytes("{}", 2, "x", JVM_SOURCE_JFR_JSON, NULL, NULL, c, &ev, &err);
    check(a == XLF_E_CANCELLED && b == XLF_E_CANCELLED && d == XLF_E_CANCELLED && !ev,
          "pre-requested cancellation before any work (fifo %s, missing %s, bytes %s)", xlf_status_name(a),
          xlf_status_name(b), xlf_status_name(d));
    xlf_cancel_reset(c);
    a = jvm_evidence_import(fifo, JVM_SOURCE_JFR_JSON, NULL, NULL, c, &ev, &err);
    check(a == XLF_E_IO && !ev, "FIFO without writer refused without blocking (%s: %s)", xlf_status_name(a), err.message);
    unlink(fifo);
    xlf_cancel_destroy(c);
}

static void citations_after_mutation(const char *src, enum jvm_source source, int loader_case)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/ev-mutate-%ld.in", tmp, (long)getpid());
    size_t n = 0;
    char *orig = slurp(src, &n);
    spit(path, orig, n);
    char want[65];
    sha256_hex(orig, n, want);
    struct jvm_evidence_limits l;
    jvm_evidence_default_limits(&l);
    l.import.jfr_export_depth = 2048;
    struct jvm_evidence *ev;
    struct xlf_error err;
    enum xlf_status st = jvm_evidence_import(path, source, NULL, &l, NULL, &ev, &err);
    check(st == XLF_OK, "import of a temporary copy of %s (%s)", src, st ? err.message : "ok");
    if (st)
        return;
    spit(path, "{\"recording\":{\"events\":[]}}", 27); /* rewrite in place, different size */
    unlink(path);                                     /* then delete */
    size_t len;
    const char *sha;
    const uint8_t *bytes = jvm_evidence_source(ev, &len, &sha);
    char again[65];
    sha256_hex(bytes, len, again);
    check(len == n && !strcmp(sha, want) && !strcmp(again, want) && !memcmp(bytes, orig, n),
          "after rewrite+delete the retained source is the original (%zu bytes, sha %.12s)", len, again);
    const struct xlf_doc *d = jvm_evidence_doc(ev);
    int bad = 0;
    int json = source != JVM_SOURCE_THREAD_PRINT;
    for (uint32_t i = 0; i < d->stack_count; ++i) {
        const uint8_t *span;
        size_t sn;
        struct jvm_evidence_stack s;
        if (jvm_evidence_cite(ev, i, &span, &sn) || jvm_evidence_stack(ev, i, &s) ||
            memcmp(span, orig + s.source_offset, sn) || (json && (span[0] != '{' || span[sn - 1] != '}')) ||
            (!json && span[0] != '"' && memcmp(span, "os_prio=", 8)) ||
            (loader_case && (!memmem(span, sn, "jdk.ExecutionSample", 19) ||
                             !memmem(span, sn, i ? "loader-B" : "loader-A", 8))))
            bad++;
    }
    check(d->stack_count > 0 && !bad, "%zu stacks cite their own source bytes after the file was rewritten and deleted",
          d->stack_count);
    if (!loader_case) {
        jvm_evidence_free(ev);
        free(orig);
        return;
    }
    size_t ln;
    const char *lf = jvm_evidence_lframes(ev, &ln);
    char lsha[65];
    sha256_hex(lf, ln, lsha);
    check(!strcmp(lsha, d->sha256_hex) && d->stacks[0].cite.offset + d->stacks[0].cite.length <= ln,
          "retained C05 bytes hash to the decoded document and contain its citations");
    struct jvm_evidence_frame f0, f1;
    jvm_evidence_function(ev, 0, &f0);
    jvm_evidence_function(ev, 1, &f1);
    check(d->function_count == 2 && f0.loader_status == JVM_LOADER_NAMED && strcmp(f0.class_loader, f1.class_loader) &&
              f0.class_loader_type && !strcmp(f0.class_loader_type, "jdk/internal/loader/ClassLoaders$AppClassLoader"),
          "functions keep distinct loaders and the loader type (%s, %s)", f0.class_loader, f1.class_loader);
    jvm_evidence_free(ev);
    free(orig);
}

static enum xlf_status import_limited(const char *path, enum jvm_source src, size_t limit, uint64_t cancel_at,
                                      struct jvm_evidence_usage *u, struct xlf_error *err)
{
    struct jvm_evidence_limits l;
    jvm_evidence_default_limits(&l);
    l.import.jfr_export_depth = 2048;
    l.max_total_bytes = limit;
    struct jvm_evidence *ev;
    enum xlf_status st = jvm_evidence_import_test(path, src, NULL, &l, NULL, cancel_at, &ev, err);
    if (!st) {
        jvm_evidence_usage(ev, u);
        jvm_evidence_free(ev);
    }
    return st;
}
static size_t dense_limit = 200000;
static void budget_and_cancel(const char *path, enum jvm_source src)
{
    const char *name = strrchr(path, '/') ? strrchr(path, '/') + 1 : path;
    struct jvm_evidence_usage u = {0};
    struct xlf_error err;
    enum xlf_status st = import_limited(path, src, 0, 0, &u, &err);
    check(st == XLF_OK && u.whole_peak >= u.import_peak && u.whole_peak >= u.adapt_peak && u.retained_bytes > u.source_bytes,
          "%s: unlimited import, whole peak %zu (import %zu, adapt %zu, reader %zu), retained %zu", name, u.whole_peak,
          u.import_peak, u.adapt_peak, u.decode_peak, u.retained_bytes);
    size_t peak = u.whole_peak;
    struct jvm_evidence_usage v = {0};
    st = import_limited(path, src, peak, 0, &v, &err);
    check(st == XLF_OK && v.whole_peak == peak, "%s: max_total_bytes == whole peak (%zu) succeeds", name, peak);
    st = import_limited(path, src, peak - 1, 0, &v, &err);
    check(st == XLF_E_MEMORY && err.peak_bytes <= peak - 1, "%s: whole peak - 1 -> %s (%s)", name, xlf_status_name(st),
          err.message);
    /* C05-R4: dense. Every limit below the peak when the peak is
     * small; otherwise a stride plus every limit within +-512 bytes of each
     * phase boundary (import, adapt, decode, index peaks) and the 4096 limits
     * directly below the peak. Each must be memory_limit with the reported peak
     * within the limit and a phase-named reason, never a crash or "failed". */
    int bad = 0, runs = 0;
    size_t marks[] = {u.source_bytes, u.import_peak, u.adapt_peak, u.whole_peak - u.decode_peak, u.whole_peak};
    size_t dense_all = peak <= dense_limit;
    for (size_t lim = 1; lim < peak; lim++) {
        int take = dense_all || lim % 509 == 0 || peak - lim <= 4096;
        for (size_t m = 0; !take && m < sizeof marks / sizeof *marks; m++)
            take = lim + 512 >= marks[m] && lim <= marks[m] + 512;
        if (!take)
            continue;
        runs++;
        st = import_limited(path, src, lim, 0, &v, &err);
        if (st != XLF_E_MEMORY || err.peak_bytes > lim || strstr(err.message, ": failed") ||
            (!strstr(err.message, "budget") && !strstr(err.message, "memory"))) {
            if (bad++ < 10)
                printf("     limit %zu: %s peak %zu %s\n", lim, xlf_status_name(st), err.peak_bytes, err.message);
        }
    }
    check(!bad, "%s: %d smaller limits (%s) all memory_limit, reported peak within the limit, reason named", name, runs,
          dense_all ? "every limit" : "stride, +-512 around each phase peak, last 4096");
    uint64_t k = 1;
    bad = 0;
    for (;; ++k) {
        st = import_limited(path, src, 0, k, &v, &err);
        if (st == XLF_OK)
            break;
        if (st != XLF_E_CANCELLED)
            bad++, printf("     cancel at poll %llu: %s %s\n", (unsigned long long)k, xlf_status_name(st), err.message);
        if (k > 100000)
            break;
    }
    check(!bad && k > 2, "%s: cancelled at each of %llu importer/adapter poll points, then succeeds", name,
          (unsigned long long)(k - 1));
}

/* Input ends exactly at a PROT_NONE page: any read past it faults. */
static void guard_page(void)
{
    static const char *const tails[] = {"1:\nx\nFull thread dump Test (1 mixed mode):\nx\n",
                                        "1:\nx\nFull thread dump T (1 m):\n\nThreads class",
                                        "1:\nx\nFull thread dump T (1 m):\n\n\"a\" #1 [7] os_prio=0 tid=0x1 nid=7 r\n\tat",
                                        "1:\nx\nFull thread dump (", "1:\nx\nFull thread dump T (1 m):\n\n\"a\" #9"};
    long page = sysconf(_SC_PAGESIZE);
    char *m = mmap(NULL, (size_t)page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    mprotect(m + page, (size_t)page, PROT_NONE);
    int ok = 1;
    for (size_t i = 0; i < sizeof tails / sizeof *tails; ++i) {
        size_t n = strlen(tails[i]);
        char *at = m + page - n;
        memcpy(at, tails[i], n);
        struct jvm_limits l;
        jvm_limits_default(&l);
        struct jvm_import *im = NULL;
        int rc = jvm_import_bytes(at, n, "guard", JVM_SOURCE_THREAD_PRINT, &l, NULL, &im);
        ok &= rc == 0 || rc == -1;
        jvm_import_free(im);
    }
    munmap(m, (size_t)page * 2);
    check(ok, "Thread.print tails against a PROT_NONE page import without a read past the input");
}

static const char jfr[] =
    "{\"recording\":{\"events\":["
    "{\"type\":\"jdk.ExecutionSample\",\"values\":{\"startTime\":\"2026-10-05T00:00:00Z\",\"sampledThread\":"
    "{\"osName\":\"v\",\"osThreadId\":0,\"javaName\":\"v\",\"javaThreadId\":40,\"group\":null,\"virtual\":true},"
    "\"state\":\"STATE_RUNNABLE\",\"stackTrace\":{\"truncated\":false,\"frames\":["
    "{\"method\":{\"type\":{\"classLoader\":{\"type\":null,\"name\":\"app\"},\"name\":\"p/A\"},\"name\":\"inl\","
    "\"descriptor\":\"()V\"},\"lineNumber\":3,\"bytecodeIndex\":7,\"type\":\"Inlined\"},"
    "{\"method\":{\"type\":{\"classLoader\":{\"type\":null,\"name\":\"bootstrap\"},\"name\":\"java/lang/Object\"},"
    "\"name\":\"wait0\",\"descriptor\":\"(J)V\"},\"lineNumber\":-1,\"bytecodeIndex\":0,\"type\":\"Native\"},"
    "{\"method\":{\"type\":{\"name\":\"p/B\"},\"name\":\"run\",\"descriptor\":\"()V\"},\"lineNumber\":9,"
    "\"bytecodeIndex\":1,\"type\":\"Interpreted\"}]}}}]}}";
static const char probes[] =
    "{\"format\":\"xodb-c06-coroutine-probes\",\"version\":1,\"pid\":1,\"wall_time\":\"2026-10-05T00:00:00Z\","
    "\"nano_time\":\"1\",\"probes_installed\":true,\"runtime_version\":\"x\",\"coroutines\":["
    "{\"sequence\":1,\"coroutine_id\":null,\"name\":\"parent\",\"state\":\"SUSPENDED\",\"parent_relation\":"
    "\"parent_not_tracked\",\"parent_sequence\":null,\"last_thread\":null,\"last_observed_frames\":[\"a.B.c(B.kt:1)\"],"
    "\"creation_frames\":[\"a.B.e(B.kt:3)\"]},"
    "{\"sequence\":2,\"coroutine_id\":null,\"name\":\"child\",\"state\":\"SUSPENDED\",\"parent_relation\":"
    "\"observed\",\"parent_sequence\":1,\"last_thread\":{\"java_thread_id\":5,\"name\":\"w\",\"virtual\":false},"
    "\"last_observed_frames\":[\"a.B.d(B.kt:2)\",\"_COROUTINE._CREATION._(CoroutineDebugging.kt:30)\",\"a.B.f(B.kt:4)\"],"
    "\"creation_frames\":[\"a.B.f(B.kt:4)\",\"a.B.g(B.kt:5)\"]}]}";
static void distinctions(void)
{
    struct jvm_evidence_limits l;
    jvm_evidence_default_limits(&l);
    l.import.jfr_export_depth = 64;
    struct jvm_evidence *ev;
    struct xlf_error err;
    enum xlf_status st = jvm_evidence_import_bytes(jfr, sizeof jfr - 1, "mem", JVM_SOURCE_JFR_JSON, NULL, &l, NULL, &ev, &err);
    check(st == XLF_OK, "synthetic JFR through the bundle (%s)", st ? err.message : "ok");
    if (!st) {
        const struct xlf_doc *d = jvm_evidence_doc(ev);
        struct jvm_evidence_frame f[3];
        for (int i = 0; i < 3; ++i)
            jvm_evidence_frame(ev, (uint32_t)i, &f[i]);
        check(d->frames[0].kind == XLF_KIND_JIT && f[0].inlined && f[0].has_bci && f[0].bci == 7 && !f[0].heuristic_text,
              "inlined JIT frame: C05 kind jit, inlined + bci kept by the API");
        check(d->frames[1].kind == XLF_KIND_NATIVE && !d->frames[1].has_pc && f[1].jvm_native_method && !f[1].native_authority,
              "Java native method: C05 kind native without PC; API says jvm_native_method, no native authority");
        check(f[2].mode == JVM_FRAME_INTERPRETED && f[2].loader_status == JVM_LOADER_NOT_EXPORTED,
              "frame without loader information: identity basis loader_not_exported");
        struct jvm_evidence_thread t;
        jvm_evidence_thread(ev, 0, &t);
        check(t.what == JVM_EVIDENCE_PLATFORM_OR_VIRTUAL && t.is_virtual == JVM_YES && !t.has_os_tid && t.java_tid == 40,
              "virtual thread: virtual=yes, OS TID absent, Java TID 40");
        jvm_evidence_free(ev);
    }
    st = jvm_evidence_import_bytes(probes, sizeof probes - 1, "mem", JVM_SOURCE_COROUTINE_PROBES, NULL, NULL, NULL, &ev,
                                   &err);
    check(st == XLF_OK, "synthetic coroutine probes through the bundle (%s)", st ? err.message : "ok");
    if (!st) {
        const struct xlf_doc *d = jvm_evidence_doc(ev);
        struct jvm_evidence_thread a, b;
        uint32_t ia = xlf_find_thread(d, "c0"), ib = xlf_find_thread(d, "c1");
        jvm_evidence_thread(ev, ia, &a);
        jvm_evidence_thread(ev, ib, &b);
        struct jvm_evidence_stack s1;
        jvm_evidence_stack(ev, 1, &s1);
        struct jvm_evidence_frame f;
        jvm_evidence_frame(ev, d->stacks[1].first_frame, &f);
        check(a.what == JVM_EVIDENCE_COROUTINE && !a.has_parent && a.parent_doc_thread == XLF_NONE &&
                  !strcmp(a.parent_relation, "parent_not_tracked") && b.has_parent && b.parent_seq == 1 &&
                  b.parent_doc_thread == ia && b.has_java_tid && b.java_tid == 5 && b.is_virtual == JVM_NO,
              "coroutine parent resolves to the parent's document thread; untracked root stays untracked");
        check(d->stacks[1].frame_count == 1 && s1.creation_count == 2 && f.heuristic_text,
              "creation frames kept as context (2), not callers; text frames marked heuristic");
        jvm_evidence_free(ev);
    }
}

int main(int argc, char **argv)
{
    if (argc == 5 && !strcmp(argv[1], "--mutate")) {
        static const char *const names[] = {"jfr-json", "thread-dump-json", "thread-print", "coroutine-probes"};
        tmp = argv[4];
        for (int k = 0; k < 4; ++k)
            if (!strcmp(argv[3], names[k]))
                citations_after_mutation(argv[2], (enum jvm_source)k, 0);
        printf("%d cases, %d failures\n", cases, failures);
        return failures || !cases;
    }
    if (argc != 3) {
        fprintf(stderr, "usage: test-evidence REGRESS_DIR TMPDIR | --mutate FILE SOURCE TMPDIR\n");
        return 2;
    }
    regress = argv[1];
    tmp = argv[2];
    pre_cancel();
    char loaders[4096];
    snprintf(loaders, sizeof loaders, "%s/class-loader-collision.json", regress);
    citations_after_mutation(loaders, JVM_SOURCE_JFR_JSON, 1);
    char path[4096];
    snprintf(path, sizeof path, "%s/class-loader-collision.json", regress);
    budget_and_cancel(path, JVM_SOURCE_JFR_JSON);
    static const char print[] = "77:\n2026-10-05 00:00:00\nFull thread dump Synthetic VM (9.9 mixed mode):\n\n"
                                "\"w\" #5 [77] prio=5 os_prio=0 tid=0x00007f00 nid=77 runnable  [0x0]\n"
                                "   java.lang.Thread.State: RUNNABLE\n\tat app//pkg.C.m(C.java:3)\n"
                                "\tat java.lang.Object.wait(java.base@9.9/Native Method)\n\n"
                                "\"v\" #6 [78] prio=5 os_prio=0 tid=0x00007f01 nid=78 waiting\n\tat pkg.D.n(D.java:1)\n";
    snprintf(path, sizeof path, "%s/ev-print-%ld.txt", tmp, (long)getpid());
    spit(path, print, sizeof print - 1);
    budget_and_cancel(path, JVM_SOURCE_THREAD_PRINT);
    unlink(path);
    snprintf(path, sizeof path, "%s/ev-probes-%ld.json", tmp, (long)getpid());
    spit(path, probes, sizeof probes - 1);
    budget_and_cancel(path, JVM_SOURCE_COROUTINE_PROBES);
    unlink(path);
    guard_page();
    distinctions();
    printf("%d cases, %d failures\n", cases, failures);
    return failures != 0;
}
