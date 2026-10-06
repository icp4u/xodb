/* Text and JSON rendering of query results. Rendering is bounded and never
 * changes a result: counts are always complete even when rows are truncated. */
#include "xsq_report.h"
#include "xsq_internal.h"

#include <inttypes.h>
#include <stdlib.h>
#include <string.h>

const char *xsq_step_name(unsigned step)
{
    static const char *const names[] = {"root", "operand", "phi", "indirect_input",
                                        "load_address", "store_same_location",
                                        "store_may_alias", "store_address",
                                        "indirect_store", "call_input_unknown_callee",
                                        "barrier_input", "control", "gating"};
    return step < sizeof names / sizeof *names ? names[step] : "invalid";
}

const char *xsq_boundary_name(unsigned kind)
{
    static const char *const names[] = {"call_result", "call_may_write", "indirect_call",
                                        "indirect_other", "memory_at_entry", "unknown_operation",
                                        "immutable_load", "unknown_op_may_write"};
    return kind < sizeof names / sizeof *names ? names[kind] : "invalid";
}

const char *xsq_exclusion_name(unsigned reason)
{
    static const char *const names[] = {"disjoint_stack_slots", "disjoint_global_addresses",
                                        "disjoint_offsets_same_base", "stack_vs_global",
                                        "nonescaping_stack_slot", "killed_by_nearer_store"};
    return reason < sizeof names / sizeof *names ? names[reason] : "invalid";
}

const char *xsq_limit_name(unsigned limit)
{
    static const char *const names[] = {"none", "nodes", "edges", "work", "memory", "time",
                                        "cancelled", "allocation_failed"};
    return limit < sizeof names / sizeof *names ? names[limit] : "invalid";
}

const char *xsq_relevance_name(enum xsq_relevance relevance)
{
    static const char *const names[] = {"direct", "possible", "control", "irrelevant", "unknown"};
    return (unsigned)relevance < 5 ? names[relevance] : "invalid";
}

static void json_string(FILE *out, const char *text)
{
    fputc('"', out);
    for (const unsigned char *p = (const unsigned char *)text; *p; ++p) {
        if (*p == '"' || *p == '\\')
            fprintf(out, "\\%c", *p);
        else if (*p < 0x20 || *p >= 0x7f)
            fprintf(out, "\\u%04x", *p);
        else
            fputc(*p, out);
    }
    fputc('"', out);
}

static void json_opt_string(FILE *out, const struct xsq_graph *g, uint32_t offset)
{
    if (offset)
        json_string(out, xsq_string(g, offset));
    else
        fputs("null", out);
}

const char *xsq_certainty_name(unsigned certainty)
{
    return certainty == XSQ_DIRECT ? "direct" : certainty == XSQ_POSSIBLE ? "possible" : "control";
}

const char *xsq_vn_role(const struct xsq_graph *g, uint32_t v)
{
    const struct xsq_vn *vn = &g->vns[v];
    if (g->spaces[vn->space].cls == XSQ_SPACE_CONSTANT)
        return "constant";
    if (vn->flags & XSQ_VN_PARAM)
        return "parameter";
    if (vn->flags & XSQ_VN_ANNOTATION)
        return "code_address";
    if (vn->flags & XSQ_VN_SPACEBASE)
        return "frame_base";
    if (vn->flags & XSQ_VN_INPUT)
        return "function_input";
    return "intermediate";
}

static void json_vn(FILE *out, const struct xsq_graph *g, uint32_t v)
{
    if (v == XSQ_NONE) {
        fputs("null", out);
        return;
    }
    const struct xsq_vn *vn = &g->vns[v];
    fprintf(out, "{\"id\":%" PRIu32 ",\"space\":", vn->id);
    json_string(out, xsq_string(g, g->spaces[vn->space].name));
    fprintf(out, ",\"offset\":\"0x%" PRIx64 "\",\"size\":%" PRIu32 ",\"role\":\"%s\"", vn->offset,
            vn->size, xsq_vn_role(g, v));
    if (vn->param >= 0)
        fprintf(out, ",\"param\":%" PRId32, vn->param);
    if (vn->name) {
        fputs(",\"name\":", out);
        json_string(out, xsq_string(g, vn->name));
    }
    if (vn->flags & XSQ_VN_SPACEBASE_HEURISTIC)
        fputs(",\"frame_base_inferred_by_adapter\":true", out);
    fputc('}', out);
}

static void json_op(FILE *out, const struct xsq_graph *g, uint32_t o)
{
    if (o == XSQ_NONE) {
        fputs("null", out);
        return;
    }
    const struct xsq_op *op = &g->ops[o];
    fprintf(out, "{\"id\":%" PRIu32 ",\"opcode\":", op->id);
    json_string(out, xsq_opcode_name(g, op));
    fprintf(out, ",\"address\":\"0x%" PRIx64 "\",\"block\":%" PRIu32 ",\"seq\":%" PRIu32
                 ",\"origin\":",
            op->address, g->blocks[op->block].id, op->seq);
    json_opt_string(out, g, op->origin);
    for (uint32_t c = 0; c < g->call_count; ++c)
        if (g->calls[c].op == o) {
            fputs(",\"call_target\":", out);
            if (g->calls[c].known)
                fprintf(out, "\"0x%" PRIx64 "\"", g->calls[c].target);
            else
                fputs("null", out);
            fputs(",\"call_name\":", out);
            json_opt_string(out, g, g->calls[c].name);
        }
    fputc('}', out);
}

/* Width-relevant transformation applied by an op to the value it reads. */
void xsq_transform(const struct xsq_graph *g, uint32_t o, char *text, size_t size)
{
    const struct xsq_op *op = &g->ops[o];
    uint32_t in = op->in_count ? g->vns[g->inputs[op->in_first]].size : 0;
    uint32_t out = op->out != XSQ_NONE ? g->vns[op->out].size : 0;
    switch (op->opcode) {
    case XSQ_OP_INT_ZEXT:
        snprintf(text, size, "zero_extend %u->%u bytes", in, out);
        return;
    case XSQ_OP_INT_SEXT:
        snprintf(text, size, "sign_extend %u->%u bytes", in, out);
        return;
    case XSQ_OP_SUBPIECE:
        snprintf(text, size, "truncate %u->%u bytes at byte offset %" PRIu64, in, out,
                 g->vns[g->inputs[op->in_first + 1]].offset);
        return;
    case XSQ_OP_PIECE:
        snprintf(text, size, "concatenate to %u bytes", out);
        return;
    case XSQ_OP_INT_SLESS:
    case XSQ_OP_INT_SLESSEQUAL:
    case XSQ_OP_INT_SBORROW:
    case XSQ_OP_INT_SCARRY:
    case XSQ_OP_INT_SDIV:
    case XSQ_OP_INT_SREM:
    case XSQ_OP_INT_SRIGHT:
        snprintf(text, size, "signed %u-byte", in);
        return;
    case XSQ_OP_INT_LESS:
    case XSQ_OP_INT_LESSEQUAL:
    case XSQ_OP_INT_CARRY:
    case XSQ_OP_INT_DIV:
    case XSQ_OP_INT_REM:
    case XSQ_OP_INT_RIGHT:
        snprintf(text, size, "unsigned %u-byte", in);
        return;
    default:
        snprintf(text, size, "%u bytes", out ? out : in);
        return;
    }
}

static void json_path(FILE *out, const struct xsq_graph *g, const struct xsq_result *r,
                      uint32_t node)
{
    uint32_t chain[XSQ_REPORT_MAX_PATH];
    uint32_t n = 0;
    int truncated = 0;
    for (uint32_t i = node; i != XSQ_NONE; i = r->nodes[i].parent) {
        if (n == XSQ_REPORT_MAX_PATH) {
            truncated = 1;
            break;
        }
        chain[n++] = i;
    }
    fputs("{\"to\":", out);
    json_vn(out, g, r->nodes[node].vn);
    fprintf(out, ",\"certainty\":\"%s\",\"truncated\":%s,\"steps\":[",
            xsq_certainty_name(r->nodes[node].certainty),
            truncated ? "true" : "false");
    /* Root first: the query value, then each op read backwards. */
    for (uint32_t k = n; k-- > 0;) {
        const struct xsq_node *x = &r->nodes[chain[k]];
        if (k != n - 1)
            fputc(',', out);
        fputs("{\"vn\":", out);
        json_vn(out, g, x->vn);
        if (x->via_op != XSQ_NONE) {
            char transform[96];
            xsq_transform(g, x->via_op, transform, sizeof transform);
            fprintf(out, ",\"read_by\":");
            json_op(out, g, x->via_op);
            fprintf(out, ",\"input\":%u,\"step\":\"%s\",\"transform\":", x->via_input,
                    xsq_step_name(x->step));
            json_string(out, transform);
        }
        fputc('}', out);
    }
    fputs("]}", out);
}

static int terminal(const struct xsq_graph *g, uint32_t v)
{
    return g->vns[v].def == XSQ_NONE;
}

static void json_identity(FILE *out, const struct xsq_graph *g)
{
    fprintf(out, "\"input\":{\"xsg_sha256\":\"%s\",\"image\":{\"sha256\":", g->input_sha256);
    json_opt_string(out, g, g->image_sha256);
    fputs(",\"build_id\":", out);
    json_opt_string(out, g, g->image_build_id);
    fputs(",\"name\":", out);
    json_opt_string(out, g, g->image_name);
    fputs("},\"spec\":{\"language\":", out);
    json_opt_string(out, g, g->language);
    fputs(",\"compiler\":", out);
    json_opt_string(out, g, g->compiler);
    fprintf(out, ",\"addr_bytes\":%u},\"producer\":{\"name\":", g->addr_bytes);
    json_opt_string(out, g, g->producer);
    fputs(",\"version\":", out);
    json_opt_string(out, g, g->producer_version);
    fputs("},\"source\":{\"kind\":", out);
    json_opt_string(out, g, g->source_kind);
    fputs(",\"sha256\":", out);
    json_opt_string(out, g, g->source_sha256);
    fputs("}},", out);
    /* Producer qualification is copied, never upgraded: xsq computes static
     * possibilities over the graph it was given; it does not verify that the
     * graph is a correct decompilation. */
    const char *level = g->qual_level ? xsq_string(g, g->qual_level) : "unknown";
    fputs("\"input_qualification\":{\"level\":", out);
    json_string(out, level);
    fputs(",\"reasons\":", out);
    json_opt_string(out, g, g->qual_reasons);
    fputs(",\"artifact_id\":", out);
    json_opt_string(out, g, g->artifact_id);
    fprintf(out, "},\"result_trust\":\"graph_%s\",\"verified_semantics\":false", level);
}

static void json_common(FILE *out, const struct xsq_graph *g, const struct xsq_result *r,
                        const char *kind, const struct xsq_budget *b)
{
    fprintf(out, "{\"format\":\"xsq-result\",\"version\":1,\"analysis\":\"%s\",",
            XSQ_ANALYSIS_VERSION);
    fputs("\"static_analysis\":true,\"note\":\"static possibilities; not an observed execution\",",
          out);
    json_identity(out, g);
    fprintf(out, ",\"query\":{\"kind\":\"%s\",\"function\":", kind);
    if (r->func != XSQ_NONE) {
        json_string(out, xsq_string(g, g->funcs[r->func].name));
        fprintf(out, ",\"function_entry\":\"0x%" PRIx64 "\"", g->funcs[r->func].entry);
    } else {
        fputs("null", out);
    }
    fputs(",\"op\":", out);
    json_op(out, g, r->root_op);
    if (r->root_input >= 0)
        fprintf(out, ",\"operand\":\"input%d\"", r->root_input);
    else
        fprintf(out, ",\"operand\":\"%s\"", r->root_input == -1 ? "output" : "varnode");
    fputs(",\"value\":", out);
    json_vn(out, g, r->root_vn);
    fprintf(out,
            "},\"budget\":{\"max_nodes\":%" PRIu32 ",\"max_edges\":%" PRIu32
            ",\"max_work\":%" PRIu64 ",\"max_bytes\":%zu,\"max_ns\":%" PRIu64
            ",\"semantics\":\"per phase; bytes are cumulative allocator requests\""
            ",\"load_phase\":{\"bytes\":%zu,\"max_bytes\":%zu}},",
            b->max_nodes, b->max_edges, b->max_work, b->max_bytes, b->max_ns,
            g->load_bytes, g->load_max_bytes);
    fprintf(out, "\"status\":\"%s\",\"limit\":\"%s\",\"partial_reasons\":[",
            xsq_status_name(r->status), xsq_limit_name(r->limit));
    static const char *const reasons[] = {"budget", "nonterminating_component",
                                          "cfg_incomplete_indirect_branch", "path_truncated"};
    int first = 1;
    for (unsigned i = 0; i < 4; ++i)
        if (r->partial_reasons & (1u << i)) {
            fprintf(out, "%s\"%s\"", first ? "" : ",", reasons[i]);
            first = 0;
        }
    fputs("],\"message\":", out);
    json_string(out, r->message);
    fprintf(out,
            ",\"stats\":{\"nodes\":%" PRIu32 ",\"edges\":%" PRIu64 ",\"work\":%" PRIu64
            ",\"bytes\":%" PRIu64 ",\"elapsed_ns\":%" PRIu64 "}",
            r->node_count, r->edges, r->work, r->bytes, r->ns);
}

static void json_frontier(FILE *out, const struct xsq_graph *g, const struct xsq_result *r,
                          int blocks)
{
    fprintf(out, ",\"frontier\":{\"count\":%" PRIu32 ",\"complete\":%s,\"items\":[",
            r->frontier_count, r->frontier_complete ? "true" : "false");
    for (uint32_t i = 0; i < r->frontier_count; ++i) {
        if (i)
            fputc(',', out);
        if (blocks)
            fprintf(out, "{\"block\":%" PRIu32 "}", g->blocks[r->frontier[i]].id);
        else
            json_vn(out, g, r->frontier[i]);
    }
    fputs("]}", out);
}

struct cite { uint64_t address; unsigned certainty; };

static int cmp_cite(const void *a, const void *b)
{
    const struct cite *x = a, *y = b;
    if (x->address != y->address)
        return x->address < y->address ? -1 : 1;
    return (x->certainty > y->certainty) - (x->certainty < y->certainty);
}

void xsq_report_slice_json(FILE *out, const struct xsq_graph *g, const struct xsq_result *r,
                           const struct xsq_budget *b, uint32_t max_rows)
{
    json_common(out, g, r, "slice", b);
    fprintf(out, ",\"exhaustive\":%s,\"memory_complete\":%s,\"relevance_scope\":\"%s\"",
            r->exhaustive ? "true" : "false", r->memory_complete ? "true" : "false",
            r->control_included ? "data+control" : "data");
    /* Summary counts over all nodes; rows below may be truncated by max_rows. */
    uint32_t counts[3][6] = {{0}};
    for (uint32_t i = 0; i < r->node_count; ++i) {
        uint32_t v = r->nodes[i].vn;
        const char *role = xsq_vn_role(g, v);
        unsigned k = !strcmp(role, "parameter")        ? 0
                     : !strcmp(role, "constant")       ? 1
                     : !strcmp(role, "function_input") ? 2
                     : !strcmp(role, "frame_base")     ? 3
                     : !strcmp(role, "code_address")   ? 5
                                                       : 4;
        counts[r->nodes[i].certainty][k]++;
    }
    static const char *const kinds[] = {"parameters", "constants", "function_inputs",
                                        "frame_base", "intermediates", "code_addresses"};
    fputs(",\"summary\":{", out);
    for (unsigned k = 0; k < 6; ++k)
        fprintf(out,
                "%s\"%s\":{\"direct\":%" PRIu32 ",\"possible\":%" PRIu32 ",\"control\":%" PRIu32
                "}",
                k ? "," : "", kinds[k], counts[0][k], counts[1][k], counts[2][k]);
    fprintf(out, ",\"boundaries\":%" PRIu32 ",\"exclusions\":%" PRIu32 "}", r->boundary_count,
            r->exclusion_count);
    uint32_t rows = r->node_count < max_rows ? r->node_count : max_rows;
    fprintf(out, ",\"contributions\":{\"total\":%" PRIu32 ",\"emitted\":%" PRIu32 ",\"rows\":[",
            r->node_count, rows);
    for (uint32_t i = 0; i < rows; ++i) {
        const struct xsq_node *n = &r->nodes[i];
        fprintf(out, "%s{\"node\":%" PRIu32 ",\"value\":", i ? "," : "", i);
        json_vn(out, g, n->vn);
        fprintf(out, ",\"certainty\":\"%s\",\"step\":\"%s\",\"parent_node\":",
                xsq_certainty_name(n->certainty), xsq_step_name(n->step));
        if (n->parent == XSQ_NONE)
            fputs("null", out);
        else
            fprintf(out, "%" PRIu32, n->parent);
        fputs(",\"read_by\":", out);
        json_op(out, g, n->via_op);
        fputs(",\"defined_by\":", out);
        json_op(out, g, g->vns[n->vn].def);
        fputc('}', out);
    }
    fputs("]}", out);
    /* Instruction citations: defining op addresses of contributing values,
     * with the strongest certainty of any value defined there. */
    fputs(",\"instructions\":[", out);
    struct cite *keys = xsq__malloc(((size_t)r->node_count + 1) * sizeof *keys);
    uint32_t nk = 0, distinct = 0, emitted_rows = 0;
    int keys_ok = keys != NULL;
    if (keys) {
        for (uint32_t i = 0; i < r->node_count; ++i) {
            uint32_t d = g->vns[r->nodes[i].vn].def;
            if (d != XSQ_NONE)
                keys[nk++] = (struct cite){g->ops[d].address, r->nodes[i].certainty};
        }
        qsort(keys, nk, sizeof *keys, cmp_cite); /* direct sorts before possible */
        for (uint32_t i = 0; i < nk; ++i) {
            if (i && keys[i].address == keys[i - 1].address)
                continue;
            distinct++;
            if (emitted_rows >= max_rows)
                continue;
            fprintf(out, "%s{\"address\":\"0x%" PRIx64 "\",\"certainty\":\"%s\"}",
                    emitted_rows++ ? "," : "", keys[i].address,
                    xsq_certainty_name(keys[i].certainty));
        }
        free(keys);
    }
    /* Report-phase scratch is outside the query budget (bounded by the
     * charged node array); its failure is explicit, never an empty list. */
    fprintf(out, "],\"instructions_complete\":%s,\"instructions_total\":%" PRIu32,
            keys_ok || !r->node_count ? "true" : "false", distinct);
    fprintf(out, ",\"boundaries\":[");
    for (uint32_t i = 0; i < r->boundary_count; ++i) {
        const struct xsq_boundary *x = &r->boundaries[i];
        fprintf(out, "%s{\"kind\":\"%s\",\"certainty\":\"%s\",\"op\":", i ? "," : "",
                xsq_boundary_name(x->kind), xsq_certainty_name(x->certainty));
        json_op(out, g, x->op);
        fputs(",\"value\":", out);
        json_vn(out, g, x->vn);
        fputs(",\"cause\":", out);
        json_op(out, g, x->other);
        fputc('}', out);
    }
    fputs("],\"exclusions\":[", out);
    for (uint32_t i = 0; i < r->exclusion_count; ++i) {
        const struct xsq_exclusion *x = &r->exclusions[i];
        fprintf(out, "%s{\"reason\":\"%s\",\"load\":", i ? "," : "", xsq_exclusion_name(x->reason));
        json_op(out, g, x->load_op);
        fputs(",\"excluded\":", out);
        json_op(out, g, x->other_op);
        fputc('}', out);
    }
    fputs("]", out);
    json_frontier(out, g, r, 0);
    /* Evidence paths to every terminal and every boundary-producing value. */
    fputs(",\"paths\":[", out);
    uint32_t emitted = 0, wanted = 0;
    for (uint32_t i = 0; i < r->node_count; ++i) {
        uint32_t v = r->nodes[i].vn;
        int want = terminal(g, v);
        for (uint32_t k = 0; k < r->boundary_count && !want; ++k)
            want = r->boundaries[k].vn == v;
        if (!want)
            continue;
        wanted++;
        if (emitted >= max_rows)
            continue;
        if (emitted++)
            fputc(',', out);
        json_path(out, g, r, i);
    }
    fprintf(out, "],\"paths_total\":%" PRIu32 ",\"paths_emitted\":%" PRIu32 "}\n", wanted,
            emitted);
}

void xsq_report_controls_json(FILE *out, const struct xsq_graph *g, const struct xsq_result *r,
                              const struct xsq_budget *b, uint32_t max_rows)
{
    json_common(out, g, r, "controls", b);
    uint32_t rows = r->control_count < max_rows ? r->control_count : max_rows;
    fprintf(out, ",\"controls\":{\"total\":%" PRIu32 ",\"emitted\":%" PRIu32 ",\"rows\":[",
            r->control_count, rows);
    for (uint32_t i = 0; i < rows; ++i) {
        const struct xsq_control *c = &r->controls[i];
        const struct xsq_edge *e = &g->edges[c->edge];
        fprintf(out, "%s{\"branch\":", i ? "," : "");
        json_op(out, g, c->branch_op);
        fputs(",\"condition\":", out);
        json_vn(out, g, c->condition_vn);
        fputs(",\"condition_defined_by\":", out);
        json_op(out, g, g->vns[c->condition_vn].def);
        fprintf(out,
                ",\"edge\":{\"kind\":\"%s\",\"from_block\":%" PRIu32 ",\"to_block\":%" PRIu32
                "},\"controlled_block\":%" PRIu32 ",\"depth\":%u,\"relation\":\"%s\","
                "\"certainty\":\"%s\",\"nontermination_sensitive\":%s}",
                xsq_edge_kind_name(e->kind), g->blocks[e->from].id, g->blocks[e->to].id,
                g->blocks[c->controlled_block].id, c->depth,
                c->depth == 0 ? "direct" : "transitive",
                c->certainty == XSQ_DIRECT ? "direct" : "possible",
                c->nontermination ? "true" : "false");
    }
    fputs("]}", out);
    json_frontier(out, g, r, 1);
    fputs("}\n", out);
}

/* Producer qualification on the text surface, always printed (not subject
 * to the lines budget): copied, never upgraded or verified. */
static void text_qualification(FILE *out, const struct xsq_graph *g)
{
    const char *level = g->qual_level ? xsq_string(g, g->qual_level) : "unknown";
    fprintf(out, "  input qualification=%s reasons=%s artifact=%s result_trust=graph_%s"
                 " verified_semantics=no\n",
            level, g->qual_reasons ? xsq_string(g, g->qual_reasons) : "-",
            g->artifact_id ? xsq_string(g, g->artifact_id) : "-", level);
}

static void text_vn(FILE *out, const struct xsq_graph *g, uint32_t v)
{
    const struct xsq_vn *vn = &g->vns[v];
    fprintf(out, "v%" PRIu32 "(%s:0x%" PRIx64 ",%" PRIu32 ")", vn->id,
            xsq_string(g, g->spaces[vn->space].name), vn->offset, vn->size);
    if (vn->name)
        fprintf(out, "[%s]", xsq_string(g, vn->name));
    if (vn->param >= 0)
        fprintf(out, "[param %" PRId32 "]", vn->param);
}

/* Lines budget: each printed line decrements; output ends with an explicit
 * "more lines omitted" marker rather than silently stopping. */
struct lines { FILE *out; uint32_t left, omitted; };

static int line(struct lines *l)
{
    if (!l->left) {
        l->omitted++;
        return 0;
    }
    l->left--;
    return 1;
}

void xsq_report_slice_text(FILE *out, const struct xsq_graph *g, const struct xsq_result *r,
                           uint32_t max_lines)
{
    struct lines l = {out, max_lines, 0};
    if (line(&l)) {
        fprintf(out, "slice %s: status=%s limit=%s exhaustive=%s memory_complete=%s nodes=%" PRIu32
                     " work=%" PRIu64 "\n",
                r->func != XSQ_NONE ? xsq_string(g, g->funcs[r->func].name) : "-",
                xsq_status_name(r->status), xsq_limit_name(r->limit),
                r->exhaustive ? "yes" : "no", r->memory_complete ? "yes" : "no", r->node_count,
                r->work);
    }
    text_qualification(out, g);
    if (r->root_vn != XSQ_NONE && line(&l)) {
        fputs("  value ", out);
        text_vn(out, g, r->root_vn);
        if (r->root_op != XSQ_NONE)
            fprintf(out, " at op %" PRIu32 " %s @0x%" PRIx64, g->ops[r->root_op].id,
                    xsq_opcode_name(g, &g->ops[r->root_op]), g->ops[r->root_op].address);
        fputs(" (static possibilities, not an observed execution)\n", out);
    }
    for (uint32_t i = 0; i < r->node_count; ++i) {
        uint32_t v = r->nodes[i].vn;
        if (!terminal(g, v) || !line(&l))
            continue;
        fprintf(out, "  %-8s %-14s ", xsq_certainty_name(r->nodes[i].certainty),
                xsq_vn_role(g, v));
        text_vn(out, g, v);
        fputs("  via", out);
        uint32_t hops = 0;
        for (uint32_t k = i; k != XSQ_NONE && r->nodes[k].via_op != XSQ_NONE && hops < 8;
             k = r->nodes[k].parent, ++hops)
            fprintf(out, " %s@0x%" PRIx64, xsq_opcode_name(g, &g->ops[r->nodes[k].via_op]),
                    g->ops[r->nodes[k].via_op].address);
        if (hops == 8)
            fputs(" ...", out);
        fputc('\n', out);
    }
    for (uint32_t i = 0; i < r->boundary_count; ++i) {
        const struct xsq_boundary *b = &r->boundaries[i];
        if (!line(&l))
            continue;
        fprintf(out, "  boundary %-20s %-8s op %" PRIu32 " %s @0x%" PRIx64, xsq_boundary_name(b->kind),
                xsq_certainty_name(b->certainty), g->ops[b->op].id,
                xsq_opcode_name(g, &g->ops[b->op]), g->ops[b->op].address);
        if (b->other != XSQ_NONE)
            fprintf(out, " cause op %" PRIu32 " %s @0x%" PRIx64, g->ops[b->other].id,
                    xsq_opcode_name(g, &g->ops[b->other]), g->ops[b->other].address);
        fputc('\n', out);
    }
    for (uint32_t i = 0; i < r->exclusion_count; ++i) {
        const struct xsq_exclusion *x = &r->exclusions[i];
        if (!line(&l))
            continue;
        fprintf(out, "  excluded %-26s load op %" PRIu32, xsq_exclusion_name(x->reason),
                g->ops[x->load_op].id);
        if (x->other_op != XSQ_NONE)
            fprintf(out, " vs op %" PRIu32 " %s @0x%" PRIx64, g->ops[x->other_op].id,
                    xsq_opcode_name(g, &g->ops[x->other_op]), g->ops[x->other_op].address);
        fputc('\n', out);
    }
    if ((r->status == XSQ_PARTIAL || r->status == XSQ_CANCELLED) && line(&l))
        fprintf(out, "  frontier: %" PRIu32 " unexpanded values%s (partial result)\n",
                r->frontier_count, r->frontier_complete ? "" : ", list incomplete");
    if (r->message[0] && line(&l))
        fprintf(out, "  note: %s\n", r->message);
    if (l.omitted)
        fprintf(out, "  ... %" PRIu32 " more lines omitted (see JSON evidence)\n", l.omitted);
}

void xsq_report_controls_text(FILE *out, const struct xsq_graph *g, const struct xsq_result *r,
                              uint32_t max_lines)
{
    struct lines l = {out, max_lines, 0};
    if (line(&l))
        fprintf(out, "controls %s: status=%s limit=%s controls=%" PRIu32 " work=%" PRIu64 "\n",
                r->func != XSQ_NONE ? xsq_string(g, g->funcs[r->func].name) : "-",
                xsq_status_name(r->status), xsq_limit_name(r->limit), r->control_count, r->work);
    text_qualification(out, g);
    if (r->root_op != XSQ_NONE && line(&l))
        fprintf(out, "  op %" PRIu32 " %s @0x%" PRIx64 " in block %" PRIu32
                     " (static control dependence, not observed)\n",
                g->ops[r->root_op].id, xsq_opcode_name(g, &g->ops[r->root_op]),
                g->ops[r->root_op].address, g->blocks[g->ops[r->root_op].block].id);
    for (uint32_t i = 0; i < r->control_count; ++i) {
        const struct xsq_control *c = &r->controls[i];
        if (!line(&l))
            continue;
        const struct xsq_op *op = &g->ops[c->branch_op];
        fprintf(out, "  %-10s %-8s %s@0x%" PRIx64 " cond ", c->depth ? "transitive" : "direct",
                c->certainty == XSQ_DIRECT ? "" : "possible", xsq_opcode_name(g, op), op->address);
        text_vn(out, g, c->condition_vn);
        fprintf(out, " edge %s -> block %" PRIu32 " controls block %" PRIu32 "%s\n",
                xsq_edge_kind_name(g->edges[c->edge].kind), g->blocks[g->edges[c->edge].to].id,
                g->blocks[c->controlled_block].id,
                c->nontermination ? " (nontermination-sensitive)" : "");
    }
    if ((r->status == XSQ_PARTIAL || r->status == XSQ_CANCELLED) && line(&l))
        fprintf(out, "  frontier: %" PRIu32 " unexpanded blocks%s (partial result)\n",
                r->frontier_count, r->frontier_complete ? "" : ", list incomplete");
    if (r->partial_reasons & XSQ_PARTIAL_CFG_INCOMPLETE && line(&l))
        fputs("  partial: unresolved indirect branch; CFG incomplete\n", out);
    if (r->partial_reasons & XSQ_PARTIAL_NONTERMINATING && line(&l))
        fputs("  partial: some branch can enter a region with no exit\n", out);
    if (r->message[0] && line(&l))
        fprintf(out, "  note: %s\n", r->message);
    if (l.omitted)
        fprintf(out, "  ... %" PRIu32 " more lines omitted (see JSON evidence)\n", l.omitted);
}
