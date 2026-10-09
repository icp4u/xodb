/* Owned cooperating fixture. PadWalker runs only in this fixture; the product
 * reader receives an exact-read callback and never calls interpreter code. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#ifdef XODB_PERL_ORACLE
#include "../../../src/language/perl.h"
#include "../../check.h"
#include <fcntl.h>
#include <sys/uio.h>
#include <unistd.h>
static struct xpl_layout layout;
static unsigned checks, frames, snapshots;
static int owned_read(void *unused, uint64_t address, void *out, size_t n) {
    (void)unused;
    struct iovec local = {out, n}, remote = {(void *)(uintptr_t)address, n};
    return process_vm_readv(getpid(), &local, 1, &remote, 1, 0) == (ssize_t)n ? 0 : -1;
}
static void verify(pTHX_ AV *expected) {
    struct xpl_stack *stack = calloc(1, sizeof *stack);
    struct xpl_locals *locals = calloc(1, sizeof *locals), *lookup = calloc(1, sizeof *lookup);
    CHECK(stack && locals && lookup);
    struct xpl_reader r = {.read = owned_read};
    xpl_stack_read(&layout, &r, (uintptr_t)my_perl, stack);
    CHECK(!r.error);
    for (size_t f = 0; f < stack->count; ++f) {
        printf("frame %zu %s type %u\n", f, stack->frames[f].name, stack->frames[f].context_type);
        CHECK(f <= (size_t)av_top_index(expected));
        SV **want = av_fetch(expected, (SSize_t)f, 0); CHECK(want && SvROK(*want));
        HV *bindings = (HV *)SvRV(*want); CHECK(SvTYPE(bindings) == SVt_PVHV);
        size_t total = 0;
        do {
        r = (struct xpl_reader){.read = owned_read};
        xpl_locals_read(&layout, &r, (uintptr_t)my_perl, f, total, 7, locals);
        if (locals->reason) { fprintf(stderr, "frame %zu: %s\n", f, locals->reason); abort(); }
#ifdef XODB_PERL_ORACLE_NEGATIVE
        locals->total ^= 1; /* The harness must reject this wrong binding count. */
#endif
        CHECK(locals->total == HvTOTALKEYS(bindings));
        for (size_t i = 0; i < locals->count; ++i) {
            const struct xpl_local *row = &locals->items[i];
            SV **oracle = hv_fetch(bindings, row->name, (I32)strlen(row->name), 0);
            if (!oracle) { fprintf(stderr, "unexpected name %s frame %zu\n", row->name, f); abort(); }
            CHECK(SvROK(*oracle));
            SV *value = SvRV(*oracle);
            if (row->sv != (uintptr_t)value) { fprintf(stderr, "wrong slot %s frame %zu\n", row->name, f); abort(); }
            printf("  %s = %s (%u)\n", row->name, row->value.display, row->scope);
            if (SvIOK(value) && !SvROK(value)) {
                char text[256]; snprintf(text, sizeof text, "IV %lld", (long long)SvIV(value));
                CHECK(!strcmp(text, row->value.display));
            }
            if (SvTYPE(value) == SVt_PVAV) CHECK(row->value.count == (uint64_t)(av_top_index((AV *)value) + 1));
            if (SvTYPE(value) == SVt_PVHV) CHECK(row->value.count == HvTOTALKEYS((HV *)value));
            if (SvPOK(value) && !SvROK(value)) {
                STRLEN n; const char *bytes = SvPV(value, n);
                CHECK(row->value.count == n && row->value.byte_count == n && !memcmp(row->value.bytes, bytes, n));
            }
            r = (struct xpl_reader){.read = owned_read};
            xpl_local_find(&layout, &r, (uintptr_t)my_perl, f, row->name, lookup);
            CHECK(!lookup->reason && lookup->count == 1 && lookup->items[0].sv == row->sv && lookup->items[0].ordinal == row->ordinal);
            ++checks;
        }
        total += locals->count;
        CHECK(!locals->truncated || locals->count);
        } while (locals->truncated);
        CHECK(total == HvTOTALKEYS(bindings));
        ++frames;
    }
    free(lookup); free(locals); free(stack); ++snapshots;
}
#endif
__attribute__((noinline)) void xodb_perl_named_stop(PerlInterpreter *my_perl, AV *expected) {
    volatile PerlInterpreter *retained = my_perl;
    __asm__ volatile("" : : "r"(retained), "r"(expected) : "memory"); /* NAMED_STOP */
}
static XS(snapshot) {
    dXSARGS;
    if (items != 1 || !SvROK(ST(0)) || SvTYPE(SvRV(ST(0))) != SVt_PVAV) croak("expected oracle array");
    AV *expected = (AV *)SvRV(ST(0));
#ifdef XODB_PERL_ORACLE
    verify(aTHX_ expected);
#endif
    xodb_perl_named_stop(aTHX_ expected);
    XSRETURN_EMPTY;
}
static XS(finished) {
    dXSARGS; (void)items;
#ifdef XODB_PERL_ORACLE
    printf("Perl named locals: %u bindings, %u frames, %u snapshots passed\n", checks, frames, snapshots);
#endif
    XSRETURN_EMPTY;
}
EXTERN_C void boot_XodbNamed(pTHX_ CV *cv) {
    (void)cv;
#ifdef XODB_PERL_ORACLE
    int fd = open(getenv("XODB_PERL_ORACLE_IMAGE"), O_RDONLY | O_CLOEXEC); CHECK(fd >= 0);
    Dwarf *dw = dwarf_begin(fd, DWARF_C_READ); CHECK(dw);
    uint8_t id[] = {1}, version[] = {5,44,0};
    const char *why = xpl_layout_build(dw, id, sizeof id, version, &layout);
    if (why) { fprintf(stderr, "%s\n", why); abort(); }
    dwarf_end(dw); close(fd);
#endif
    newXS("XodbNamed::snapshot", snapshot, __FILE__);
    newXS("XodbNamed::finished", finished, __FILE__);
}
