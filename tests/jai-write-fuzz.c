/* Synthetic graph and bounded owned headers; arbitrary path/value bytes. */
#define JAI_WRITE_NO_MAIN
#include "jai-write.c"
int LLVMFuzzerTestOneInput(const unsigned char *data,size_t size)
{
    if (!write_graph) write_fixture();
    if (size<3) return 0;
    size_t pn=data[0];if (pn>size-2) pn=size-2;
    size_t vn=size-2-pn;if (vn>XJAI_WRITE_VALUE) vn=XJAI_WRITE_VALUE;
    struct write_value before=writable;
    write_reader.reads=write_reader.bytes=0;struct xjai_write_plan plan;
    const char *why=xjai_write_plan(write_graph,write_index,(uintptr_t)&writable,(const char *)data+2,pn,(const char *)data+2+pn,vn,data[1]&1,&write_reader,&plan);
    if (why) {
        const unsigned char *p=(const unsigned char *)&plan;for (size_t i=0;i<sizeof plan;++i) CHECK(p[i]==0);
    } else CHECK(plan.size>0 && plan.size<=XJAI_WRITE_BYTES && plan.type<write_graph->type_count && plan.address>0 && plan.address<=UINT64_MAX-plan.size);
    CHECK(write_reader.reads<=16 && write_reader.bytes<=16*40 && !memcmp(&writable,&before,sizeof before));return 0;
}
