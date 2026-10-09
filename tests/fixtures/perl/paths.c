/* The fixture's public Perl macros and actual Perl subscriptions supply the
 * oracle. The optional component build additionally checks the external reader. */
#ifdef XODB_PERL_PATH_ORACLE
#define XODB_PERL_WATCH_ORACLE
#endif
#include "watches.c"
static void json_text(const char *s) {
    putchar('"');
    for (const unsigned char *p=(const unsigned char *)s;*p;++p) {
        if (*p=='"' || *p=='\\') {putchar('\\');putchar(*p);}
        else if (*p<32) printf("\\u%04x",*p);
        else putchar(*p);
    }
    putchar('"');
}
static SV *element(AV *av, SSize_t index) {
    SV **p=av_fetch(av,index,0);if(!p) croak("oracle row missing");return *p;
}
static XS(paths_snapshot) {
    dXSARGS;
    if(items!=3 || !SvROK(ST(1)) || SvTYPE(SvRV(ST(1)))!=SVt_PVHV ||
       !SvROK(ST(2)) || SvTYPE(SvRV(ST(2)))!=SVt_PVAV) croak("bad snapshot");
    HV *bindings=(HV *)SvRV(ST(1));AV *rows=(AV *)SvRV(ST(2));
    printf("{\"label\":");json_text(SvPV_nolen(ST(0)));printf(",\"values\":[");
    for(SSize_t i=0;i<=av_top_index(rows);++i) {
        SV *ref=element(rows,i);if(!SvROK(ref) || SvTYPE(SvRV(ref))!=SVt_PVAV) croak("bad row");
        AV *row=(AV *)SvRV(ref);
        const char *expression=SvPV_nolen(element(row,0)),*root=SvPV_nolen(element(row,1));
        SV **binding=hv_fetch(bindings,root,(I32)strlen(root),0);
        if(!binding || !SvROK(*binding)) croak("root binding missing");
        SV *root_sv=SvRV(*binding),*expected_ref=element(row,2);
        const char *reason=SvPV_nolen(element(row,3));
        SV *expected=SvROK(expected_ref)?SvRV(expected_ref):NULL;
        unsigned kind=0;unsigned char bytes[4096];size_t used=0;
        if(!*reason && (!expected || !oracle(aTHX_ expected,&kind,bytes,&used))) croak("incomplete expected scalar");
#ifdef XODB_PERL_PATH_ORACLE
        struct xpl_reader reader={.read=owned_read};struct xpl_path_value got;
        xpl_path_read(&layout,&reader,(uintptr_t)root_sv,expression,&got);
        if(*reason) {
            if(!got.reason || strcmp(reason,got.reason)) {fprintf(stderr,"%s: wanted %s got %s\n",expression,reason,got.reason?got.reason:"value");abort();}
        } else {
            if(got.reason) {fprintf(stderr,"%s: %s\n",expression,got.reason);abort();}
#ifdef XODB_PERL_PATH_ORACLE_NEGATIVE
            got.sv ^= 8; /* The harness must reject this wrong element address. */
#endif
            CHECK(got.sv==(uintptr_t)expected);
            struct xpl_sample sample;xpl_sample_read(&layout,&reader,got.sv,&sample);
            CHECK(!sample.reason && sample.kind==kind && sample.size==used && !memcmp(sample.bytes,bytes,used));
        }
        ++verified_samples;
#endif
        if(i)putchar(',');printf("{\"expression\":");json_text(expression);
        printf(",\"root_address\":%" UVuf ",\"address\":%" UVuf ",\"reason\":",PTR2UV(root_sv),PTR2UV(expected));
        if(*reason)json_text(reason);else printf("null");
        printf(",\"kind\":%u,\"sample\":\"",kind);
        for(size_t j=0;j<used;++j)printf("%02x",bytes[j]);printf("\"}");
    }
    puts("]}");fflush(stdout);
#ifdef XODB_PERL_PATH_ORACLE
    fprintf(stderr,"verified %zu path samples\n",verified_samples);
#endif
    xodb_perl_watch_stop(aTHX);XSRETURN_EMPTY;
}
EXTERN_C void boot_XodbPaths(pTHX_ CV *cv) {
    boot_XodbWatch(aTHX_ cv);
    newXS("XodbPaths::snapshot",paths_snapshot,__FILE__);
}
