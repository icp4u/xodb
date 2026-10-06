/* C05-R3 / C06 importer regressions. Every case runs in a forked
 * child, so a sanitizer abort or signal on an unfixed importer is a counted
 * failure rather than the end of the run:
 *  - bounded text: Thread.print lines shorter than a fixed prefix (a
 *    45-byte reproducer and variants) and "Full thread dump (" with an empty name;
 *  - time: real calendar days, leap years, zone offset range, leap second,
 *    fraction precision and the exact signed epoch-ns endpoints;
 *  - identity: frames of one method from loader-A and loader-B stay two functions.
 * Expected epoch values were computed independently (Python datetime + integer
 * nanoseconds), not with the code under test.
 *   test-r3-import REGRESS_DIR TMPDIR */
#define _GNU_SOURCE 1
#include "jvm_import.h"
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static const char *regress, *tmp;
static int failures, cases;

static void report(int ok, const char *name, const char *why)
{
    cases++;
    failures += !ok;
    printf("%s %s%s%s\n", ok ? "ok  " : "FAIL", name, why ? ": " : "", why ? why : "");
    fflush(stdout);
}
/* Runs fn in a child; exit 0 = pass, anything else (incl. abort/signal) = fail. */
static void run(const char *name, int (*fn)(const void *), const void *arg)
{
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0)
        _exit(fn(arg) ? 0 : 1);
    int st = 0;
    waitpid(pid, &st, 0);
    char why[96] = "";
    if (WIFSIGNALED(st))
        snprintf(why, sizeof why, "child killed by signal %d", WTERMSIG(st));
    else if (WEXITSTATUS(st) > 1)
        snprintf(why, sizeof why, "child exited %d (sanitizer or abort)", WEXITSTATUS(st));
    report(WIFEXITED(st) && WEXITSTATUS(st) == 0, name, why[0] ? why : NULL);
}
static int say(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("     ");
    vprintf(fmt, ap);
    putchar('\n');
    va_end(ap);
    return 0;
}

/* ---- time ---- */
struct tcase {
    const char *text;
    int ok;
    long long ns;
};
static const struct tcase times[] = {
    {"1970-01-01T00:00:00Z", 1, 0},
    {"1677-09-21T00:12:43.145224192Z", 1, (-9223372036854775807LL - 1)}, /* INT64_MIN */
    {"1677-09-21T00:12:43.145224191Z", 0, 0},                            /* one below */
    {"2262-04-11T23:47:16.854775807Z", 1, 9223372036854775807LL},       /* INT64_MAX */
    {"2262-04-11T23:47:16.854775808Z", 0, 0},                           /* addition overflow */
    {"9999-01-01T00:00:00Z", 0, 0},                                     /* multiplication overflow */
    {"0000-01-01T00:00:00Z", 0, 0},
    {"2024-02-29T12:00:00Z", 1, 1709208000000000000LL},
    {"2000-02-29T00:00:00Z", 1, 951782400000000000LL},
    {"2023-02-29T00:00:00Z", 0, 0},
    {"2100-02-29T00:00:00Z", 0, 0},
    {"2026-02-31T00:00:00Z", 0, 0}, /* invented date */
    {"2026-04-31T00:00:00Z", 0, 0},
    {"2026-10-05T24:00:00Z", 0, 0},
    {"2016-12-31T23:59:60Z", 0, 0}, /* leap second: not folded into the next second */
    {"2026-10-05T00:00:00+99:99", 0, 0}, /* invalid zone */
    {"2026-10-05T00:00:00+18:00", 1, 1791093600000000000LL},
    {"2026-10-05T00:00:00-18:00", 1, 1791223200000000000LL},
    {"2026-10-05T00:00:00+18:01", 0, 0},
    {"2026-10-05T00:00:00+05:60", 0, 0},
    {"1900-01-01T00:00:00+05:30:15", 1, -2209008615000000000LL},
    {"1969-12-31T23:59:59.5Z", 1, -500000000LL},
    {"1970-01-01T00:00:00.000000001+00:01", 1, -59999999999LL},
    {"2026-10-05T13:09:55.165454909+05:30", 1, 1791185995165454909LL},
    {"2026-10-05T00:39:55.1234567891Z", 0, 0},
    {"2026-10-05T00:39:55", 0, 0},
    {"2026-10-05T00:39:55+05", 0, 0},
};
static int time_case(const void *arg)
{
    const struct tcase *c = arg;
    int64_t v = 0x5a5a5a5a;
    int rc = jvm_parse_iso_time(c->text, &v);
    if (c->ok)
        return rc == 0 && v == c->ns ? 1 : say("rc=%d value %lld want %lld", rc, (long long)v, c->ns);
    return rc != 0 && v == 0x5a5a5a5a ? 1 : say("rc=%d value %lld: accepted or written", rc, (long long)v);
}

static int write_file(const char *path, const char *text, size_t n)
{
    FILE *f = fopen(path, "wb");
    if (!f)
        return 0;
    int ok = fwrite(text, 1, n, f) == n;
    return fclose(f) == 0 && ok;
}
static char *read_file(const char *path, size_t *n)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return NULL;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *s = malloc((size_t)size + 1);
    if (s && fread(s, 1, (size_t)size, f) != (size_t)size) {
        free(s);
        s = NULL;
    }
    fclose(f);
    if (s) {
        s[size] = 0;
        *n = (size_t)size;
    }
    return s;
}

/* A fixture JFR sample with its startTime replaced; imported, adapted and
 * decoded by the C05 reader. A bad time is kept raw, never a stack time. */
static int jfr_time_case(const void *arg)
{
    const char *when = arg;
    char src[4096], dst[4096];
    snprintf(src, sizeof src, "%s/jfr-time-sample.json", regress);
    snprintf(dst, sizeof dst, "%s/r3-time-%ld.json", tmp, (long)getpid());
    size_t n;
    char *text = read_file(src, &n);
    if (!text)
        return say("cannot read %s", src);
    const char *old = "9999-01-01T00:00:00Z";
    char *at = strstr(text, old);
    if (!at)
        return say("template lacks %s", old);
    size_t out_n = n - strlen(old) + strlen(when);
    char *out = malloc(out_n);
    memcpy(out, text, (size_t)(at - text));
    memcpy(out + (at - text), when, strlen(when));
    memcpy(out + (at - text) + strlen(when), at + strlen(old), n - (size_t)(at - text) - strlen(old));
    write_file(dst, out, out_n);
    struct jvm_limits l;
    jvm_limits_default(&l);
    l.jfr_export_depth = 2048;
    struct jvm_import *im = NULL;
    int rc = jvm_import_file(dst, JVM_SOURCE_JFR_JSON, &l, &im);
    unlink(dst);
    if (rc || im->record_count != 1)
        return say("import rc=%d %s", rc, im ? im->error : "");
    const struct jvm_record *r = &im->records[0];
    if (r->has_time_ns || !r->time_raw || strcmp(jvm_str(im, r->time_raw), when))
        return say("time accepted (%lld) or raw text lost", (long long)r->time_ns);
    struct jvm_query q = {.name = "lframes"};
    struct xlf_doc *d = NULL;
    struct xlf_error err;
    if (jvm_lframes_decode(im, &q, 4096, NULL, NULL, &d, &err) || !d || d->stack_count != 1 ||
        d->stacks[0].start_ns.known)
        return say("composed document: %s", d ? "stack carries a time" : err.message);
    xlf_free(d);
    jvm_import_free(im);
    free(text);
    free(out);
    return 1;
}

/* ---- bounded Thread.print text ---- */
struct pcase {
    const char *text;
    size_t len;
    int records;
};
#define P(s, r) {s, sizeof(s) - 1, r}
static const struct pcase prints[] = {
    P("1:\nx\nFull thread dump Test (1 mixed mode):\nx\n", 0), /* 45-byte reproducer */
    P("1:\nx\nFull thread dump Test (1 mixed mode):\nx", 0),   /* final line without newline */
    P("1:\nx\nFull thread dump T (1 m):\n\nJ", 0),
    P("1:\nx\nFull thread dump T (1 m):\n\nThreads class", 0),
    P("1:\nx\nFull thread dump T (1 m):\n\n0", 0),
    P("1:\nx\nFull thread dump T (1 m):\n\n\"a\" #1 [7] os_prio=0 tid=0x1 nid=7 r\n\tat", 1),
    P("1:\nx\nFull thread dump T (1 m):\n\n\"a\" #1 [7] os_prio=0 tid=0x1 nid=7 r\n   java.lang.Thread.Stat", 1),
    P("1:\nx\nFull thread dump T (1 m):\n\n\"a\" #1 [7] os_prio=0 tid=0x1 nid=7 r\n\t-", 1),
    P("1:\nx\nFull thread dump T (1 m):\n\n\"a\" #1 [7", 0),
    P("1:\nx\nFull thread dump T (1 m):\n\nos_prio", 0),
};
static int print_case(const void *arg)
{
    const struct pcase *c = arg;
    char path[4096];
    snprintf(path, sizeof path, "%s/r3-print-%ld.txt", tmp, (long)getpid());
    /* Exactly-sized heap copy: the importer's own buffer is the subject. */
    write_file(path, c->text, c->len);
    struct jvm_limits l;
    jvm_limits_default(&l);
    struct jvm_import *im = NULL;
    int rc = jvm_import_file(path, JVM_SOURCE_THREAD_PRINT, &l, &im);
    unlink(path);
    if (rc)
        return say("import rc=%d %s", rc, im ? im->error : "");
    if (im->record_count != (uint64_t)c->records)
        return say("records %llu want %d", (unsigned long long)im->record_count, c->records);
    jvm_import_free(im);
    return 1;
}
/* "Full thread dump (" leaves no JVM name; R2 computed a negative length. */
static int empty_name_case(const void *arg)
{
    (void)arg;
    static const char text[] = "1:\nx\nFull thread dump (21 mixed mode):\nnext line\n";
    char path[4096];
    snprintf(path, sizeof path, "%s/r3-name-%ld.txt", tmp, (long)getpid());
    write_file(path, text, sizeof text - 1);
    struct jvm_limits l;
    jvm_limits_default(&l);
    struct jvm_import *im = NULL;
    int rc = jvm_import_file(path, JVM_SOURCE_THREAD_PRINT, &l, &im);
    unlink(path);
    if (rc)
        return say("import rc=%d", rc);
    const char *name = jvm_str(im, im->jvm_name);
    if (name && strchr(name, '\n'))
        return say("jvm name runs into the next line: \"%.40s\"", name);
    if (name && *name)
        return say("jvm name \"%s\" invented", name);
    return 1;
}

/* ---- loader identity ---- */
static int loader_case(const void *arg)
{
    (void)arg;
    char path[4096];
    snprintf(path, sizeof path, "%s/class-loader-collision.json", regress);
    struct jvm_limits l;
    jvm_limits_default(&l);
    l.jfr_export_depth = 2048;
    struct jvm_import *im = NULL;
    if (jvm_import_file(path, JVM_SOURCE_JFR_JSON, &l, &im) || im->record_count != 2)
        return say("import failed");
    struct jvm_query q = {.name = "lframes"};
    struct xlf_doc *d = NULL;
    struct xlf_error err;
    if (jvm_lframes_decode(im, &q, 4096, NULL, NULL, &d, &err))
        return say("compose: %s", err.message);
    /* Independent of the adapter key: the two source frames differ only in their
     * class loader name, so they must reach two distinct reader functions. */
    uint32_t f0 = d->frames[d->stacks[0].first_frame].function, f1 = d->frames[d->stacks[1].first_frame].function;
    if (d->function_count != 2 || f0 == f1 || f0 == XLF_NONE || f1 == XLF_NONE)
        return say("functions=%zu stack0->%u stack1->%u (conflated)", d->function_count, f0, f1);
    struct xlf_aggregate a;
    if (xlf_aggregate(d, XLF_NONE, NULL, NULL, &a, &err) || a.self[f0].lo != 1 || a.self[f1].lo != 1)
        return say("aggregate does not keep one sample per loader");
    xlf_aggregate_free(&a);
    xlf_free(d);
    jvm_import_free(im);
    return 1;
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: test-r3-import REGRESS_DIR TMPDIR\n");
        return 2;
    }
    regress = argv[1];
    tmp = argv[2];
    char name[160];
    for (size_t i = 0; i < sizeof times / sizeof *times; ++i) {
        snprintf(name, sizeof name, "time %s -> %s", times[i].text, times[i].ok ? "exact epoch ns" : "refused, output untouched");
        run(name, time_case, &times[i]);
    }
    static const char *const jfr_times[] = {"9999-01-01T00:00:00Z", "2262-04-11T23:47:16.854775808Z",
                                            "2026-02-31T00:00:00Z", "2026-10-05T00:00:00+99:99",
                                            "2016-12-31T23:59:60Z"};
    for (size_t i = 0; i < sizeof jfr_times / sizeof *jfr_times; ++i) {
        snprintf(name, sizeof name, "JFR startTime %s kept raw, no stack time, document decodes", jfr_times[i]);
        run(name, jfr_time_case, jfr_times[i]);
    }
    for (size_t i = 0; i < sizeof prints / sizeof *prints; ++i) {
        snprintf(name, sizeof name, "Thread.print short tail #%zu (%zu bytes) imports without reading past the input", i,
                 prints[i].len);
        run(name, print_case, &prints[i]);
    }
    run("Thread.print \"Full thread dump (\": no JVM name, no negative length", empty_name_case, NULL);
    run("class-loader-collision.json: loader-A and loader-B stay two functions", loader_case, NULL);
    printf("%d cases, %d failures\n", cases, failures);
    return failures != 0;
}
