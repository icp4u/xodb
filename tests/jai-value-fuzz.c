/* Periodic lane: metadata fixed, value bytes/pointers mutated in owned spans. */
#define JAI_VALUE_NO_MAIN
#include "jai-value.c"
struct fuzz_memory { struct object_value *object;struct span *view;int64_t *numbers; };
static int copy_range(uint64_t at,void *out,size_t n,const void *p,size_t size)
{
    uint64_t base=(uintptr_t)p;
    if (at<base || at-base>size || n>size-(at-base)) return 0;
    memcpy(out,(const unsigned char *)p+(at-base),n);return 1;
}
static int fuzz_read(void *context,uint64_t at,void *out,size_t n)
{
    struct fuzz_memory *m=context;
    return copy_range(at,out,n,m->object,sizeof *m->object) || copy_range(at,out,n,m->view,sizeof *m->view) ||
        copy_range(at,out,n,m->numbers,4*sizeof *m->numbers) || copy_range(at,out,n,arena,used);
}
int LLVMFuzzerTestOneInput(const unsigned char *data,size_t size)
{
    struct xjai_region region;struct xjai_image image=value_fixture(&region);struct xjai_graph *g=NULL;
    CHECK(!xjai_graph_build(&image,NULL,&g));
    struct object_value object={.base={.score=-42},.energy=12.5,.fixed={1,-2,3}};object.next=(uintptr_t)&object;
    int64_t numbers[]={1,2,3,4};struct span view={4,(uintptr_t)numbers};
    for (size_t i=0;i<size && i<sizeof object;++i) ((unsigned char *)&object)[i]^=data[i];
    if (size>sizeof object) for (size_t i=0;i<size-sizeof object && i<sizeof view;++i) ((unsigned char *)&view)[i]^=data[sizeof object+i];
    struct fuzz_memory memory={&object,&view,numbers};struct xjai_live_reader reader={.context=&memory,.read=fuzz_read};
    struct xjai_value_options options={.depth=size?data[0]%9:3,.limit=1+(size?data[0]%64:8),.start=size>1?data[1]:0,.follow_pointers=1};
    struct xjai_values *v=NULL;CHECK(!xjai_value_read(g,xjai_type_at(g,object_type),(uintptr_t)&object,&options,&reader,&v));
    CHECK(v && v->count<=256 && reader.reads<=512 && reader.bytes<=65536);xjai_values_free(v);
    reader.reads=reader.bytes=0;CHECK(!xjai_value_read(g,xjai_type_at(g,view_type),(uintptr_t)&view,&options,&reader,&v));
    CHECK(v && v->count<=256 && reader.reads<=512 && reader.bytes<=65536);xjai_values_free(v);xjai_graph_free(g);return 0;
}
