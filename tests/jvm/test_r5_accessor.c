/* C05-R5: the typed frame accessor carries the whole function identity.
 *   test-r5-accessor REGRESS_DIR
 * For each input, every pair of distinct document functions must differ in
 * the tuple a host reads through jvm_evidence_function (
 * p/C against p.C, a real NUL against a literal "\0"), every frame must report
 * its function's identity, and the escape bits must name the escaped field.
 *   identity-variants.json  12 functions (p/C and p.C distinct)
 *   nul-escape.json         6 functions: m<NUL>a, m\0a, m\\0a, m\u0000a, m<NUL>, m
 *   nul-field-swap.json     2 functions: class p/X<NUL> + method m\0 against
 *                           class p/X\0 + method m<NUL> (one flag per frame
 *                           merged them in C05-R4)
 * Also: jvm_limits_default leaves no member to the caller's stack garbage
 * (jfr_export_depth was uninitialized in C05-R4, so an -O2 CLI could call an
 * undeclared-depth JFR stack "complete"). */
#define _GNU_SOURCE 1
#include "jvm_evidence.h"
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static const char *regress;
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
}
static int same_str(const char *a, const char *b)
{
    return a == b || (a && b && !strcmp(a, b));
}
static int same_identity(const struct jvm_evidence_frame *a, const struct jvm_evidence_frame *b)
{
    return a->mode == b->mode && a->loader_status == b->loader_status && a->nul_escaped == b->nul_escaped &&
           same_str(a->class_name, b->class_name) && same_str(a->raw_class, b->raw_class) &&
           same_str(a->method, b->method) && same_str(a->descriptor, b->descriptor) &&
           same_str(a->class_loader, b->class_loader) && same_str(a->class_loader_type, b->class_loader_type) &&
           same_str(a->module, b->module) && same_str(a->module_version, b->module_version);
}
static struct jvm_evidence *load(const char *name)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", regress, name);
    struct jvm_evidence_limits l;
    jvm_evidence_default_limits(&l);
    l.import.jfr_export_depth = 2048;
    struct jvm_evidence *ev = NULL;
    struct xlf_error err;
    enum xlf_status st = jvm_evidence_import(path, JVM_SOURCE_JFR_JSON, NULL, &l, NULL, &ev, &err);
    check(st == XLF_OK, "%s imports (%s)", name, st ? err.message : "ok");
    return st == XLF_OK ? ev : NULL;
}
/* Distinct functions have distinct accessor identities; frames agree with their function. */
static void injective(const char *name, size_t want_functions)
{
    struct jvm_evidence *ev = load(name);
    if (!ev)
        return;
    const struct xlf_doc *d = jvm_evidence_doc(ev);
    size_t collisions = 0, mismatched = 0;
    for (uint32_t i = 0; i < d->function_count; i++)
        for (uint32_t j = i + 1; j < d->function_count; j++) {
            struct jvm_evidence_frame a, b;
            if (jvm_evidence_function(ev, i, &a) || jvm_evidence_function(ev, j, &b) || same_identity(&a, &b)) {
                collisions++;
                printf("     f%u and f%u read the same: %s | %s.%s esc=%u\n", i, j, a.raw_class ? a.raw_class : "-",
                       a.class_name ? a.class_name : "-", a.method ? a.method : "-", a.nul_escaped);
            }
        }
    for (uint32_t k = 0; k < d->frame_count; k++) {
        struct jvm_evidence_frame f, g;
        uint32_t fn = d->frames[k].function;
        if (fn == XLF_NONE)
            continue;
        if (jvm_evidence_frame(ev, k, &f) || jvm_evidence_function(ev, fn, &g) || !same_identity(&f, &g))
            mismatched++;
    }
    check(d->function_count == want_functions, "%s: %zu functions (want %zu)", name, d->function_count,
          want_functions);
    check(collisions == 0, "%s: no two functions share an accessor identity (%zu pairs do)", name, collisions);
    check(mismatched == 0, "%s: every frame reports its function's identity (%zu do not)", name, mismatched);
    jvm_evidence_free(ev);
}
/* The function of stack i's innermost frame, through the accessor. */
static int stack_function(struct jvm_evidence *ev, uint32_t i, struct jvm_evidence_frame *out)
{
    const struct xlf_doc *d = jvm_evidence_doc(ev);
    return i < d->stack_count ? jvm_evidence_function(ev, d->frames[d->stacks[i].first_frame].function, out) : -1;
}
static void fields(void)
{
    struct jvm_evidence *ev = load("identity-variants.json");
    struct jvm_evidence_frame a, b;
    if (ev) {
        int ok = !stack_function(ev, 0, &a) && !stack_function(ev, 1, &b);
        check(ok && !strcmp(a.class_name, "p.C") && !strcmp(b.class_name, "p.C") && !strcmp(a.raw_class, "p/C") &&
                  !strcmp(b.raw_class, "p.C"),
              "identity-variants: p/C and p.C share class_name p.C, raw_class tells them apart (%s, %s)",
              ok ? a.raw_class : "-", ok ? b.raw_class : "-");
        jvm_evidence_free(ev);
    }
    if ((ev = load("nul-escape.json"))) {
        /* events: m<NUL>a, literal m\0a, literal m\\0a, literal m\u0000a, m<NUL>, m */
        static const char *const method[] = {"m\\0a", "m\\0a", "m\\\\0a", "m\\u0000a", "m\\0", "m"};
        static const uint8_t esc[] = {JVM_NUL_METHOD, 0, 0, 0, JVM_NUL_METHOD, 0};
        int ok = 1;
        for (uint32_t i = 0; i < 6; i++) {
            ok &= !stack_function(ev, i, &a) && !strcmp(a.method, method[i]) && a.nul_escaped == esc[i] &&
                  !strcmp(a.raw_class, "p/C");
        }
        check(ok, "nul-escape: methods as stored with the method escape bit only on real NULs");
        ok = !stack_function(ev, 0, &a) && !stack_function(ev, 1, &b);
        check(ok && !strcmp(a.method, b.method) && a.nul_escaped != b.nul_escaped,
              "nul-escape: real NUL and literal \\0 read the same text and differ in nul_escaped (%u, %u)",
              ok ? a.nul_escaped : 0, ok ? b.nul_escaped : 0);
        jvm_evidence_free(ev);
    }
    if ((ev = load("nul-field-swap.json"))) {
        int ok = !stack_function(ev, 0, &a) && !stack_function(ev, 1, &b);
        check(ok && a.nul_escaped == JVM_NUL_CLASS && b.nul_escaped == JVM_NUL_METHOD &&
                  !strcmp(a.class_name, b.class_name) && !strcmp(a.method, b.method),
              "nul-field-swap: same text, escape bits name the field (class %u, method %u)", ok ? a.nul_escaped : 0,
              ok ? b.nul_escaped : 0);
        const char *doc;
        size_t n;
        doc = jvm_evidence_lframes(ev, &n);
        check(doc && memmem(doc, n, "\"x_nul_escaped_fields\":[\"class\"]", 32) &&
                  memmem(doc, n, "\"x_nul_escaped_fields\":[\"method\"]", 33),
              "nul-field-swap: the C05 document names the escaped field");
        jvm_evidence_free(ev);
    }
}
int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: test-r5-accessor REGRESS_DIR\n");
        return 2;
    }
    regress = argv[1];
    injective("identity-variants.json", 12);
    injective("nul-escape.json", 6);
    injective("nul-field-swap.json", 2);
    fields();
    struct jvm_limits l;
    memset(&l, 0xa5, sizeof l);
    jvm_limits_default(&l);
    check(l.jfr_export_depth == 0, "jvm_limits_default: export depth undeclared (%u)", l.jfr_export_depth);
    printf("%d cases, %d failures\n", cases, failures);
    return failures != 0;
}
