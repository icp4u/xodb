/* C05-R4 importer regressions.
 *   test-r4-import REGRESS_DIR TMPDIR
 * F1  Thread.print under a whole-operation budget: tp-null-frame.txt at every
 *     limit 26000..30000 and every limit up to its peak; each run memory_limit
 *     with the reported peak within the limit (R3: SIGSEGV, NULL dereference).
 * F3  invalid UTF-8 in the Thread.print timestamp line: imports, text repaired,
 *     time "malformed"; a 19-byte non-time line is malformed, not unzoned.
 * F4  identity-variants.json: p/C and p.C stay two functions; m\0a and m\0b stay
 *     two functions and are never shortened to "m".
 * F5  CRLF Thread.print: the same functions and stacks as the LF text.
 * F6  budget failures name their reason (never "import: failed"); precision is
 *     reported only for well-formed text; /proc pseudo-files are refused.
 * API (R4 only) opaque info accessor; concurrent aggregates share the budget.
 * Built against a C05-R3 tree (no XLF_HAVE_READ_STABLE) it runs the portable
 * checks, which fail there. */
#define _GNU_SOURCE 1
#include "jvm_evidence.h"
#ifdef XLF_HAVE_READ_STABLE
#include "jvm_evidence_internal.h"
#endif
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static const char *regress, *tmp;
static int failures, cases;
static void check(int ok, const char *fmt, ...)
{
    char what[700];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(what, sizeof what, fmt, ap);
    va_end(ap);
    cases++;
    failures += !ok;
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    fflush(stdout);
}
static __attribute__((unused)) void spit(const char *path, const char *s, size_t n)
{
    FILE *f = fopen(path, "wb");
    fwrite(s, 1, n, f);
    fclose(f);
}
static enum xlf_status ev_import(const char *path, enum jvm_source src, size_t limit, struct jvm_evidence **ev,
                                 struct xlf_error *err)
{
    struct jvm_evidence_limits l;
    jvm_evidence_default_limits(&l);
    l.import.jfr_export_depth = 2048;
    l.max_total_bytes = limit;
    return jvm_evidence_import(path, src, NULL, &l, NULL, ev, err);
}

/* F1: the sweep runs in a child so a crash is a reported failure, not an abort. */
static void f1(void)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/tp-null-frame.txt", regress);
    struct jvm_evidence *ev;
    struct xlf_error err;
    enum xlf_status st = ev_import(path, JVM_SOURCE_THREAD_PRINT, 0, &ev, &err);
    struct jvm_evidence_usage u = {0};
    if (!st) {
        jvm_evidence_usage(ev, &u);
        jvm_evidence_free(ev);
    }
    check(st == XLF_OK, "F1 tp-null-frame.txt imports unlimited (whole peak %zu)", u.whole_peak);
    fflush(stdout);
    pid_t child = fork();
    if (!child) {
        int bad = 0, runs = 0;
        size_t top = u.whole_peak > 30000 ? u.whole_peak : 30000;
        for (size_t lim = 1; lim <= top; lim++) {
            if (lim >= u.whole_peak && lim < 26000)
                continue;
            runs++;
            st = ev_import(path, JVM_SOURCE_THREAD_PRINT, lim, &ev, &err);
            int ok = lim >= u.whole_peak ? st == XLF_OK : st == XLF_E_MEMORY && err.peak_bytes <= lim;
            if (!st)
                jvm_evidence_free(ev);
            if (!ok && bad++ < 5)
                printf("     limit %zu: %s peak %zu %s\n", lim, xlf_status_name(st), err.peak_bytes, err.message);
        }
        printf("     %d limits run (1..%zu)\n", runs, top);
        _exit(bad ? 1 : 0);
    }
    int ws;
    waitpid(child, &ws, 0);
    check(WIFEXITED(ws) && !WEXITSTATUS(ws),
          "F1 every limit 1..max(peak,30000) (incl. 26000..30000): memory_limit with peak within the limit below the "
          "peak, ok at and above it (child %s %d)",
          WIFSIGNALED(ws) ? "killed by signal" : "exit", WIFSIGNALED(ws) ? WTERMSIG(ws) : WEXITSTATUS(ws));
}

static void f3(void)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/tp-invalid-utf8-time.txt", regress);
    struct jvm_evidence *ev;
    struct xlf_error err;
    enum xlf_status st = ev_import(path, JVM_SOURCE_THREAD_PRINT, 0, &ev, &err);
    struct jvm_evidence_stack s = {0};
    if (!st)
        jvm_evidence_stack(ev, 0, &s);
    check(st == XLF_OK && s.time_status == JVM_TIME_MALFORMED && s.time_raw && strstr(s.time_raw, "\xef\xbf\xbd"),
          "F3 invalid UTF-8 in the timestamp line: import %s, time %s, raw text repaired with U+FFFD",
          st ? err.message : "ok", jvm_time_status_name(s.time_status));
    if (!st)
        jvm_evidence_free(ev);
    static const char *const lines[] = {"xxxx-xxxxx xxxxxxxx", "2026-13-05 01:02:03", "2026-10-05 01:02:03"};
    static const unsigned want[] = {JVM_TIME_MALFORMED, JVM_TIME_INVALID_DATE, JVM_TIME_UNZONED};
    for (int i = 0; i < 3; i++) {
        char text[512];
        int n = snprintf(text, sizeof text,
                         "1:\n%s\nFull thread dump T (1 m):\n\n\"a\" #1 [2] os_prio=0 tid=0x1 nid=2 r\n\tat A.b(A.java:1)\n",
                         lines[i]);
        struct jvm_limits l;
        jvm_limits_default(&l);
        struct jvm_import *im = NULL;
        int rc = jvm_import_bytes(text, (size_t)n, "t", JVM_SOURCE_THREAD_PRINT, &l, NULL, &im);
        unsigned got = rc == 0 && im->record_count ? im->records[0].time_status : 99;
        check(got == want[i], "F3 Thread.print time line \"%s\": %s (want %s)", lines[i], jvm_time_status_name(got),
              jvm_time_status_name(want[i]));
        jvm_import_free(im);
    }
}

static void f4(void)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/identity-variants.json", regress);
    struct jvm_evidence *ev;
    struct xlf_error err;
    enum xlf_status st = ev_import(path, JVM_SOURCE_JFR_JSON, 0, &ev, &err);
    check(st == XLF_OK, "F4 identity-variants.json imports (%s)", st ? err.message : "ok");
    if (st)
        return;
    const struct xlf_doc *d = jvm_evidence_doc(ev);
    uint32_t fn[14];
    for (uint32_t i = 0; i < 14 && i < d->stack_count; i++)
        fn[i] = d->frames[d->stacks[i].first_frame].function;
    struct jvm_evidence_frame a, b;
    jvm_evidence_function(ev, fn[10], &a);
    jvm_evidence_function(ev, fn[11], &b);
    check(d->stack_count == 14 && fn[0] != fn[1], "F4 raw class p/C and p.C: two functions (f%u, f%u)", fn[0], fn[1]);
    check(d->stack_count == 14 && fn[10] != fn[11] && strcmp(a.method, "m") && strcmp(b.method, "m") &&
              strcmp(a.method, b.method),
          "F4 methods m\\0a and m\\0b: two functions, names kept distinct and unshortened (%s, %s)", a.method, b.method);
    /* 14 events, 13 raw identities (the two unnamed x/L1 loaders are the same raw
     * object); classLoader null and an absent loader merge as loader_not_exported. */
    check(d->function_count == 12 && fn[3] == fn[4] && fn[5] == fn[6],
          "F4 12 functions: only null/absent loader (loader_not_exported) and the same-type unnamed loaders merge (%zu)",
          d->function_count);
    jvm_evidence_free(ev);
}

static const char print_lf[] = "77:\n2026-10-05 00:00:00\nFull thread dump Synthetic VM (9.9 mixed mode):\n\n"
                               "\"w\" #5 [77] prio=5 os_prio=0 tid=0x00007f00 nid=77 runnable  [0x0]\n"
                               "   java.lang.Thread.State: RUNNABLE\n\tat app//pkg.C.m(C.java:3)\n"
                               "\tat java.lang.Object.wait(java.base@9.9/Native Method)\n\t- locked <0x1> (a pkg.C)\n\n"
                               "\"v\" #6 [78] prio=5 os_prio=0 tid=0x00007f01 nid=78 waiting\n\tat pkg.D.n(D.java:1)\n";
static void f5(void)
{
    char crlf[2048];
    size_t n = 0;
    for (const char *p = print_lf; *p; p++) {
        if (*p == '\n')
            crlf[n++] = '\r';
        crlf[n++] = *p;
    }
    struct jvm_evidence *a = NULL, *b = NULL;
    struct xlf_error e1, e2;
    enum xlf_status s1 = jvm_evidence_import_bytes(print_lf, sizeof print_lf - 1, "lf", JVM_SOURCE_THREAD_PRINT, NULL,
                                                   NULL, NULL, &a, &e1);
    enum xlf_status s2 = jvm_evidence_import_bytes(crlf, n, "crlf", JVM_SOURCE_THREAD_PRINT, NULL, NULL, NULL, &b, &e2);
    const struct xlf_doc *da = s1 ? NULL : jvm_evidence_doc(a), *db = s2 ? NULL : jvm_evidence_doc(b);
    int same = da && db && da->function_count == db->function_count && da->stack_count == db->stack_count &&
               da->frame_count == db->frame_count;
    for (size_t i = 0; same && i < da->function_count; i++)
        same = !strcmp(da->functions[i].qualified.ptr ? da->functions[i].qualified.ptr : "",
                       db->functions[i].qualified.ptr ? db->functions[i].qualified.ptr : "");
    struct jvm_evidence_stack sa = {0}, sb = {0};
    if (same) {
        jvm_evidence_stack(a, 0, &sa);
        jvm_evidence_stack(b, 0, &sb);
    }
    check(same && da->function_count == 3 && sb.time_status == JVM_TIME_UNZONED && sa.time_status == sb.time_status,
          "F5 CRLF Thread.print: %zu functions, %zu stacks, time %s (LF text: %zu functions)", db ? db->function_count : 0,
          db ? db->stack_count : 0, jvm_time_status_name(sb.time_status), da ? da->function_count : 0);
    jvm_evidence_free(a);
    jvm_evidence_free(b);
}

static void f6(void)
{
    fflush(stdout);
    pid_t child = fork(); /* on R3 the F1 crash can be reached from here */
    if (child) {
        int ws;
        waitpid(child, &ws, 0);
        if (!WIFEXITED(ws))
            check(0, "F6 budget refusal messages: child killed by signal %d", WTERMSIG(ws));
        else
            check(WEXITSTATUS(ws) == 0, "F6 budget refusals all name the exhausted budget, never \"import: failed\"");
    } else {
    int bad = 0, runs = 0;
    for (size_t lim = 1; lim < 40000; lim += 7, runs++) {
        struct jvm_evidence *ev = NULL;
        struct xlf_error err;
        struct jvm_evidence_limits l;
        jvm_evidence_default_limits(&l);
        l.max_total_bytes = lim;
        enum xlf_status st = jvm_evidence_import_bytes(print_lf, sizeof print_lf - 1, "x", JVM_SOURCE_THREAD_PRINT, NULL,
                                                       &l, NULL, &ev, &err);
        if (!st)
            jvm_evidence_free(ev);
        else if (strstr(err.message, ": failed") || (!strstr(err.message, "budget") && !strstr(err.message, "memory"))) {
            if (bad++ < 3)
                printf("     limit %zu: %s\n", lim, err.message);
        }
    }
    printf("     %d budget refusals checked, %d unnamed\n", runs, bad);
    _exit(bad != 0);
    }
    static const struct {
        const char *s;
        unsigned want;
    } t[] = {{"2026-10-05T00:00:00.1234567890x", JVM_TIME_MALFORMED},
             {"2026-10-05T00:00:00.1234567890Z", JVM_TIME_PRECISION},
             {"2026-10-05T00:00:00.1234567890", JVM_TIME_PRECISION},
             {"2026-10-05T00:00:00.1234567890+25", JVM_TIME_MALFORMED},
             {"2026-02-30T00:00:00.1234567890Z", JVM_TIME_PRECISION},
             {"2026-10-05T00:00:00.123456789Z", JVM_TIME_OK}};
    int wrong = 0;
    for (size_t i = 0; i < sizeof t / sizeof *t; i++) {
        int64_t ns;
        unsigned got = (unsigned)jvm_parse_iso_time(t[i].s, &ns);
        if (got != t[i].want) {
            wrong++;
            printf("     %s: %s, want %s\n", t[i].s, jvm_time_status_name(got), jvm_time_status_name(t[i].want));
        }
    }
    check(!wrong, "F6 precision_finer_than_ns only for well-formed text (oracle precedence: malformed, precision, unzoned)");
    struct xlf_error err;
    struct xlf_doc *d = xlf_decode_file("/proc/self/status", NULL, NULL, &err);
    check(!d && err.status == XLF_E_IO, "F6 /proc pseudo-file refused by the reader as io_error (%s)",
          xlf_status_name(err.status));
    xlf_free(d);
    struct jvm_evidence *ev = NULL;
    enum xlf_status st = ev_import("/proc/self/status", JVM_SOURCE_THREAD_PRINT, 0, &ev, &err);
    check(st == XLF_E_IO && !strncmp(err.message, "read:", 5), "F6 /proc pseudo-file refused by the importer at read (%s)",
          xlf_status_name(st));
    jvm_evidence_free(ev);
}

#ifdef XLF_HAVE_READ_STABLE
struct agg_job {
    const struct jvm_evidence *ev;
    atomic_int ok, refused, other;
};
static void *agg_thread(void *arg)
{
    struct agg_job *j = arg;
    for (int i = 0; i < 300; i++) {
        struct xlf_aggregate a;
        struct xlf_error err;
        enum xlf_status st = jvm_evidence_aggregate(j->ev, XLF_NONE, NULL, &a, &err);
        if (!st) {
            atomic_fetch_add(&j->ok, 1);
            xlf_aggregate_free(&a);
        } else if (st == XLF_E_MEMORY && strstr(err.message, "concurrent"))
            atomic_fetch_add(&j->refused, 1);
        else
            atomic_fetch_add(&j->other, 1);
    }
    return NULL;
}
static void api(void)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/r4-api-%ld.txt", tmp, (long)getpid());
    spit(path, print_lf, sizeof print_lf - 1);
    struct jvm_evidence *ev;
    struct xlf_error err;
    enum xlf_status st = ev_import(path, JVM_SOURCE_THREAD_PRINT, 0, &ev, &err);
    struct jvm_evidence_info info = {0};
    if (!st)
        jvm_evidence_info(ev, &info);
    check(!st && info.source == JVM_SOURCE_THREAD_PRINT && info.has_pid && info.pid == 77 && !info.incomplete &&
              info.records == 2 && info.jvm_name && !strcmp(info.jvm_name, "Synthetic VM") &&
              info.collected_status == JVM_TIME_UNZONED && info.diagnostics.monitor_lines == 1 &&
              info.stability == XLF_STABILITY_LEASED,
          "API jvm_evidence_info: pid, completeness, runtime identity, diagnostics, stability %s",
          xlf_stability_name(info.stability));
    struct jvm_evidence_usage u = {0};
    if (!st) {
        jvm_evidence_usage(ev, &u);
        jvm_evidence_free(ev);
    }
    /* A budget leaving room for about one aggregate at a time. */
    struct xlf_aggregate one;
    st = ev_import(path, JVM_SOURCE_THREAD_PRINT, 0, &ev, &err);
    size_t need = 0;
    if (!st && !jvm_evidence_aggregate(ev, XLF_NONE, NULL, &one, &err)) {
        need = one.query_peak_bytes;
        xlf_aggregate_free(&one);
    }
    if (!st)
        jvm_evidence_free(ev);
    size_t limit = u.whole_peak > u.retained_bytes + need + need / 2 ? u.whole_peak : u.retained_bytes + need + need / 2;
    st = ev_import(path, JVM_SOURCE_THREAD_PRINT, limit, &ev, &err);
    check(!st && need, "API bundle with %zu bytes left after retention (one aggregate needs %zu)", limit - u.retained_bytes,
          need);
    if (!st) {
        struct agg_job j = {.ev = ev};
        pthread_t t[8];
        for (int i = 0; i < 8; i++)
            pthread_create(&t[i], NULL, agg_thread, &j);
        for (int i = 0; i < 8; i++)
            pthread_join(t[i], NULL);
        int after = jvm_evidence_aggregate(ev, XLF_NONE, NULL, &one, &err) == XLF_OK;
        if (after)
            xlf_aggregate_free(&one);
        check(j.ok > 0 && !j.other && after,
              "API 8 threads x 300 concurrent aggregates share the remainder: %d ok, %d refused as reserved by "
              "concurrent queries, %d other; all reservations returned",
              (int)j.ok, (int)j.refused, (int)j.other);
        jvm_evidence_free(ev);
    }
    unlink(path);
}
#endif

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: test-r4-import REGRESS_DIR TMPDIR\n");
        return 2;
    }
    regress = argv[1];
    tmp = argv[2];
    f1();
    f3();
    f4();
    f5();
    f6();
#ifdef XLF_HAVE_READ_STABLE
    api();
#endif
    printf("%d cases, %d failures\n", cases, failures);
    return failures != 0;
}
