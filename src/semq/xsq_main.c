/* xsq: command-line harness for bounded static semantic queries. */
#define _GNU_SOURCE 1
#include "xsq.h"
#include "xsq_report.h"

#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static struct xsq_cancel cancel; /* lock-free atomic: safe to set from a signal handler */

static void on_signal(int sig)
{
    (void)sig;
    xsq_cancel_request(&cancel);
}

static void usage(void)
{
    fputs("usage:\n"
          "  xsq validate FILE\n"
          "  xsq info FILE\n"
          "  xsq ops FILE [--function NAME]\n"
          "  xsq slice FILE (--op ID | --origin TEXT) [--in N | --out] [--data-only] [--check VN]...\n"
          "  xsq slice FILE --vn ID [--check VN]...\n"
          "  xsq controls FILE (--op ID | --origin TEXT)\n"
          "  xsq bench FILE [--repeat N] [--sample N]\n"
          "options: --json PATH|-  --lines N  --rows N  --max-nodes N  --max-edges N\n"
          "         --max-work N  --max-bytes N  --max-ms N  --cancel\n"
          "--max-bytes is the operation total: graph-load bytes plus query bytes\n"
          "(cumulative allocator requests) never exceed it.  bench runs each sampled\n"
          "query as its own operation on the one loaded graph: load + that query.\n"
          "exit: 0 ok, 3 partial, 4 cancelled, 5 unsupported, 6 not found, 2 usage,\n"
          "      7 malformed, 8 limit, 9 io/memory\n",
          stderr);
}

static int exit_code(enum xsq_status s)
{
    switch (s) {
    case XSQ_OK: return 0;
    case XSQ_PARTIAL: return 3;
    case XSQ_CANCELLED: return 4;
    case XSQ_UNSUPPORTED: return 5;
    case XSQ_NOT_FOUND: return 6;
    case XSQ_INVALID_ARGUMENT: return 2;
    case XSQ_MALFORMED: return 7;
    case XSQ_LIMIT: return 8;
    case XSQ_NO_MEMORY:
    case XSQ_IO: return 9;
    }
    return 9;
}

static int number(const char *text, uint64_t *value)
{
    if (!text || !*text || *text == '-')
        return 0;
    char *end;
    errno = 0;
    unsigned long long v = strtoull(text, &end, 0);
    if (errno || *end)
        return 0;
    *value = v;
    return 1;
}

static int load(const char *path, struct xsq_graph *g, size_t max_bytes)
{
    struct xsq_load_budget lb = {.max_bytes = max_bytes, .cancel = &cancel};
    enum xsq_status s = xsq_load_file_budget(path, &lb, g);
    if (s) {
        fprintf(stderr, "xsq: %s: %s: line %" PRIu32 ": %s\n", path, xsq_status_name(s),
                g->error_line, g->error);
        return exit_code(s);
    }
    return 0;
}

static void info(const struct xsq_graph *g)
{
    printf("xsg sha256 %s\nimage sha256=%s build_id=%s name=%s\n", g->input_sha256,
           xsq_string(g, g->image_sha256), xsq_string(g, g->image_build_id),
           xsq_string(g, g->image_name));
    printf("spec language=%s compiler=%s addr_bytes=%u\nproducer %s %s\nsource kind=%s sha256=%s\n",
           xsq_string(g, g->language), xsq_string(g, g->compiler), g->addr_bytes,
           xsq_string(g, g->producer), xsq_string(g, g->producer_version),
           xsq_string(g, g->source_kind), xsq_string(g, g->source_sha256));
    for (uint32_t f = 0; f < g->func_count; ++f) {
        const struct xsq_func *fn = &g->funcs[f];
        printf("function %" PRIu32 " %s entry=0x%" PRIx64 " blocks=%" PRIu32 " ops=%" PRIu32
               " varnodes=%" PRIu32 "%s\n",
               fn->id, xsq_string(g, fn->name), fn->entry, fn->block_count, fn->op_count,
               fn->vn_count, fn->cfg_incomplete ? " cfg_incomplete" : "");
    }
}

static void ops(const struct xsq_graph *g, const char *function)
{
    for (uint32_t i = 0; i < g->op_count; ++i) {
        const struct xsq_op *op = &g->ops[i];
        if (function && strcmp(function, xsq_string(g, g->funcs[op->func].name)))
            continue;
        printf("op %" PRIu32 " %s block %" PRIu32 " @0x%" PRIx64 " %s", op->id,
               xsq_string(g, g->funcs[op->func].name), g->blocks[op->block].id, op->address,
               xsq_opcode_name(g, op));
        if (op->out != XSQ_NONE)
            printf(" out=v%" PRIu32 "(%u)", g->vns[op->out].id, g->vns[op->out].size);
        for (uint32_t k = 0; k < op->in_count; ++k) {
            uint32_t v = g->inputs[op->in_first + k];
            if (v == XSQ_NONE)
                printf(" in%u=@%" PRIu32, k, g->ops[op->iop].id);
            else
                printf(" in%u=v%" PRIu32 "(%s)", k, g->vns[v].id, xsq_vn_role(g, v));
        }
        if (op->origin)
            printf(" origin=%s", xsq_string(g, op->origin));
        for (uint32_t c = 0; c < g->call_count; ++c)
            if (g->calls[c].op == i)
                printf(" call=%s", g->calls[c].name ? xsq_string(g, g->calls[c].name)
                                                    : "(unnamed)");
        putchar('\n');
    }
}

static uint64_t now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}

/* Sampled slices (op outputs) and control queries, plus one slice and one
 * control query at the last op (typically the final RETURN). */
static int bench(const struct xsq_graph *g, const struct xsq_budget *b, uint64_t repeat,
                 uint64_t sample, uint64_t load_ns)
{
    uint64_t start = now_ns(), slices = 0, controls = 0, not_ok = 0, work = 0, nodes = 0;
    uint64_t max_slice_ns = 0, max_control_ns = 0, slice_ns = 0, control_ns = 0;
    uint64_t slice_status[XSQ_IO + 1] = {0}, control_status[XSQ_IO + 1] = {0};
    uint64_t step = g->op_count > sample ? g->op_count / sample : 1;
    for (uint64_t k = 0; k < repeat; ++k)
        for (uint64_t i = 0; i < g->op_count; i += step) {
            struct xsq_result r;
            const struct xsq_op *op = &g->ops[i];
            if (op->out != XSQ_NONE) {
                struct xsq_selector sel = {.op_id = op->id, .vn_id = XSQ_NONE, .input = -1};
                xsq_slice(g, sel, b, &r);
                slices++;
                work += r.work;
                nodes += r.node_count;
                not_ok += r.status != XSQ_OK;
                slice_status[r.status]++;
                slice_ns += r.ns;
                if (r.ns > max_slice_ns)
                    max_slice_ns = r.ns;
                xsq_result_free(&r);
            }
            xsq_controls(g, op->id, b, &r);
            controls++;
            work += r.work;
            not_ok += r.status != XSQ_OK;
            control_status[r.status]++;
            control_ns += r.ns;
            if (r.ns > max_control_ns)
                max_control_ns = r.ns;
            xsq_result_free(&r);
        }
    struct xsq_result last;
    const struct xsq_op *op = &g->ops[g->op_count - 1];
    struct xsq_selector sel = {.op_id = op->id, .vn_id = XSQ_NONE,
                               .input = op->in_count > 1 ? 1 : (op->out != XSQ_NONE ? -1 : 0)};
    xsq_slice(g, sel, b, &last);
    printf("{\"ops\":%" PRIu32 ",\"blocks\":%" PRIu32 ",\"varnodes\":%" PRIu32
           ",\"load_bytes\":%zu,\"query_max_bytes\":%zu"
           ",\"budget_rule\":\"each query: load_bytes + query bytes <= --max-bytes\""
           ",\"load_ns\":%" PRIu64 ",\"last_slice\":{\"status\":\"%s\",\"limit\":\"%s\","
           "\"nodes\":%" PRIu32 ",\"work\":%" PRIu64 ",\"bytes\":%" PRIu64 ",\"ns\":%" PRIu64
           ",\"boundaries\":%" PRIu32 ",\"exclusions\":%" PRIu32 "}",
           g->op_count, g->block_count, g->vn_count, g->load_bytes, b->max_bytes, load_ns,
           xsq_status_name(last.status),
           xsq_limit_name(last.limit), last.node_count, last.work, last.bytes, last.ns,
           last.boundary_count, last.exclusion_count);
    xsq_result_free(&last);
    xsq_controls(g, op->id, b, &last);
    printf(",\"last_controls\":{\"status\":\"%s\",\"controls\":%" PRIu32 ",\"work\":%" PRIu64
           ",\"ns\":%" PRIu64 "}",
           xsq_status_name(last.status), last.control_count, last.work, last.ns);
    xsq_result_free(&last);
    for (int pass = 0; pass < 2; ++pass) {
        const uint64_t *h = pass ? control_status : slice_status;
        printf(",\"%s_status\":{", pass ? "controls" : "slice");
        for (int k = 0, first = 1; k <= XSQ_IO; ++k)
            if (h[k]) {
                printf("%s\"%s\":%" PRIu64, first ? "" : ",", xsq_status_name((enum xsq_status)k), h[k]);
                first = 0;
            }
        putchar('}');
    }
    printf(",\"sampled_slices\":%" PRIu64 ",\"sampled_controls\":%" PRIu64
           ",\"not_ok\":%" PRIu64 ",\"work\":%" PRIu64 ",\"nodes\":%" PRIu64
           ",\"mean_slice_ns\":%" PRIu64 ",\"max_slice_ns\":%" PRIu64
           ",\"mean_controls_ns\":%" PRIu64 ",\"max_controls_ns\":%" PRIu64
           ",\"total_ns\":%" PRIu64 "}\n",
           slices, controls, not_ok, work, nodes, slices ? slice_ns / slices : 0, max_slice_ns,
           controls ? control_ns / controls : 0, max_control_ns, now_ns() - start);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        usage();
        return 2;
    }
    const char *command = argv[1], *path = argv[2];
    struct xsq_budget budget;
    memset(&budget, 0, sizeof budget);
    xsq_cancel_init(&cancel);
    uint64_t op_id = XSQ_NONE, vn_id = XSQ_NONE, lines = 40, rows = 200, repeat = 1, value;
    uint64_t sample = 64;
    int input = -1, have_selector = 0;
    unsigned slice_flags = 0;
    const char *json = NULL, *origin = NULL, *function = NULL;
    uint64_t checks[64];
    unsigned check_count = 0;
    for (int i = 3; i < argc; ++i) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
        int takes = 1;
        if (!strcmp(a, "--op") && number(v, &op_id) && op_id < XSQ_NONE)
            have_selector = 1;
        else if (!strcmp(a, "--origin") && v)
            origin = v, have_selector = 1;
        else if (!strcmp(a, "--vn") && number(v, &vn_id) && vn_id < XSQ_NONE)
            have_selector = 1;
        else if (!strcmp(a, "--in") && number(v, &value) && value < XSQ_MAX_OP_INPUTS)
            input = (int)value;
        else if (!strcmp(a, "--out"))
            input = -1, takes = 0;
        else if (!strcmp(a, "--data-only"))
            slice_flags |= XSQ_SLICE_DATA_ONLY, takes = 0;
        else if (!strcmp(a, "--json") && v)
            json = v;
        else if (!strcmp(a, "--function") && v)
            function = v;
        else if (!strcmp(a, "--lines") && number(v, &lines))
            ;
        else if (!strcmp(a, "--rows") && number(v, &rows))
            ;
        else if (!strcmp(a, "--repeat") && number(v, &repeat) && repeat && repeat <= 1000)
            ;
        else if (!strcmp(a, "--sample") && number(v, &sample) && sample)
            ;
        else if (!strcmp(a, "--check") && number(v, &value) && check_count < 64)
            checks[check_count++] = value;
        else if (!strcmp(a, "--max-nodes") && number(v, &value) && value && value < XSQ_NONE)
            budget.max_nodes = (uint32_t)value;
        else if (!strcmp(a, "--max-edges") && number(v, &value) && value && value < XSQ_NONE)
            budget.max_edges = (uint32_t)value;
        else if (!strcmp(a, "--max-work") && number(v, &value) && value)
            budget.max_work = value;
        else if (!strcmp(a, "--max-bytes") && number(v, &value) && value)
            budget.max_bytes = (size_t)value;
        else if (!strcmp(a, "--max-ms") && number(v, &value) && value)
            budget.max_ns = value * 1000000u;
        else if (!strcmp(a, "--cancel"))
            xsq_cancel_request(&cancel), takes = 0; /* pre-set cancellation, for tests */
        else {
            fprintf(stderr, "xsq: bad option %s\n", a);
            usage();
            return 2;
        }
        i += takes;
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    budget.cancel = &cancel;
    struct xsq_graph g;
    uint64_t load_start = now_ns();
    int rc = load(path, &g, budget.max_bytes);
    uint64_t load_ns = now_ns() - load_start;
    if (rc)
        return rc;
    if (!strcmp(command, "validate")) {
        printf("ok %s functions=%" PRIu32 " blocks=%" PRIu32 " ops=%" PRIu32 " varnodes=%" PRIu32
               "\n",
               g.input_sha256, g.func_count, g.block_count, g.op_count, g.vn_count);
        goto out;
    }
    if (!strcmp(command, "info")) {
        info(&g);
        goto out;
    }
    if (!strcmp(command, "ops")) {
        ops(&g, function);
        goto out;
    }
    struct xsq_budget effective;
    xsq_budget_default(&effective);
    if (budget.max_nodes)
        effective.max_nodes = budget.max_nodes;
    if (budget.max_edges)
        effective.max_edges = budget.max_edges;
    if (budget.max_work)
        effective.max_work = budget.max_work;
    if (budget.max_bytes) /* operation total: the query gets what loading left */
        effective.max_bytes = budget.max_bytes > g.load_bytes ? budget.max_bytes - g.load_bytes : 1;
    effective.max_ns = budget.max_ns;
    effective.cancel = budget.cancel;
    if (!strcmp(command, "bench")) {
        rc = bench(&g, &effective, repeat, sample, load_ns);
        goto out;
    }
    int is_slice = !strcmp(command, "slice");
    if ((!is_slice && strcmp(command, "controls")) || !have_selector) {
        usage();
        rc = 2;
        goto out;
    }
    if (origin) {
        uint32_t o = xsq_find_op_origin(&g, origin);
        if (o == XSQ_NONE) {
            fprintf(stderr, "xsq: no op with origin %s\n", origin);
            rc = 6;
            goto out;
        }
        op_id = g.ops[o].id;
    }
    struct xsq_result r;
    enum xsq_status s;
    if (is_slice) {
        struct xsq_selector sel = {.op_id = (uint32_t)op_id, .vn_id = (uint32_t)vn_id,
                                   .input = input, .flags = slice_flags};
        s = xsq_slice(&g, sel, &effective, &r);
    } else {
        s = xsq_controls(&g, (uint32_t)op_id, &effective, &r);
    }
    /* With --json -, stdout carries only JSON; the text explanation goes to stderr. */
    FILE *text = json && !strcmp(json, "-") ? stderr : stdout;
    if (is_slice)
        xsq_report_slice_text(text, &g, &r, (uint32_t)(lines > 100000 ? 100000 : lines));
    else
        xsq_report_controls_text(text, &g, &r, (uint32_t)(lines > 100000 ? 100000 : lines));
    for (unsigned i = 0; i < check_count && is_slice; ++i) {
        uint32_t v = checks[i] < XSQ_NONE ? xsq_find_vn(&g, (uint32_t)checks[i]) : XSQ_NONE;
        if (v == XSQ_NONE) {
            fprintf(text, "  check v%" PRIu64 ": not_found\n", checks[i]);
            continue;
        }
        uint32_t node;
        enum xsq_relevance rel = xsq_relevance(&r, v, &node);
        if (r.func != XSQ_NONE && g.vns[v].func != r.func)
            rel = XSQ_REL_UNKNOWN; /* other function: interprocedural, not analysed */
        fprintf(text, "  check v%" PRIu64 ": %s\n", checks[i], xsq_relevance_name(rel));
    }
    if (json) {
        FILE *out = strcmp(json, "-") ? fopen(json, "w") : stdout;
        if (!out) {
            fprintf(stderr, "xsq: cannot write %s: %s\n", json, strerror(errno));
            rc = 9;
        } else {
            uint32_t max_rows = (uint32_t)(rows > 1000000 ? 1000000 : rows);
            if (is_slice)
                xsq_report_slice_json(out, &g, &r, &effective, max_rows);
            else
                xsq_report_controls_json(out, &g, &r, &effective, max_rows);
            if (out != stdout && fclose(out))
                rc = 9;
        }
    }
    xsq_result_free(&r);
    if (!rc)
        rc = exit_code(s);
out:
    xsq_free(&g);
    return rc;
}
