/* Owned portable demo. The same native sizeof/offsetof oracle builds as ELF/PE. */
#define JAI_READER_NO_MAIN
#define JAI_FIXTURE_ALIGN 4096
#include "jai-reader.c"
#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <sys/prctl.h>
#include <unistd.h>
#endif
struct entity_base { uint64_t entity_type; };
struct entity { struct entity_base base;int64_t health; };
struct entity_area { struct entity first;uint64_t unrelated;struct entity last; };
struct bucket { unsigned char occupied[4];struct entity data[4];int64_t count; };
struct dynamic_array { int64_t count;uint64_t data;int64_t allocated;uint64_t allocator[2]; };
static struct entity_area area;
static struct bucket bucket;
static int64_t numbers[]={1111,1112,1113,1114,1115,1116};
static struct dynamic_array dynamic;
__attribute__((noinline)) void demo_changed(void) { __asm__ volatile("" ::: "memory"); }
static void readonly_metadata(void)
{
#ifdef _WIN32
    DWORD old;CHECK(VirtualProtect(arena,sizeof arena,PAGE_READONLY,&old));
#else
    CHECK(sysconf(_SC_PAGESIZE)==4096 && !mprotect(arena,sizeof arena,PROT_READ));
    /* Only the test parent and its debugger descendants may attach under Yama. */
    CHECK(!prctl(PR_SET_PTRACER,(unsigned long)getppid(),0,0,0));
#endif
}
int main(int argc,char **argv)
{
    CHECK(argc==2 && sizeof(void *)==8);
    origin=(uint64_t)(uintptr_t)arena;struct xjai_region region;graph_fixture(&region);
    uint64_t s64=type(0,8,24),meta=type(13,8,16),flag=type(2,1,16);put(s64+16,1,1);
    uint64_t bm,em,base=make_struct("FixtureEntityBase",sizeof(struct entity_base),1,&bm);
    field(bm,0,"entity_type",meta,offsetof(struct entity_base,entity_type),0);
    uint64_t entity=make_struct("FixtureEntity",sizeof(struct entity),2,&em);
    field(em,0,"base",base,offsetof(struct entity,base),20);field(em,1,"health",s64,offsetof(struct entity,health),0);
    uint64_t flags=type(8,4,40),data=type(8,sizeof bucket.data,40);
    put(flags+16,flag,8);put(flags+24,0,4);put(flags+32,4,8);
    put(data+16,entity,8);put(data+24,0,4);put(data+32,4,8);
    uint64_t members,bt=make_struct("Bucket",sizeof bucket,3,&members);(void)bt;
    field(members,0,"occupied",flags,offsetof(struct bucket,occupied),0);
    field(members,1,"data",data,offsetof(struct bucket,data),0);
    field(members,2,"count",s64,offsetof(struct bucket,count),0);
    uint64_t array=type(8,sizeof dynamic,40);put(array+16,s64,8);put(array+24,2,4);put(array+32,UINT64_MAX,8);
    uint64_t roots=make_struct("FixtureDemoRoots",sizeof dynamic,1,&members);(void)roots;
    field(members,0,"numbers",array,0,0);
    area=(struct entity_area){{{entity},77},entity,{{entity},99}};
    bucket.occupied[1]=bucket.occupied[3]=1;bucket.count=2;bucket.data[1]=area.first;bucket.data[3]=area.last;
    dynamic=(struct dynamic_array){6,(uintptr_t)numbers,6,{UINT64_MAX,UINT64_MAX}};
    readonly_metadata();FILE *f=fopen(argv[1],"w");CHECK(f);
    CHECK(fprintf(f,"{\"base\":\"0x%llx\",\"size\":%zu,\"area\":\"0x%llx\",\"area_size\":%zu,\"first\":\"0x%llx\",\"last\":\"0x%llx\",\"unrelated\":\"0x%llx\",\"entity_type\":\"0x%llx\",\"entity_size\":%zu,\"health_offset\":%zu,\"health\":%lld,\"bucket\":\"0x%llx\",\"bucket_items\":[\"0x%llx\",\"0x%llx\"],\"dynamic\":\"0x%llx\",\"dynamic_type\":\"0x%llx\",\"changed\":\"0x%llx\"}\n",
        (unsigned long long)origin,used,(unsigned long long)(uintptr_t)&area,sizeof area,
        (unsigned long long)(uintptr_t)&area.first,(unsigned long long)(uintptr_t)&area.last,(unsigned long long)(uintptr_t)&area.unrelated,
        (unsigned long long)entity,sizeof(struct entity),offsetof(struct entity,health),(long long)area.first.health,
        (unsigned long long)(uintptr_t)&bucket,(unsigned long long)(uintptr_t)&bucket.data[1],(unsigned long long)(uintptr_t)&bucket.data[3],
        (unsigned long long)(uintptr_t)&dynamic,(unsigned long long)array,(unsigned long long)(uintptr_t)demo_changed)>0);
    CHECK(!fclose(f));puts("ready");CHECK(!fflush(stdout));
    CHECK(getchar()=='c');CHECK(area.first.health==77);area.first.health=78;demo_changed();return 0;
}
