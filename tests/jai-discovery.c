/* Owned live container/search fixture, with read-only synthetic metadata. */
#define JAI_CONTAINER_NO_MAIN
#define JAI_FIXTURE_ALIGN 4096
#include "jai-container.c"
#include <sys/mman.h>
static struct { struct typed_child first;uint64_t unrelated_word;struct typed_child last; } area;
static struct bucket_value bucket,bad_bucket;
static struct dynamic_value dynamic;
static int64_t numbers[]={11,22,33,44};
static struct offset_value offset;
static struct typed_child many[70];
static int64_t many_numbers[70];
static struct dynamic_value many_dynamic;
__attribute__((noinline)) void discovery_ready(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void discovery_changed(void) { __asm__ volatile("" ::: "memory"); }
int main(int argc,char **argv)
{
    CHECK(argc==2 && sysconf(_SC_PAGESIZE)==4096);
    struct xjai_region region;container_fixture(&region);
    area.first=(struct typed_child){{typed_child_type},22};area.last=(struct typed_child){{typed_child_type},44};
    area.unrelated_word=typed_child_type; /* A matching word is not proof of an object. */
    bucket=(struct bucket_value){.count=2,.occupied={0,1,0,1}};bucket.data[1]=area.first;bucket.data[3]=area.last;
    bad_bucket=bucket;bad_bucket.count=3;
    dynamic=(struct dynamic_value){3,(uintptr_t)numbers,4,{UINT64_MAX,UINT64_MAX}};
    offset=(struct offset_value){17,offset_type};
    for (unsigned i=0;i<70;++i) {many[i]=(struct typed_child){{typed_child_type},10+i};many_numbers[i]=1111+i;}
    many_dynamic=(struct dynamic_value){70,(uintptr_t)many_numbers,70,{0,0}};
    const size_t slow_size=1024u*1024u*1024u;
    void *slow=mmap(NULL,slow_size,PROT_READ,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);CHECK(slow!=MAP_FAILED);
    unsigned char *holes=mmap(NULL,3*4096,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);CHECK(holes!=MAP_FAILED);
    memcpy(holes,&typed_child_type,8);memcpy(holes+2*4096,&typed_child_type,8);CHECK(!munmap(holes+4096,4096));
    FILE *f=fopen(argv[1],"w");CHECK(f);
    CHECK(fprintf(f,"{\"base\":\"0x%llx\",\"size\":%zu,\"area\":\"0x%llx\",\"area_size\":%zu,\"candidates\":[\"0x%llx\",\"0x%llx\",\"0x%llx\"],\"bucket\":\"0x%llx\",\"bad_bucket\":\"0x%llx\",\"bucket_items\":[\"0x%llx\",\"0x%llx\"],\"dynamic\":\"0x%llx\",\"dynamic_type\":\"0x%llx\",\"numbers\":\"0x%llx\",\"offset\":\"0x%llx\",\"offset_size\":%zu,\"slow\":\"0x%llx\",\"slow_size\":%zu,\"holes\":\"0x%llx\",\"many\":\"0x%llx\",\"many_size\":%zu,\"many_dynamic\":\"0x%llx\"}\n",
        (unsigned long long)origin,used,(unsigned long long)(uintptr_t)&area,sizeof area,
        (unsigned long long)(uintptr_t)&area.first,(unsigned long long)(uintptr_t)&area.unrelated_word,(unsigned long long)(uintptr_t)&area.last,
        (unsigned long long)(uintptr_t)&bucket,(unsigned long long)(uintptr_t)&bad_bucket,
        (unsigned long long)(uintptr_t)&bucket.data[1],(unsigned long long)(uintptr_t)&bucket.data[3],
        (unsigned long long)(uintptr_t)&dynamic,(unsigned long long)dynamic_type,(unsigned long long)(uintptr_t)numbers,
        (unsigned long long)(uintptr_t)&offset,sizeof offset,(unsigned long long)(uintptr_t)slow,slow_size,(unsigned long long)(uintptr_t)holes,(unsigned long long)(uintptr_t)many,sizeof many,(unsigned long long)(uintptr_t)&many_dynamic)>0);
    CHECK(!fclose(f) && !mprotect(arena,sizeof arena,PROT_READ));
    discovery_ready();area.first.health=23;bucket.count=1;bucket.occupied[3]=0;discovery_changed();CHECK(!munmap(slow,slow_size) && !munmap(holes,3*4096));return 0;
}
