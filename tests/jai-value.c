/* Fast lane: exact values in owned self/ptrace-stopped-child fixtures. */
#define _GNU_SOURCE 1
#define JAI_READER_NO_MAIN
#include "jai-reader.c"
#include <sys/uio.h>
#include <sys/ptrace.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <signal.h>
#include <unistd.h>
static unsigned long current_rss(void)
{
    FILE *f=fopen("/proc/self/statm","r");unsigned long pages,resident;
    CHECK(f && fscanf(f,"%lu %lu",&pages,&resident)==2);fclose(f);
    return resident*(unsigned long)sysconf(_SC_PAGESIZE);
}
struct typed_base { uint64_t rtti; };
struct typed_child { struct typed_base base;int64_t health; };
static uint64_t typed_base_type,typed_child_type,string_type,view_type,big_array;
static struct xjai_image value_fixture(struct xjai_region *region)
{
    origin=(uint64_t)(uintptr_t)arena;CHECK((origin&7)==0);
    struct xjai_image im=graph_fixture(region);
    uint64_t s64=type(0,8,24);put(s64+16,1,1);uint64_t meta=type(13,8,16),bm,cm;
    typed_base_type=make_struct("FixtureTypedBase",sizeof(struct typed_base),1,&bm);
    field(bm,0,"entity_type",meta,offsetof(struct typed_base,rtti),0);
    typed_child_type=make_struct("FixtureTypedChild",sizeof(struct typed_child),2,&cm);
    field(cm,0,"base",typed_base_type,offsetof(struct typed_child,base),20);
    field(cm,1,"health",s64,offsetof(struct typed_child,health),0);
    string_type=type(3,16,16);view_type=type(8,16,40);put(view_type+16,s64,8);put(view_type+24,1,2);put(view_type+26,0xface,2);put(view_type+32,UINT64_MAX,8);
    uint64_t inner=type(8,64*8,40);put(inner+16,s64,8);put(inner+24,0,2);put(inner+32,64,8);
    big_array=type(8,4*64*8,40);put(big_array+16,inner,8);put(big_array+24,0,2);put(big_array+32,4,8);
    uint64_t fields,holder=make_struct("FixtureValueRoots",16+16+4*64*8,3,&fields);(void)holder;
    field(fields,0,"text",string_type,0,0);field(fields,1,"view",view_type,16,0);field(fields,2,"matrix",big_array,32,0);
    region->size=used;return im;
}
static int memory(void *context,uint64_t at,void *out,size_t size)
{
    struct iovec local={out,size},remote={(void *)(uintptr_t)at,size};
    return process_vm_readv(*(pid_t *)context,&local,1,&remote,1,0)==(ssize_t)size;
}
static struct xjai_values *read_value(struct xjai_graph *g,uint64_t ti,uint64_t at,struct xjai_live_reader *r,struct xjai_value_options *options)
{
    struct xjai_values *v=NULL;CHECK(!xjai_value_read(g,xjai_type_at(g,ti),at,options,r,&v) && v);return v;
}
int xjai_value_fixture_main(int argc,char **argv)
{
    struct xjai_region region;struct xjai_image im=value_fixture(&region);struct xjai_graph *g;build_graph(&im,&g);
    struct object_value object={.base={.score=-42},.energy=12.5,.fixed={1,-2,3}};object.next=(uint64_t)(uintptr_t)&object;
    unsigned long rss_before=current_rss();
    pid_t pid=getpid();struct xjai_live_reader r={.context=&pid,.read=memory};
    struct xjai_values *v=read_value(g,object_type,(uintptr_t)&object,&r,NULL);
    CHECK(!v->partial && v->count==9);CHECK(v->rows[2].has_bits && v->rows[2].bits==(uint64_t)(int64_t)(argc>1 && !strcmp(argv[1],"--wrong-oracle")?-41:-42));
    CHECK(v->rows[2].address==(uintptr_t)&object.base.score && v->rows[3].bits==UINT64_C(0x4029000000000000));
    CHECK(v->rows[4].bits==(uintptr_t)&object && v->rows[7].bits==(uint64_t)(int64_t)-2);xjai_values_free(v);
    struct xjai_value_options options={.depth=8,.limit=64,.follow_pointers=1};r.reads=r.bytes=0;
    v=read_value(g,object_type,(uintptr_t)&object,&r,&options);CHECK(v->partial && !strcmp(v->rows[5].reason,"JaiValueCycle"));xjai_values_free(v);
    uint32_t oi=xjai_type_at(g,object_type),array_index=g->members[g->types[oi].first_member+3].type;
    options=(struct xjai_value_options){.depth=1,.limit=1,.start=1};r.reads=r.bytes=0;
    CHECK(!xjai_value_read(g,array_index,(uintptr_t)object.fixed,&options,&r,&v));CHECK(v->count==2 && v->rows[1].index==1 && v->rows[1].bits==(uint64_t)(int64_t)-2 && v->rows[0].truncated);xjai_values_free(v);
    unsigned char text_bytes[]={'h','i',0,'x',255};struct span text={5,(uintptr_t)text_bytes};r.reads=r.bytes=0;
    v=read_value(g,string_type,(uintptr_t)&text,&r,NULL);CHECK(!v->partial && v->rows[0].preview_bytes==5 && !memcmp(v->rows[0].preview,text_bytes,5));xjai_values_free(v);
    int64_t numbers[]={10,20,30};struct span view={3,(uintptr_t)numbers};r.reads=r.bytes=0;
    v=read_value(g,view_type,(uintptr_t)&view,&r,NULL);CHECK(!v->partial && v->count==4 && v->rows[3].bits==30);xjai_values_free(v);
    view.count=-1;r.reads=r.bytes=0;v=read_value(g,view_type,(uintptr_t)&view,&r,NULL);CHECK(v->partial && !strcmp(v->rows[0].reason,"JaiArrayHeaderInvalid"));xjai_values_free(v);
    struct typed_child child={{typed_child_type},99};uint32_t base=xjai_type_at(g,typed_base_type),actual=XJAI_NONE;r.reads=r.bytes=0;
    CHECK(!xjai_self_type(g,base,(uintptr_t)&child,g->types[base].first_member,&r,&actual) && actual==xjai_type_at(g,typed_child_type));
    v=read_value(g,typed_child_type,(uintptr_t)&child,&r,NULL);CHECK(!v->partial && v->count==4 && v->rows[2].referenced_type==actual && v->rows[3].bits==99);xjai_values_free(v);
    child.base.rtti=object_type;CHECK(!strcmp(xjai_self_type(g,base,(uintptr_t)&child,g->types[base].first_member,&r,&actual),"JaiDynamicTypeIncompatible") && actual==XJAI_NONE);
    child.base.rtti=UINT64_MAX;CHECK(!strcmp(xjai_self_type(g,base,(uintptr_t)&child,g->types[base].first_member,&r,&actual),"JaiTypePointerUnknown"));
    int64_t matrix[4][64]={{0}};matrix[0][1]=7;options=(struct xjai_value_options){.depth=3,.limit=64};r.reads=r.bytes=0;
    v=read_value(g,big_array,(uintptr_t)matrix,&r,&options);CHECK(v->partial && v->count==256 && !strcmp(v->reason,"JaiValueRowLimit") && v->rows[3].bits==7);
    printf("{\"rows\":%u,\"allocated_bytes\":%zu,\"rss_before\":%lu,\"rss_after\":%lu}\n",v->count,sizeof *v+v->capacity*sizeof *v->rows,rss_before,current_rss());xjai_values_free(v);
    r.reads=512;r.bytes=0;v=read_value(g,string_type,(uintptr_t)&text,&r,NULL);CHECK(v->partial && !strcmp(v->rows[0].reason,"JaiValueReadBudget") && !v->rows[0].has_bits);xjai_values_free(v);
    r.reads=r.bytes=0;v=read_value(g,string_type,UINT64_MAX-7,&r,NULL);CHECK(v->partial && r.reads==0 && !strcmp(v->rows[0].reason,"JaiValueAddressInvalid"));xjai_values_free(v);
    /* Live ownership oracle: target is our child, actually ptrace-stopped. */
    pid_t parent=getpid();pid=fork();CHECK(pid>=0);
    if (!pid) {CHECK(!prctl(PR_SET_PDEATHSIG,SIGKILL) && getppid()==parent);CHECK(!ptrace(PTRACE_TRACEME,0,0,0));raise(SIGSTOP);_exit(0);}
    int status;CHECK(waitpid(pid,&status,0)==pid && WIFSTOPPED(status));r.reads=r.bytes=0;
    v=read_value(g,object_type,(uintptr_t)&object,&r,NULL);CHECK(!v->partial && v->rows[2].bits==(uint64_t)(int64_t)-42 && v->rows[3].bits==UINT64_C(0x4029000000000000));xjai_values_free(v);
    CHECK(!ptrace(PTRACE_CONT,pid,0,0));CHECK(waitpid(pid,&status,0)==pid && WIFEXITED(status) && WEXITSTATUS(status)==0);
    r.reads=r.bytes=0;v=read_value(g,object_type,(uintptr_t)&object,&r,NULL);CHECK(v->partial && !strcmp(v->rows[2].reason,"JaiValueUnreadable") && !v->rows[2].has_bits);xjai_values_free(v);
    xjai_graph_free(g);puts("Jai values: owned stopped child, exact bits/offsets, pages, cycles, Type fields, bytes, budgets and gone target PASS");return 0;
}

#ifndef JAI_VALUE_NO_MAIN
int main(int argc,char **argv) {return xjai_value_fixture_main(argc,argv);}
#endif
