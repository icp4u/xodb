/* Decoder tests for xodb.logical-frames v1 draft C05-1 (reader contract C05-R2-1): generated adversarial
 * and boundary inputs. Real runtime exports are checked by run-tests.sh. */
#define _GNU_SOURCE 1
#include "logical_frames.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures, cases;
static struct xlf_error agg_err;
#define AGG(d, t, a) xlf_aggregate((d), (t), NULL, NULL, (a), &agg_err)
/* Exact counter equals a small value. */
static int eq(struct xlf_count c, uint64_t v)
{
    return c.hi == 0 && c.lo == v;
}

#define SHA "\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""
#define PRODUCER "\"producer\":{\"name\":\"t\",\"version\":\"1\",\"kind\":\"cooperating_in_process\",\"sha256\":null}"
#define RUNTIME                                                                                     \
    "\"runtime\":{\"language\":\"python\",\"implementation\":\"cpython\",\"version\":\"3.14.7\","    \
    "\"build\":null,\"executable\":{\"path\":\"/usr/bin/python3\",\"sha256\":" SHA ",\"gnu_build_id\":\"0a1b\"},\"library\":null}"
#define PROCESS "\"process\":{\"pid\":42,\"start_ticks\":\"123\",\"boot_id\":\"aaaaaaaa-0000-4000-8000-000000000001\"}"
#define COLLECTION                                                                                  \
    "\"collection\":{\"method\":\"m\",\"trigger\":\"timer\",\"interval_ns\":\"5000000\",\"atomicity\":\"all_threads_one_call\"}"
#define TAIL "\"frame_order\":\"innermost_first\",\"weight_unit\":\"observation\",\"weight_semantics\":\"one\"}"
#define HEADER_WITH(clock)                                                                          \
    "{\"type\":\"header\",\"format\":\"xodb.logical-frames\",\"version\":1,\"draft\":\"C05-1\"," PRODUCER \
    ",\"source_kind\":\"cooperative_sample\"," RUNTIME "," PROCESS "," clock ",\"command\":[\"python3\",\"w.py\"]," COLLECTION "," TAIL
#define HEADER HEADER_WITH("\"clock\":{\"domain\":\"CLOCK_MONOTONIC\",\"unit\":\"ns\"}")
#define CODE "{\"type\":\"code\",\"id\":\"c1\",\"kind\":\"source_file\",\"path\":\"/w.py\",\"sha256\":" SHA ",\"bytes\":10}"
#define FIB "{\"type\":\"function\",\"id\":\"f1\",\"name\":\"fib\",\"qualified\":\"fib\",\"code\":\"c1\",\"first_line\":1,\"frame_kind\":\"interpreter\"}"
#define MAIN "{\"type\":\"function\",\"id\":\"f2\",\"name\":\"main\",\"qualified\":null,\"code\":\"c1\",\"first_line\":4,\"frame_kind\":\"interpreter\"}"
#define CFN "{\"type\":\"function\",\"id\":\"f3\",\"name\":\"each\",\"qualified\":\"Array#each\",\"code\":null,\"first_line\":null,\"frame_kind\":\"native\"}"
#define THREAD "{\"type\":\"thread\",\"id\":\"t1\",\"language_id\":\"ident:1\",\"name\":\"worker\",\"os_tid\":100,\"os_tid_source\":\"native_id\"}"
#define ACQ "{\"type\":\"acquisition\",\"seq\":1,\"start_ns\":\"100\",\"end_ns\":\"200\",\"stacks\":1}"
#define FR(f, line) "{\"function\":\"" f "\",\"kind\":\"interpreter\",\"line\":" #line ",\"provenance\":\"runtime\"}"
#define STACK_WITH(extra, frames)                                                                   \
    "{\"type\":\"stack\",\"id\":\"s1\",\"acquisition\":1,\"thread\":\"t1\",\"start_ns\":\"110\",\"end_ns\":\"120\"," \
    "\"trigger\":\"timer\",\"weight\":\"1\",\"state\":\"complete\",\"omitted\":null,\"reason\":null" extra ",\"frames\":[" frames "]}"
#define FRAMES FR("f1", 2) "," FR("f1", 2) "," FR("f1", 2) "," FR("f2", 5)
#define STACK STACK_WITH("", FRAMES)
#define END(n) "{\"type\":\"end\",\"records\":" #n ",\"acquisitions\":1,\"stacks\":1,\"status\":\"complete\"}"
#define BASE HEADER "\n" CODE "\n" FIB "\n" MAIN "\n" THREAD "\n" ACQ "\n" STACK "\n"
#define VALID BASE END(7) "\n"

static struct xlf_doc *run(const char *name, const char *input, size_t size, const struct xlf_limits *limits,
                           enum xlf_status want, uint32_t want_warnings)
{
    cases++;
    struct xlf_error err;
    struct xlf_doc *d = xlf_decode(input, size, limits, NULL, &err);
    enum xlf_status got = d ? XLF_OK : err.status;
    if (got != want || (d && (d->warnings & want_warnings) != want_warnings)) {
        failures++;
        printf("FAIL %-40s want %s/0x%x got %s/0x%x line %llu: %s\n", name, xlf_status_name(want), want_warnings,
               xlf_status_name(got), d ? d->warnings : 0, (unsigned long long)err.line, err.message);
    } else {
        printf("ok   %-40s %s%s%s\n", name, xlf_status_name(got), d ? "" : ": ", d ? "" : err.message);
    }
    return d;
}
static void expect(const char *name, const char *input, enum xlf_status want, uint32_t warnings)
{
    xlf_free(run(name, input, strlen(input), NULL, want, warnings));
}
static void check(int ok, const char *what)
{
    cases++;
    if (!ok) {
        failures++;
        printf("FAIL %s\n", what);
    } else
        printf("ok   %s\n", what);
}
/* Replace the first occurrence of from with to in VALID. */
static char *mutate(const char *base, const char *from, const char *to)
{
    const char *at = strstr(base, from);
    if (!at) {
        printf("FAIL mutation anchor missing: %s\n", from);
        failures++;
        return strdup(base);
    }
    size_t n = strlen(base) - strlen(from) + strlen(to) + 1;
    char *out = malloc(n);
    size_t prefix = (size_t)(at - base);
    memcpy(out, base, prefix);
    strcpy(out + prefix, to);
    strcat(out, at + strlen(from));
    return out;
}
static void expect_mut(const char *name, const char *from, const char *to, enum xlf_status want, uint32_t warnings)
{
    char *s = mutate(VALID, from, to);
    expect(name, s, want, warnings);
    free(s);
}
/* Mutation that adds `extra` records before the end record. */
static void expect_add(const char *name, const char *from, const char *to, int extra, enum xlf_status want,
                       uint32_t warnings)
{
    char end[128];
    snprintf(end, sizeof end, "{\"type\":\"end\",\"records\":%d,", 7 + extra);
    char *s = mutate(VALID, from, to);
    char *t = mutate(s, "{\"type\":\"end\",\"records\":7,", end);
    expect(name, t, want, warnings);
    free(s);
    free(t);
}

int main(void)
{
    /* Valid document, recursion ordering and aggregate rules. */
    struct xlf_doc *d = run("valid", VALID, strlen(VALID), NULL, XLF_OK, 0);
    if (d) {
        check(d->stack_count == 1 && d->stacks[0].frame_count == 4, "valid: one stack of four frames");
        const struct xlf_frame *f = &d->frames[d->stacks[0].first_frame];
        check(f[0].function == 0 && f[1].function == 0 && f[2].function == 0 && f[3].function == 1,
              "recursive frames keep innermost-first order");
        check(f[0].line == 2 && f[3].line == 5 && !f[0].has_pc, "lines retained; no PC invented");
        check(d->ended && d->warnings == 0, "valid: ended without warnings");
        check(d->stacks[0].cite.line == 7 && d->threads[0].cite.line == 5, "source citations are line numbers");
        struct xlf_aggregate a;
        check(!AGG(d, XLF_NONE, &a), "aggregate runs");
        check(eq(a.self[0], 1) && eq(a.inclusive[0], 1) && eq(a.inclusive[1], 1) && eq(a.self[1], 0),
              "recursion counted once per stack in inclusive weight");
        xlf_aggregate_free(&a);
        check(xlf_find_thread(d, "worker") == 0 && xlf_find_thread(d, "t1") == 0 &&
                  xlf_find_thread(d, "nope") == XLF_NONE,
              "thread lookup by id and name");
        xlf_free(d);
    }

    /* Truncation and loss. */
    {
        size_t cut = strlen(BASE) - 40; /* inside the stack record */
        d = run("truncated mid-record", VALID, cut, NULL, XLF_OK, XLF_W_TRUNCATED_TAIL | XLF_W_NO_END | XLF_W_ACQ_INCOMPLETE);
        if (d) {
            check(d->stack_count == 0 && d->truncated_tail.line == 7, "truncated tail is cited and ignored");
            xlf_free(d);
        }
        d = run("missing end record", BASE, strlen(BASE), NULL, XLF_OK, XLF_W_NO_END);
        if (d) {
            check(!d->ended && d->stack_count == 1, "no end: stacks kept, document marked incomplete");
            xlf_free(d);
        }
    }
    expect("empty input", "", XLF_E_EMPTY, 0);
    expect("interrupted producer", BASE "{\"type\":\"end\",\"records\":7,\"acquisitions\":1,\"stacks\":1,\"status\":\"interrupted\"}\n",
           XLF_OK, XLF_W_INTERRUPTED);
    expect("loss counts beyond u64 are exact, not refused",
           BASE "{\"type\":\"loss\",\"reason\":\"a\",\"count\":\"18446744073709551615\",\"acquisition\":null}\n"
                "{\"type\":\"loss\",\"reason\":\"b\",\"count\":\"2\",\"acquisition\":null}\n" END(9) "\n",
           XLF_OK, XLF_W_LOSS);
    expect("loss record", BASE "{\"type\":\"loss\",\"reason\":\"timer_overrun\",\"count\":\"3\",\"acquisition\":1}\n" END(8) "\n",
           XLF_OK, XLF_W_LOSS);
    expect("loss cites unknown acquisition", BASE "{\"type\":\"loss\",\"reason\":\"x\",\"count\":\"3\",\"acquisition\":9}\n",
           XLF_E_REFERENCE, 0);

    /* Partial stacks. */
    expect_mut("truncated stack with reason", "\"state\":\"complete\",\"omitted\":null,\"reason\":null",
               "\"state\":\"truncated\",\"omitted\":\"7\",\"reason\":\"max_depth\"", XLF_OK, XLF_W_PARTIAL_STACKS);
    expect_mut("partial stack without reason", "\"state\":\"complete\"", "\"state\":\"partial\"", XLF_E_SCHEMA, 0);
    expect_mut("complete stack omitting frames", "\"omitted\":null", "\"omitted\":\"2\"", XLF_E_SCHEMA, 0);
    expect_mut("complete stack without frames", FRAMES, "", XLF_E_SCHEMA, 0);
    {
        char *s = mutate(VALID, "\"state\":\"complete\",\"omitted\":null,\"reason\":null",
                         "\"state\":\"partial\",\"omitted\":null,\"reason\":\"thread exited during walk\"");
        d = run("partial stack aggregate", s, strlen(s), NULL, XLF_OK, XLF_W_PARTIAL_STACKS);
        if (d) {
            struct xlf_aggregate a;
            AGG(d, XLF_NONE, &a);
            check(eq(a.partial_weight, 1) && eq(a.total_weight, 1), "partial weight is reported separately");
            xlf_aggregate_free(&a);
            xlf_free(d);
        }
        free(s);
    }

    /* Duplicate and dangling identities. */
    expect("duplicate stack id", BASE "{\"type\":\"acquisition\",\"seq\":2,\"start_ns\":\"300\",\"end_ns\":\"400\",\"stacks\":1}\n"
           "{\"type\":\"stack\",\"id\":\"s1\",\"acquisition\":2,\"thread\":\"t1\",\"start_ns\":null,\"end_ns\":null,\"trigger\":\"t\","
           "\"weight\":\"1\",\"state\":\"complete\",\"omitted\":null,\"reason\":null,\"frames\":[" FR("f1", 1) "]}\n",
           XLF_E_DUPLICATE, 0);
    expect_mut("duplicate function id", MAIN, FIB, XLF_E_DUPLICATE, 0);
    expect_mut("duplicate acquisition seq", ACQ, ACQ "\n" ACQ, XLF_E_DUPLICATE, 0);
    expect_mut("undefined function", FR("f2", 5), FR("f9", 5), XLF_E_REFERENCE, 0);
    expect_mut("undefined thread", "\"thread\":\"t1\"", "\"thread\":\"t2\"", XLF_E_REFERENCE, 0);
    expect_mut("undefined acquisition", "\"acquisition\":1", "\"acquisition\":2", XLF_E_REFERENCE, 0);
    expect_mut("forward reference", FIB "\n" MAIN "\n", MAIN "\n", XLF_E_REFERENCE, 0);

    /* Identity rules. */
    expect_mut("thread pid mismatch", "\"os_tid_source\":\"native_id\"}", "\"os_tid_source\":\"native_id\",\"pid\":43}",
               XLF_E_IDENTITY, 0);
    expect_mut("thread pid match", "\"os_tid_source\":\"native_id\"}", "\"os_tid_source\":\"native_id\",\"pid\":42}", XLF_OK, 0);
    expect_mut("uppercase digest", "\"sha256\":" SHA ",\"bytes\"",
               "\"sha256\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"bytes\"", XLF_E_IDENTITY, 0);
    expect_mut("short digest", "\"sha256\":" SHA ",\"bytes\"", "\"sha256\":\"abcd\",\"bytes\"", XLF_E_IDENTITY, 0);
    expect_mut("absent digest without reason", "\"sha256\":" SHA ",\"bytes\"", "\"sha256\":null,\"bytes\"", XLF_E_IDENTITY, 0);
    expect_mut("absent digest with reason", "\"sha256\":" SHA ",\"bytes\"",
               "\"sha256\":null,\"unavailable\":\"frozen\",\"bytes\"", XLF_OK, 0);
    expect_mut("missing digest member", "\"sha256\":" SHA ",\"bytes\"", "\"bytes\"", XLF_E_SCHEMA, 0);
    expect_mut("odd build id", "\"gnu_build_id\":\"0a1b\"", "\"gnu_build_id\":\"0a1\"", XLF_E_IDENTITY, 0);
    expect_mut("pid unknown without reason", "\"pid\":42,", "\"pid\":null,", XLF_E_IDENTITY, 0);
    expect_mut("pid unknown with reason", "\"pid\":42,", "\"pid\":null,\"unavailable\":\"imported report lacks pid\",", XLF_OK, 0);
    expect_mut("pid zero", "\"pid\":42,", "\"pid\":0,", XLF_E_IDENTITY, 0);
    expect_mut("bad boot id", "aaaaaaaa-0000", "AAAAAAAA-0000", XLF_E_IDENTITY, 0);
    expect_mut("os tid unknown without reason", "\"os_tid\":100,\"os_tid_source\":\"native_id\"", "\"os_tid\":null", XLF_E_IDENTITY, 0);
    expect_mut("os tid unknown with reason", "\"os_tid\":100,\"os_tid_source\":\"native_id\"",
               "\"os_tid\":null,\"os_tid_reason\":\"M:N\"", XLF_OK, 0);
    expect_add("os tid shared by two language threads", THREAD,
               THREAD "\n{\"type\":\"thread\",\"id\":\"t2\",\"language_id\":\"ident:2\",\"name\":\"w2\",\"os_tid\":100,\"os_tid_source\":\"n\"}",
               1, XLF_OK, XLF_W_OS_TID_SHARED);
    expect_add("code path reused with new content", MAIN,
               "{\"type\":\"code\",\"id\":\"c2\",\"kind\":\"source_file\",\"path\":\"/w.py\",\"sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"bytes\":11}\n" MAIN,
               1, XLF_OK, XLF_W_CODE_PATH_REUSED);

    /* Clocks. */
    {
        char *s = mutate(VALID, "\"clock\":{\"domain\":\"CLOCK_MONOTONIC\",\"unit\":\"ns\"}",
                         "\"clock\":null,\"clock_unavailable\":\"report has no timestamps\"");
        expect("times without a clock", s, XLF_E_CLOCK, 0);
        char *t = mutate(s, "\"start_ns\":\"100\",\"end_ns\":\"200\"", "\"start_ns\":null,\"end_ns\":null");
        char *u = mutate(t, "\"start_ns\":\"110\",\"end_ns\":\"120\"", "\"start_ns\":null,\"end_ns\":null");
        expect("no clock and no times", u, XLF_OK, XLF_W_NO_CLOCK);
        free(s), free(t), free(u);
    }
    expect_mut("clock null without reason", "\"clock\":{\"domain\":\"CLOCK_MONOTONIC\",\"unit\":\"ns\"}", "\"clock\":null",
               XLF_E_SCHEMA, 0);
    expect_mut("clock unit not ns", "\"unit\":\"ns\"", "\"unit\":\"ms\"", XLF_E_SCHEMA, 0);
    expect_mut("stack outside acquisition", "\"start_ns\":\"110\"", "\"start_ns\":\"90\"", XLF_E_CLOCK, 0);
    expect_mut("stack ends before start", "\"end_ns\":\"120\"", "\"end_ns\":\"105\"", XLF_E_CLOCK, 0);
    expect_mut("half-known interval", "\"end_ns\":\"120\"", "\"end_ns\":null", XLF_E_CLOCK, 0);
    expect_mut("time as JSON number", "\"start_ns\":\"110\"", "\"start_ns\":110", XLF_E_SCHEMA, 0);
    expect_mut("time with leading zero", "\"start_ns\":\"110\"", "\"start_ns\":\"0110\"", XLF_E_SCHEMA, 0);

    /* Native PCs and addresses. */
    expect_mut("interpreter frame with pc", FR("f2", 5),
               "{\"function\":\"f2\",\"kind\":\"interpreter\",\"line\":5,\"provenance\":\"runtime\",\"pc\":\"0x401000\"}",
               XLF_E_INVENTED_PC, 0);
    {
        char *s0 = mutate(VALID, MAIN, MAIN "\n" CFN);
        char *s = mutate(s0, END(7), END(8));
        free(s0);
        char *t = mutate(s, FR("f2", 5),
                         "{\"function\":\"f3\",\"kind\":\"native\",\"line\":null,\"provenance\":\"runtime\",\"pc\":\"0xffffffffffffffff\"}");
        d = run("high-bit native pc", t, strlen(t), NULL, XLF_OK, 0);
        if (d) {
            check(d->frames[3].has_pc && d->frames[3].pc == UINT64_MAX, "high-bit PC decoded exactly");
            xlf_free(d);
        }
        char *u = mutate(t, "0xffffffffffffffff", "0x10000000000000000");
        expect("pc wider than 64 bits", u, XLF_E_SCHEMA, 0);
        char *v = mutate(t, "0xffffffffffffffff", "0x00ff");
        expect("non-canonical pc", v, XLF_E_SCHEMA, 0);
        char *w = mutate(t, "\"provenance\":\"runtime\",\"pc\"", "\"provenance\":\"cooperative_annotation\",\"pc\"");
        expect("cooperative frame with pc", w, XLF_E_INVENTED_PC, 0);
        char *x = mutate(s, FR("f2", 5), "{\"function\":\"f3\",\"kind\":\"interpreter\",\"line\":null,\"provenance\":\"runtime\"}");
        expect("frame kind differs from function", x, XLF_E_SCHEMA, 0);
        free(s), free(t), free(u), free(v), free(w), free(x);
    }
    expect_mut("native transition marker", FR("f2", 5),
               "{\"function\":null,\"kind\":\"native_transition\",\"line\":null,\"provenance\":\"cooperative_annotation\","
               "\"label\":\"libc:qsort\",\"reason\":\"declared\"}," FR("f2", 5),
               XLF_OK, 0);
    expect_mut("marker without label", FR("f2", 5),
               "{\"function\":null,\"kind\":\"native_transition\",\"line\":null,\"provenance\":\"cooperative_annotation\"}",
               XLF_E_SCHEMA, 0);
    expect_mut("interpreter marker without function", FR("f2", 5),
               "{\"function\":null,\"kind\":\"interpreter\",\"line\":1,\"provenance\":\"runtime\",\"label\":\"x\",\"reason\":\"y\"}",
               XLF_E_SCHEMA, 0);
    expect_mut("interpreter frame without line or reason", FR("f2", 5),
               "{\"function\":\"f2\",\"kind\":\"interpreter\",\"line\":null,\"provenance\":\"runtime\"}", XLF_E_SCHEMA, 0);
#define JIT(id, start, end, load, unload)                                                           \
    "{\"type\":\"code\",\"id\":\"" id "\",\"kind\":\"jit\",\"path\":null,\"sha256\":null,\"unavailable\":\"jit\",\"bytes\":null," \
    "\"range\":{\"start\":\"" start "\",\"end\":\"" end "\",\"load_ns\":" load ",\"unload_ns\":" unload "}}"
    expect_add("jit reuse with disjoint lifetimes", CODE,
               CODE "\n" JIT("j1", "0x1000", "0x2000", "\"10\"", "\"20\"") "\n" JIT("j2", "0x1800", "0x2800", "\"20\"", "null"),
               2, XLF_OK, 0);
    expect_mut("jit overlap while both live", CODE,
               CODE "\n" JIT("j1", "0x1000", "0x2000", "\"10\"", "\"30\"") "\n" JIT("j2", "0x1800", "0x2800", "\"20\"", "\"40\""),
               XLF_E_ADDRESS, 0);
    expect_add("jit overlap with unknown lifetime", CODE,
               CODE "\n" JIT("j1", "0x1000", "0x2000", "null", "null") "\n" JIT("j2", "0x1800", "0x2800", "\"20\"", "null"),
               2, XLF_OK, XLF_W_ADDRESS_REUSE);
    expect_mut("jit load inside live code with open end", CODE,
               CODE "\n" JIT("j1", "0x1000", "0x2000", "\"10\"", "\"50\"") "\n" JIT("j2", "0x1800", "0x2800", "\"20\"", "null"),
               XLF_E_ADDRESS, 0);
    expect_mut("jit empty range", CODE, CODE "\n" JIT("j1", "0x1000", "0x1000", "null", "null"), XLF_E_ADDRESS, 0);

    /* Weights and counts. */
    expect_mut("zero weight", "\"weight\":\"1\"", "\"weight\":\"0\"", XLF_E_SCHEMA, 0);
    expect_mut("max weight", "\"weight\":\"1\"", "\"weight\":\"18446744073709551615\"", XLF_OK, 0);
    expect_mut("weight overflow", "\"weight\":\"1\"", "\"weight\":\"18446744073709551616\"", XLF_E_SCHEMA, 0);
    expect_mut("negative weight", "\"weight\":\"1\"", "\"weight\":\"-1\"", XLF_E_SCHEMA, 0);
    expect_mut("end count mismatch", END(7), END(6), XLF_E_COUNT, 0);
    expect_mut("more stacks than declared", "\"stacks\":1}\n{\"type\":\"stack\"", "\"stacks\":0}\n{\"type\":\"stack\"", XLF_E_COUNT, 0);
    expect_mut("fewer stacks than declared", "\"stacks\":1}\n{\"type\":\"stack\"", "\"stacks\":2}\n{\"type\":\"stack\"", XLF_E_COUNT, 0);

    /* Order and versions. */
    expect_mut("record before header", HEADER "\n" CODE, CODE "\n" HEADER, XLF_E_ORDER, 0);
    expect("record after end", VALID THREAD "\n", XLF_E_ORDER, 0);
    expect_mut("duplicate header", CODE, HEADER "\n" CODE, XLF_E_ORDER, 0);
    expect_mut("version 2", "\"version\":1,\"draft\"", "\"version\":2,\"draft\"", XLF_E_VERSION, 0);
    expect_mut("other draft", "\"draft\":\"C05-1\"", "\"draft\":\"C05-0\"", XLF_E_VERSION, 0);
    expect_mut("simpleperf relabel", "\"format\":\"xodb.logical-frames\"", "\"format\":\"xodb.simpleperf\"", XLF_E_VERSION, 0);
    expect_mut("unknown source kind", "\"cooperative_sample\"", "\"perf_sample\"", XLF_E_SCHEMA, 0);
    expect_mut("frame order outermost", "\"innermost_first\"", "\"outermost_first\"", XLF_E_SCHEMA, 0);
    expect_mut("unknown record type", CODE, "{\"type\":\"merge\",\"native\":\"s1\"}", XLF_E_SCHEMA, 0);

    /* JSON and UTF-8. */
    expect_mut("unknown member", "\"bytes\":10}", "\"bytes\":10,\"extra\":1}", XLF_E_SCHEMA, 0);
    expect_mut("extension member", "\"bytes\":10}", "\"bytes\":10,\"x_note\":[1,{\"a\":null}]}", XLF_OK, 0);
    expect_mut("float", "\"first_line\":1,", "\"first_line\":1.5,", XLF_E_SCHEMA, 0);
    expect_mut("exponent", "\"first_line\":1,", "\"first_line\":1e3,", XLF_E_SCHEMA, 0);
    expect_mut("duplicate key", "\"name\":\"fib\"", "\"name\":\"fib\",\"name\":\"fob\"", XLF_E_JSON, 0);
    expect_mut("trailing garbage", END(7), END(7) " x", XLF_E_JSON, 0);
    expect_mut("unterminated string", "\"name\":\"fib\"", "\"name\":\"fib", XLF_E_JSON, 0);
    expect_mut("raw control char", "\"name\":\"fib\"", "\"name\":\"f\tb\"", XLF_E_JSON, 0);
    expect_mut("invalid byte", "\"name\":\"fib\"", "\"name\":\"f\xff\"", XLF_E_UTF8, 0);
    expect_mut("overlong encoding", "\"name\":\"fib\"", "\"name\":\"f\xc0\x80\"", XLF_E_UTF8, 0);
    expect_mut("encoded surrogate", "\"name\":\"fib\"", "\"name\":\"f\xed\xa0\x80\"", XLF_E_UTF8, 0);
    expect_mut("above U+10FFFF", "\"name\":\"fib\"", "\"name\":\"f\xf4\x90\x80\x80\"", XLF_E_UTF8, 0);
    expect_mut("truncated sequence", "\"name\":\"fib\"", "\"name\":\"f\xe2\x82\"", XLF_E_UTF8, 0);
    expect_mut("escaped lone surrogate", "\"name\":\"fib\"", "\"name\":\"f\\ud800\"", XLF_E_UTF8, 0);
    expect_mut("escaped NUL", "\"name\":\"fib\"", "\"name\":\"f\\u0000\"", XLF_E_UTF8, 0);
    {
        char *s = mutate(VALID, "\"name\":\"fib\"", "\"name\":\"f\\ud83d\\ude00\xe2\x82\xac\"");
        d = run("valid surrogate pair and UTF-8", s, strlen(s), NULL, XLF_OK, 0);
        if (d) {
            check(!strcmp(d->functions[0].name.ptr, "f\xf0\x9f\x98\x80\xe2\x82\xac"), "escaped pair decoded to UTF-8");
            xlf_free(d);
        }
        free(s);
    }
    expect_mut("deep nesting", "\"bytes\":10}", "\"bytes\":10,\"x_deep\":[[[[[[[[[[[[1]]]]]]]]]]]}", XLF_E_LIMIT, 0);
    expect_mut("non-object record", CODE, "[1,2]", XLF_E_SCHEMA, 0);
    {
        char *s = strdup(VALID);
        *strstr(s, "\"fib\"") = 0; /* raw NUL inside a record */
        xlf_free(run("NUL byte in record", s, strlen(VALID), NULL, XLF_E_JSON, 0));
        free(s);
    }

    /* Budgets. */
    struct xlf_limits l;
    xlf_default_limits(&l);
    l.max_input_bytes = strlen(VALID) - 1;
    xlf_free(run("input byte budget", VALID, strlen(VALID), &l, XLF_E_LIMIT, 0));
    xlf_default_limits(&l);
    l.max_records = 6;
    xlf_free(run("record budget", VALID, strlen(VALID), &l, XLF_E_LIMIT, 0));
    xlf_default_limits(&l);
    l.max_frames_per_stack = 3;
    xlf_free(run("frames per stack budget", VALID, strlen(VALID), &l, XLF_E_LIMIT, 0));
    xlf_default_limits(&l);
    l.max_total_frames = 2;
    xlf_free(run("total frame budget", VALID, strlen(VALID), &l, XLF_E_LIMIT, 0));
    xlf_default_limits(&l);
    l.max_string_bytes = 8;
    xlf_free(run("string budget", VALID, strlen(VALID), &l, XLF_E_LIMIT, 0));
    xlf_default_limits(&l);
    l.max_memory = 4096;
    xlf_free(run("memory budget", VALID, strlen(VALID), &l, XLF_E_MEMORY, 0));
    xlf_default_limits(&l);
    l.max_line_bytes = 200;
    xlf_free(run("record size budget", VALID, strlen(VALID), &l, XLF_E_LIMIT, 0));
    xlf_default_limits(&l);
    l.max_entities = 1;
    xlf_free(run("entity budget", VALID, strlen(VALID), &l, XLF_E_LIMIT, 0));
    xlf_default_limits(&l);
    l.max_stacks = (size_t)UINT32_MAX;
    xlf_free(run("invalid limits: stacks above 32-bit index", VALID, strlen(VALID), &l, XLF_E_LIMIT, 0));
    xlf_default_limits(&l);
    l.max_memory = 0;
    xlf_free(run("invalid limits: zero memory", VALID, strlen(VALID), &l, XLF_E_LIMIT, 0));

    /* Many stacks: bounded growth and recursion depth. */
    {
        size_t n = 2000, cap = strlen(BASE) + n * 400 + 256;
        char *s = malloc(cap);
        size_t at = (size_t)snprintf(s, cap, "%s", HEADER "\n" CODE "\n" FIB "\n" MAIN "\n" THREAD "\n");
        for (size_t i = 0; i < n; ++i) {
            at += (size_t)snprintf(s + at, cap - at,
                                   "{\"type\":\"acquisition\",\"seq\":%zu,\"start_ns\":null,\"end_ns\":null,\"stacks\":1}\n"
                                   "{\"type\":\"stack\",\"id\":\"s%zu\",\"acquisition\":%zu,\"thread\":\"t1\",\"start_ns\":null,"
                                   "\"end_ns\":null,\"trigger\":\"t\",\"weight\":\"2\",\"state\":\"complete\",\"omitted\":null,"
                                   "\"reason\":null,\"frames\":[" FR("f1", 2) "," FR("f2", 5) "]}\n",
                                   i + 1, i + 1, i + 1);
        }
        at += (size_t)snprintf(s + at, cap - at,
                               "{\"type\":\"end\",\"records\":%zu,\"acquisitions\":%zu,\"stacks\":%zu,\"status\":\"complete\"}\n",
                               5 + 2 * n, n, n);
        d = run("2000 stacks", s, at, NULL, XLF_OK, 0);
        if (d) {
            struct xlf_aggregate a;
            AGG(d, 0, &a);
            check(eq(a.total_weight, 2 * n) && eq(a.self[0], 2 * n) && eq(a.inclusive[1], 2 * n), "aggregate weights over 2000 stacks");
            xlf_aggregate_free(&a);
            xlf_free(d);
        }
        free(s);
    }
    printf("%d cases, %d failures\n", cases, failures);
    return failures != 0;
}
