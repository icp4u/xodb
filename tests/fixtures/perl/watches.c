/* Cooperating fixture oracle uses Perl's public macros on PadWalker references.
 * It shares no decoder or canonicalization code with the product. */
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifdef XODB_PERL_WATCH_ORACLE
#include "../../../src/language/perl.h"
#include <assert.h>
#include <fcntl.h>
#include <sys/uio.h>
#include <unistd.h>
static struct xpl_layout layout;
static size_t verified_samples;
static int owned_read(void *unused, uint64_t address, void *out, size_t n) {
    (void)unused;
    struct iovec local = {out, n}, remote = {(void *)(uintptr_t)address, n};
    return process_vm_readv(getpid(), &local, 1, &remote, 1, 0) == (ssize_t)n ? 0 : -1;
}
#endif
static int append(unsigned char *out, size_t *used, uint64_t n, unsigned count) {
    if (count > 4096 - *used) return 0;
    for (unsigned i = 0; i < count; ++i) out[(*used)++] = (unsigned char)(n >> (i * 8));
    return 1;
}
static int oracle(pTHX_ SV *sv, unsigned *kind, unsigned char *bytes, size_t *used) {
    *kind = 0; *used = 0;
    if (SvMAGICAL(sv) || SvOBJECT(sv) || SvROK(sv) ||
        !(SvTYPE(sv) == SVt_NULL || SvTYPE(sv) == SVt_IV || SvTYPE(sv) == SVt_NV ||
          SvTYPE(sv) == SVt_PV || SvTYPE(sv) == SVt_PVIV || SvTYPE(sv) == SVt_PVNV || SvTYPE(sv) == SVt_PVMG)) return 0;
    if (SvIOK(sv)) {
        *kind |= 1 | (SvIsUV(sv) ? 8 : 0);
        if (!append(bytes, used, SvIsUV(sv) ? SvUVX(sv) : (uint64_t)SvIVX(sv), 8)) return 0;
    }
    if (SvNOK(sv)) {
        NV nv = SvNVX(sv); uint64_t bits;
        _Static_assert(sizeof nv == sizeof bits, "oracle requires 64-bit NV");
        memcpy(&bits, &nv, sizeof bits); *kind |= 2;
        if (!append(bytes, used, bits, 8)) return 0;
    }
    if (SvPOK(sv)) {
        *kind |= 4;
        const U8 *at = (const U8 *)SvPVX(sv), *end = at + SvCUR(sv);
        while (at < end) {
            STRLEN length = 1;
            UV cp = SvUTF8(sv) ? utf8_to_uvchr_buf(at, end, &length) : *at;
            if (!length || length > (STRLEN)(end-at) || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return 0;
            if (!append(bytes, used, cp, 4)) return 0;
            at += length;
        }
    }
    return 1;
}
__attribute__((noinline)) void xodb_perl_watch_stop(PerlInterpreter *my_perl) {
    __asm__ volatile("" : : "r"(my_perl) : "memory"); /* WATCH_STOP */
}
static XS(snapshot) {
    dXSARGS;
    if (items != 2 || !SvROK(ST(1)) || SvTYPE(SvRV(ST(1))) != SVt_PVAV) croak("expected label and oracle frames");
    AV *frames = (AV *)SvRV(ST(1));
    printf("{\"label\":\"%s\",\"context_array\":%" UVuf ",\"frames\":[", SvPV_nolen(ST(0)), PTR2UV(PL_curstackinfo->si_cxstack));
    for (SSize_t f = 0; f <= av_top_index(frames); ++f) {
        SV **ref = av_fetch(frames, f, 0);
        if (!ref || !SvROK(*ref) || SvTYPE(SvRV(*ref)) != SVt_PVHV) croak("bad frame");
        HV *vars = (HV *)SvRV(*ref);
        if (f) putchar(',');
        putchar('['); int first = 1;
        hv_iterinit(vars);
        HE *entry;
        while ((entry = hv_iternext(vars))) {
            SV *value = HeVAL(entry);
            if (!SvROK(value)) croak("bad binding");
            value = SvRV(value);
            unsigned kind; unsigned char bytes[4096]; size_t used;
            int complete = oracle(aTHX_ value, &kind, bytes, &used);
#ifdef XODB_PERL_WATCH_ORACLE
            struct xpl_sample observed;
            struct xpl_reader reader = {.read = owned_read};
            xpl_sample_read(&layout, &reader, (uintptr_t)value, &observed);
            assert((observed.reason == NULL) == complete);
            if (complete) assert(observed.kind == kind && observed.size == used && !memcmp(observed.bytes, bytes, used));
            ++verified_samples;
#endif
            if (!first) putchar(',');
            first = 0;
            /* Hash keys can be stored as Latin-1 even for UTF-8 source names. */
            SV *key = hv_iterkeysv(entry);
            const char *name = SvPVutf8_nolen(key);
            printf("{\"name\":\"%s\",\"address\":%" UVuf ",\"kind\":%u,\"complete\":%s,\"hex\":\"", name, PTR2UV(value), kind, complete ? "true" : "false");
            if (complete) for (size_t i = 0; i < used; ++i) printf("%02x", bytes[i]);
            printf("\"}");
        }
        putchar(']');
    }
    puts("]}"); fflush(stdout);
#ifdef XODB_PERL_WATCH_ORACLE
    fprintf(stderr, "verified %zu scalar samples\n", verified_samples);
#endif
    xodb_perl_watch_stop(aTHX);
    XSRETURN_EMPTY;
}
EXTERN_C void boot_XodbWatch(pTHX_ CV *cv) {
    (void)cv;
#ifdef XODB_PERL_WATCH_ORACLE
    int fd = open(getenv("XODB_PERL_ORACLE_IMAGE"), O_RDONLY | O_CLOEXEC); assert(fd >= 0);
    Dwarf *dw = dwarf_begin(fd, DWARF_C_READ); assert(dw);
    uint8_t id[] = {1}, version[] = {5,44,0};
    const char *why = xpl_layout_build(dw, id, sizeof id, version, &layout);
    if (why) { fprintf(stderr, "%s\n", why); abort(); }
    dwarf_end(dw); close(fd);
#endif
    newXS("XodbWatch::snapshot", snapshot, __FILE__);
}
