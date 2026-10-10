/* Periodic lane: mutate only owned container headers/slots; exact bounded reads. */
#define JAI_CONTAINER_NO_MAIN
#include "jai-container.c"
struct fuzz_span { const void *data;size_t size; };
static int fuzz_read(void *context,uint64_t at,void *out,size_t size)
{
    const struct fuzz_span *spans=context;
    for (unsigned i=0;i<4;++i) {
        uint64_t base=(uintptr_t)spans[i].data;
        if (at>=base && at-base<=spans[i].size && size<=spans[i].size-(at-base)) {
            memcpy(out,(const unsigned char *)spans[i].data+(at-base),size);return 1;
        }
    }
    return 0;
}
int LLVMFuzzerTestOneInput(const unsigned char *input,size_t size)
{
    struct xjai_region region;struct xjai_image im=container_fixture(&region);struct xjai_graph *g;build_graph(&im,&g);
    struct bucket_value bucket={.count=2,.occupied={0,1,0,1}};
    bucket.data[1]=(struct typed_child){{typed_child_type},22};bucket.data[3]=(struct typed_child){{typed_child_type},44};
    int64_t values[]={1,2,3,4};struct dynamic_value dynamic={2,(uintptr_t)values,4,{0,0}};
    for (size_t i=0;i<size && i<sizeof bucket;++i) ((unsigned char *)&bucket)[i]^=input[i];
    if (size>sizeof bucket) for (size_t i=0;i<size-sizeof bucket && i<sizeof dynamic;++i) ((unsigned char *)&dynamic)[i]^=input[sizeof bucket+i];
    struct fuzz_span spans[]={{&bucket,sizeof bucket},{&dynamic,sizeof dynamic},{values,sizeof values},{arena,used}};
    struct xjai_live_reader reader={.context=spans,.read=fuzz_read};
    struct xjai_container_row rows[4];struct xjai_container_page page;
    uint64_t start=size?input[0]:0;
    const char *why=xjai_container_read(g,xjai_type_at(g,bucket_type),(uintptr_t)&bucket,start,rows,4,&reader,&page);
    CHECK(reader.reads<=512 && reader.bytes<=65536 && page.count<=4);
    if (why) CHECK(!page.count && !page.total_count);
    else {
        CHECK(page.total_count<=4);
        for (unsigned i=0;i<page.count;++i) CHECK(rows[i].slot<4 && bucket.occupied[rows[i].slot]==1 && rows[i].address==(uintptr_t)&bucket.data[rows[i].slot]);
    }
    reader.reads=reader.bytes=0;
    why=xjai_container_read(g,xjai_type_at(g,dynamic_type),(uintptr_t)&dynamic,start,rows,4,&reader,&page);
    CHECK(reader.reads<=512 && reader.bytes<=65536 && page.count<=4);
    if (why) CHECK(!page.count && !page.total_count);
    uint64_t address;uint32_t actual;reader.reads=reader.bytes=0;
    uint32_t base=xjai_type_at(g,typed_base_type);
    why=xjai_instance_candidate(g,base,g->types[base].first_member,(uintptr_t)&bucket.data[1],&reader,&address,&actual);
    if (why) CHECK(!address && actual==XJAI_NONE);
    else CHECK(address==(uintptr_t)&bucket.data[1] && actual<g->type_count);
    xjai_graph_free(g);return 0;
}
