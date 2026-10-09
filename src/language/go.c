#include "go.h"
#include <stddef.h>
#include <string.h>
/* Observer-only Go runtime reader. Every target read goes through the
 * caller's bounded reader; failures become reasons, never guesses. */
struct mod {
    uint64_t text, minpc, maxpc, ftab, nftab, pcln, pcln_len, names, names_len;
    const char *reason;
};
static int rd(struct xgo_reader *r, uint64_t at, void *out, size_t n) {
    if (r->error) return 0;
    if (r->reads >= XGO_READ_LIMIT || n > XGO_BYTE_LIMIT - r->bytes) { r->error = "GoReadLimit"; return 0; }
    r->reads++; r->bytes += n;
    return at != 0 && r->read(r->context, at, out, n) == 0;
}
static uint64_t get(const struct xgo_layout *l, const uint8_t *base, enum xgo_field f) {
    uint64_t v = 0;
    for (uint32_t i = 0; i < l->fields[f].size && i < 8; ++i) v |= (uint64_t)base[l->fields[f].offset + i] << (8 * i);
    return v;
}
static int word(struct xgo_reader *r, uint64_t at, uint64_t *out) {
    uint8_t b[8];
    if (!rd(r, at, b, 8)) return 0;
    uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v |= (uint64_t)b[i] << (8 * i);
    *out = v; return 1;
}
#define C(l, k) ((l)->constants[XGO_C_##k])
static void module_read(const struct xgo_layout *l, struct xgo_reader *r, const struct xgo_globals *gl, struct mod *m) {
    uint8_t buf[2048];
    memset(m, 0, sizeof *m);
    if (l->sizes[XGO_T_MODULE] > sizeof buf) { m->reason = "GoModuleLayoutTooLarge"; return; }
    if (!rd(r, gl->moduledata, buf, l->sizes[XGO_T_MODULE])) { m->reason = r->error ? r->error : "GoModuleUnreadable"; return; }
    m->text = get(l, buf, XGO_MD_TEXT); m->minpc = get(l, buf, XGO_MD_MINPC); m->maxpc = get(l, buf, XGO_MD_MAXPC);
    m->ftab = get(l, buf, XGO_MD_FTAB); m->pcln = get(l, buf, XGO_MD_PCLN); m->names = get(l, buf, XGO_MD_NAMES);
    uint64_t nftab = get(l, buf, XGO_MD_FTAB_LEN), pcln_len = get(l, buf, XGO_MD_PCLN_LEN), names_len = get(l, buf, XGO_MD_NAMES_LEN);
    uint64_t sections = get(l, buf, XGO_MD_TEXTSECT_LEN);
    if (sections > 1) { m->reason = "GoTextSectionsUnsupported"; return; }
    if (nftab < 2 || nftab > (1u << 22) || pcln_len > (1ull << 32) || names_len > (1ull << 32) ||
        m->minpc >= m->maxpc || m->text > m->minpc || !m->ftab || !m->pcln || !m->names) { m->reason = "GoModuleImplausible"; return; }
    m->nftab = nftab - 1; m->pcln_len = pcln_len; m->names_len = names_len;
}
static void func_at(const struct xgo_layout *l, struct xgo_reader *r, const struct mod *m, uint64_t pc, struct xgo_func *out) {
    memset(out, 0, sizeof *out);
    if (m->reason) { out->reason = m->reason; return; }
    if (pc < m->minpc || pc >= m->maxpc) { out->reason = "GoPcOutsideModule"; return; }
    uint64_t off = pc - m->text, lo = 0, hi = m->nftab;
    uint8_t entry[8], fn[256];
    /* Largest ftab index whose entryoff <= off (runtime findfunc's order). */
    while (hi - lo > 1) {
        uint64_t mid = lo + (hi - lo) / 2, at;
        if (!rd(r, m->ftab + mid * 8, entry, 8)) { out->reason = r->error ? r->error : "GoPclntabUnreadable"; return; }
        at = get(l, entry, XGO_FT_ENTRY);
        if (at <= off) lo = mid; else hi = mid;
    }
    if (!rd(r, m->ftab + lo * 8, entry, 8)) { out->reason = r->error ? r->error : "GoPclntabUnreadable"; return; }
    uint64_t entry_off = get(l, entry, XGO_FT_ENTRY), func_off = get(l, entry, XGO_FT_FUNC);
    if (entry_off > off) { out->reason = "GoPcOutsideModule"; return; }
    if (l->sizes[XGO_T_FUNC] > sizeof fn || func_off > m->pcln_len || l->sizes[XGO_T_FUNC] > m->pcln_len - func_off) { out->reason = "GoPclntabMalformed"; return; }
    if (!rd(r, m->pcln + func_off, fn, l->sizes[XGO_T_FUNC])) { out->reason = r->error ? r->error : "GoPclntabUnreadable"; return; }
    /* Stored cross-check: the _func record names the same entry as ftab. */
    if (get(l, fn, XGO_FN_ENTRY) != entry_off) { out->reason = "GoPclntabMismatch"; return; }
    int64_t name_off = (int32_t)(uint32_t)get(l, fn, XGO_FN_NAME);
    if (name_off < 0 || (uint64_t)name_off >= m->names_len) { out->reason = "GoPclntabMalformed"; return; }
    size_t want = XGO_NAME - 1;
    if (m->names_len - (uint64_t)name_off < want) want = (size_t)(m->names_len - (uint64_t)name_off);
    if (!rd(r, m->names + (uint64_t)name_off, out->name, want)) { out->name[0] = 0; out->reason = r->error ? r->error : "GoPclntabUnreadable"; return; }
    out->name[want] = 0;
    if (strlen(out->name) == want) out->reason = "GoFunctionNameTruncated";
    out->entry = m->text + entry_off;
    out->id = (uint8_t)get(l, fn, XGO_FN_ID);
}
void xgo_func_at(const struct xgo_layout *l, struct xgo_reader *r, const struct xgo_globals *gl, uint64_t pc, struct xgo_func *out) {
    struct mod m;
    module_read(l, r, gl, &m);
    func_at(l, r, &m, pc, out);
}
static void text(struct xgo_reader *r, uint64_t strings, uint64_t count, uint64_t index, char *out, size_t size, const char *fallback) {
    uint64_t ptr, len;
    out[0] = 0;
    if (index >= count) { strncpy(out, fallback, size - 1); out[size - 1] = 0; return; }
    if (!word(r, strings + index * 16, &ptr) || !word(r, strings + index * 16 + 8, &len) || len >= size || !rd(r, ptr, out, (size_t)len)) {
        strncpy(out, "?", size); return;
    }
    out[len] = 0;
}
static int exported_runtime(const char *name) {
    if (strncmp(name, "runtime.", 8)) return 0;
    name += 8;
    const char *dot = strrchr(name, '.'), *rcvr = NULL;
    size_t rl = 0;
    if (dot) {
        rcvr = name; rl = (size_t)(dot - name); name = dot + 1;
        if (rl >= 3 && rcvr[0] == '(' && rcvr[1] == '*' && rcvr[rl - 1] == ')') { rcvr += 2; rl -= 3; }
    }
    return name[0] >= 'A' && name[0] <= 'Z' && (!rl || (rcvr[0] >= 'A' && rcvr[0] <= 'Z'));
}
int xgo_traceback_visible(const struct xgo_layout *l, const char *name, uint8_t id, int first, int have_callee, uint8_t callee) {
    if (id == C(l, FUNC_WRAPPER)) {
        int keep = have_callee && (callee == C(l, FUNC_GOPANIC) || callee == C(l, FUNC_SIGPANIC) || callee == C(l, FUNC_PANICWRAP));
        if (!keep) return 0;
    }
    if (id == C(l, FUNC_FINALIZERS) || id == C(l, FUNC_CLEANUPS)) return 1;
    if (!strcmp(name, "runtime.gopanic") && !first) return 1;
    return strchr(name, '.') && (strncmp(name, "runtime.", 8) || exported_runtime(name));
}
static void walk(const struct xgo_layout *l, struct xgo_reader *r, const struct mod *m, struct xgo_goroutine *g) {
    uint64_t pc = g->pc, bp = g->bp, previous = 0;
    if (!pc) { g->reason = "GoSchedulerStateEmpty"; return; }
    for (g->count = 0; g->count < XGO_FRAMES; ) {
        struct xgo_frame *f = &g->frames[g->count++];
        memset(f, 0, sizeof *f);
        f->pc = pc; f->fp = bp;
        func_at(l, r, m, pc, &f->func);
        if (f->func.reason && !f->func.name[0]) {
            f->reason = f->func.reason; f->lookup_pc = pc;
            g->reason = !strcmp(f->func.reason, "GoPcOutsideModule") ? "GoFramePcUnmapped" : f->func.reason;
            return;
        }
        /* Return addresses symbolize at pc-1 unless pc is a function entry
         * (a fresh goroutine's sched.pc), as the runtime's own unwinder does. */
        f->lookup_pc = pc > f->func.entry ? pc - 1 : pc;
        if (f->func.id == C(l, FUNC_GOEXIT)) { g->complete = 1; return; }
        if (!bp) { g->reason = "GoFramePointerEnd"; return; }
        if (bp & 7 || bp < g->stack_lo || bp > g->stack_hi - 16 || bp <= previous || (previous == 0 && g->sp && bp < g->sp)) {
            f->reason = g->reason = "GoFramePointerOutOfStack"; return;
        }
        uint64_t next, ret;
        if (!word(r, bp, &next) || !word(r, bp + 8, &ret)) { f->reason = g->reason = r->error ? r->error : "GoStackUnreadable"; return; }
        previous = bp; bp = next; pc = ret;
    }
    g->reason = "GoFrameLimit";
}
void xgo_goroutines_read(const struct xgo_layout *l, struct xgo_reader *r, const struct xgo_globals *gl, struct xgo_snapshot *out) {
    memset(out, 0, offsetof(struct xgo_snapshot, items));
    struct mod m;
    uint8_t slice[64], gb[1024];
    uint64_t len2;
    if (l->sizes[XGO_T_GSLICE] > sizeof slice || l->sizes[XGO_T_G] > sizeof gb) { out->reason = "GoLayoutTooLarge"; return; }
    module_read(l, r, gl, &m);
    if (m.reason) { out->reason = m.reason; return; }
    if (!rd(r, gl->allgs, slice, l->sizes[XGO_T_GSLICE]) || !word(r, gl->allglen, &len2)) { out->reason = r->error ? r->error : "GoAllgsUnreadable"; return; }
    uint64_t array = get(l, slice, XGO_GS_PTR), len = get(l, slice, XGO_GS_LEN);
    /* The runtime stores the count twice (allgs.len and allglen). */
    if (len != len2) { out->reason = "GoAllgsInconsistent"; return; }
    if (len > (1u << 20)) { out->reason = "GoGoroutineCountImplausible"; return; }
    out->total = (size_t)len;
    for (uint64_t i = 0; i < len; ++i) {
        uint64_t gp;
        if (!word(r, array + i * 8, &gp) || !gp) { out->reason = r->error ? r->error : "GoAllgsUnreadable"; return; }
        if (!rd(r, gp, gb, l->sizes[XGO_T_G])) { out->reason = r->error ? r->error : "GoGoroutineUnreadable"; return; }
        uint32_t raw = (uint32_t)get(l, gb, XGO_G_STATUS), status = raw & ~(uint32_t)C(l, GSCAN);
        if (status == C(l, GDEAD) || status == C(l, GDEADEXTRA)) { out->dead++; continue; }
        if (out->count == XGO_GOROUTINES) { out->truncated = 1; continue; }
        struct xgo_goroutine *g = &out->items[out->count++];
        memset(g, 0, sizeof *g);
        g->g = gp; g->raw_status = raw; g->status = status; g->scan = raw != status;
        g->goid = get(l, gb, XGO_G_GOID); g->parent = get(l, gb, XGO_G_PARENT);
        g->gopc = get(l, gb, XGO_G_GOPC); g->startpc = get(l, gb, XGO_G_STARTPC);
        g->m = get(l, gb, XGO_G_M); g->wait_reason = (uint8_t)get(l, gb, XGO_G_WAITREASON);
        g->stack_lo = get(l, gb, XGO_G_STACK_LO); g->stack_hi = get(l, gb, XGO_G_STACK_HI);
        text(r, gl->status_strings, gl->status_count, status, g->status_name, sizeof g->status_name, "???");
        if ((status == C(l, GWAITING) || status == C(l, GLEAKED)) && g->wait_reason)
            text(r, gl->wait_strings, gl->wait_count, g->wait_reason, g->wait_name, sizeof g->wait_name, "unknown wait reason");
        func_at(l, r, &m, g->gopc, &g->creator);
        func_at(l, r, &m, g->startpc, &g->start);
        if (g->start.reason && !g->start.name[0]) g->system = 0;
        else if (g->start.id == C(l, FUNC_MAIN) || g->start.id == C(l, FUNC_COROSTART) || g->start.id == C(l, FUNC_ASYNCEVENT)) g->system = 0;
        else g->system = !strncmp(g->start.name, "runtime.", 8);
        if (g->stack_lo >= g->stack_hi || g->stack_hi - g->stack_lo > (1ull << 30)) { g->reason = "GoStackBoundsImplausible"; continue; }
        if (status == C(l, GRUNNING)) {
            g->running = 1;
            if (!g->m) { g->reason = "GoRunningWithoutM"; continue; }
            uint64_t curg;
            if (!word(r, g->m + l->fields[XGO_M_PROCID].offset, &g->thread) || !word(r, g->m + l->fields[XGO_M_CURG].offset, &curg)) {
                g->reason = r->error ? r->error : "GoMUnreadable"; continue;
            }
            if (curg != gp) g->reason = "GoRunningGoroutineNotCurrent";
            continue;
        }
        if (status == C(l, GSYSCALL)) {
            g->pc = get(l, gb, XGO_G_SYSCALL_PC); g->sp = get(l, gb, XGO_G_SYSCALL_SP); g->bp = get(l, gb, XGO_G_SYSCALL_BP);
        } else {
            g->pc = get(l, gb, XGO_G_SCHED_PC); g->sp = get(l, gb, XGO_G_SCHED_SP); g->bp = get(l, gb, XGO_G_SCHED_BP);
        }
        walk(l, r, &m, g);
        if (r->error) { out->reason = r->error; return; }
    }
}
