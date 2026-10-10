/* Periodic lane: synthetic type graph mutations, never a captured image. */
#define JAI_READER_NO_MAIN
#include "jai-reader.c"
int LLVMFuzzerTestOneInput(const unsigned char *data,size_t size)
{
    struct xjai_region region;origin=UINT64_C(0x20000000002000);
    struct xjai_image image=graph_fixture(&region);
    for (size_t i=0;i+2<size;i+=3) arena[(((size_t)data[i]<<8)|data[i+1])%used]^=data[i+2];
    if (size && data[0]&1) region.size=1+(region.size*data[0])/256;
    struct xjai_limits limits={128,512,512,16384};struct xjai_graph *g=NULL;
    const char *why=xjai_graph_build(&image,&limits,&g);
    if (why) CHECK(!g);
    else {
        CHECK(g && g->type_count<=limits.types && g->member_count<=limits.members && g->enum_count<=limits.enums && g->text_bytes<=limits.text_bytes);
        struct xjai_flat_field rows[8];size_t count;
        for (uint32_t i=0;i<g->type_count;++i) {
            CHECK(g->types[i].name<g->text_bytes);
            if (g->types[i].tag==7) {xjai_fields_flatten(g,i,rows,8,&count);CHECK(count<=8);}
        }
        xjai_graph_free(g);
    }
    return 0;
}
