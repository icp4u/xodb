/* Owned live fixture. Type tables become read-only before the first marker. */
#define JAI_VALUE_NO_MAIN
#define JAI_FIXTURE_ALIGN 4096
#include "jai-value.c"
#include <sys/mman.h>
static struct object_value object;
static struct typed_child child;
static unsigned char text_bytes[]={'h','i',0,'x',255};
static struct span text_value;
__attribute__((noinline)) void runtime_ready(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void runtime_changed(void) { __asm__ volatile("" ::: "memory"); }
int main(int argc,char **argv)
{
    CHECK(argc==2 && sysconf(_SC_PAGESIZE)==4096);
    struct xjai_region region;value_fixture(&region);
    uint64_t fields;make_struct("FixtureDuplicate",8,0,&fields);make_struct("FixtureDuplicate",8,0,&fields);
    object=(struct object_value){.base={-42},.energy=12.5,.fixed={1,-2,3}};
    object.next=(uintptr_t)&object;child=(struct typed_child){{typed_child_type},99};
    text_value=(struct span){sizeof text_bytes,(uintptr_t)text_bytes};
    FILE *f=fopen(argv[1],"w");CHECK(f);
    CHECK(fprintf(f,"{\"base\":\"0x%llx\",\"size\":%zu,\"object\":\"0x%llx\",\"object_size\":%zu,\"energy_offset\":%zu,\"child\":\"0x%llx\",\"text\":\"0x%llx\",\"string_type\":\"0x%llx\"}\n",
        (unsigned long long)origin,used,(unsigned long long)(uintptr_t)&object,sizeof object,offsetof(struct object_value,energy),
        (unsigned long long)(uintptr_t)&child,(unsigned long long)(uintptr_t)&text_value,(unsigned long long)string_type)>0);
    CHECK(!fclose(f));CHECK(!mprotect(arena,sizeof arena,PROT_READ));
    runtime_ready();object.base.score=-43;child.health=100;runtime_changed();return 0;
}
