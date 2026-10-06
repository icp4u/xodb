/* Owned XS fixture. Only the fixture executes Perl API calls; xodb reads it. */
#include "EXTERN.h"
#include "XSUB.h"
#include "perl.h"

__attribute__((noinline)) void xodb_perl_values(SV *integer, SV *number, SV *string, SV *reference, AV *array, HV *hash,
                                                CV *code, GV *glob, PerlInterpreter *my_perl) {
    (void)my_perl;
    (void)integer;
    (void)number;
    (void)string;
    (void)reference;
    (void)array;
    (void)hash;
    (void)code;
    (void)glob;
    __asm__ volatile("" ::: "memory");
}
static XS(inspect_values) {
    dXSARGS;
    if (items != 8)
        croak("inspect requires eight arguments");
    xodb_perl_values(ST(0), ST(1), ST(2), ST(3), (AV *)SvRV(ST(4)), (HV *)SvRV(ST(5)), (CV *)SvRV(ST(6)),
                     (GV *)SvRV(ST(7)), aTHX);
    XSRETURN_EMPTY;
}
static XS(reenter) {
    dXSARGS;
    (void)items;
    call_pv("main::inside", G_DISCARD | G_NOARGS);
    XSRETURN_EMPTY;
}
static XS(callback) {
    dXSARGS;
    if (items != 1) croak("callback requires one coderef");
    call_sv(ST(0), G_DISCARD | G_NOARGS);
    XSRETURN_EMPTY;
}
EXTERN_C void boot_DynaLoader(pTHX_ CV *cv);
static void embedded_init(pTHX) { newXS("DynaLoader::boot_DynaLoader", boot_DynaLoader, __FILE__); }
static XS(embed) {
    dXSARGS;
    if (items != 3)
        croak("embed requires program, library and export paths");
    char *args[] = {"perl", SvPV_nolen(ST(0)), "values", SvPV_nolen(ST(1)), SvPV_nolen(ST(2)), NULL};
    PerlInterpreter *outer = my_perl;
    PerlInterpreter *inner = perl_alloc();
    if (!inner)
        croak("perl_alloc failed");
    PERL_SET_CONTEXT(inner);
    perl_construct(inner);
    int status = perl_parse(inner, embedded_init, 5, args, NULL);
    if (!status)
        status = perl_run(inner);
    perl_destruct(inner);
    perl_free(inner);
    PERL_SET_CONTEXT(outer);
    if (status)
        croak("embedded Perl failed");
    XSRETURN_EMPTY;
}
EXTERN_C void boot_XodbFixture(pTHX_ CV *cv) {
    (void)cv;
    newXS("XodbFixture::inspect", inspect_values, __FILE__);
    newXS("XodbFixture::reenter", reenter, __FILE__);
    newXS("XodbFixture::embed", embed, __FILE__);
    newXS("XodbFixture::callback", callback, __FILE__);
}
