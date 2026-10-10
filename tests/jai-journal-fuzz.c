/* Periodic: bounded write/readback failures and reverse-order recovery. */
#define JAI_JOURNAL_NO_MAIN
#include "jai-journal.c"
int LLVMFuzzerTestOneInput(const unsigned char *data,size_t size)
{
    struct target t={.generation=100};clean_mode(&t);
    for (size_t k=0;k<sizeof t.bytes;++k) t.bytes[k]=(unsigned char)k;
    unsigned char original[128];memcpy(original,t.bytes,sizeof original);
    struct xjai_write_journal *j=xjai_write_journal_create();CHECK(j);
    struct xjai_write_io io=io_for(&t);struct xjai_write_change c;
    for (size_t k=0;k+4<size && k<512;k+=5) {
        clean_mode(&t);t.mode=(enum mode)(data[k]%8);
        t.protected_count=1;t.protected_range=(struct xjai_write_range){(uintptr_t)t.bytes+96,16};
        size_t n=1+data[k+1]%64,offset=data[k+2]%(129-n);
        struct xjai_write_plan p={.address=(uintptr_t)t.bytes+offset,.size=n};
        memset(p.bytes,data[k+3],n);struct xjai_write_stamp s=stamp(&t);
        size_t count=xjai_write_journal_count(j);
        const char *reason=xjai_write_apply(j,&p,"bytes",5,data[k+4]&1,&s,&io,&c);
        CHECK(xjai_write_journal_count(j)==count+(c.id!=0));
        if (!c.id) CHECK(reason && !t.writes);
        else {CHECK(c.before_valid && c.write_attempted);if (!reason) CHECK(c.verified && c.observed_valid);}
        CHECK(!memcmp(t.bytes+96,original+96,16));
    }
    for (size_t k=xjai_write_journal_count(j);k>0;--k) {
        clean_mode(&t);struct xjai_write_stamp s=stamp(&t);
        CHECK(!xjai_write_undo(j,k,1,&s,&io,&c) && c.verified);
    }
    CHECK(!memcmp(t.bytes,original,sizeof original));xjai_write_journal_free(j);return 0;
}
