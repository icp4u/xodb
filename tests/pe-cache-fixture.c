#define _GNU_SOURCE 1
#include "check.h"
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

__attribute__((noinline)) int pe_cache_marker(int n) {
    __asm__ volatile("" ::: "memory");
    return n + 1;
}
static void *mapped(const char *path, size_t *size, void *address) {
    int fd=open(path,O_RDONLY|O_CLOEXEC);struct stat st;
    CHECK(fd>=0 && !fstat(fd,&st) && st.st_size>0);
    *size=(size_t)st.st_size;
    void *p=mmap(address,*size,PROT_READ|PROT_EXEC,
        MAP_PRIVATE|(address?MAP_FIXED_NOREPLACE:0),fd,0);
    CHECK(p!=MAP_FAILED);CHECK(!close(fd));return p;
}
int main(int argc,char **argv) {
    CHECK(argc>=4);
    if (!strcmp(argv[1],"hold")) {
        for (int i=2;i<argc;++i) {
            size_t size;
            mapped(argv[i],&size,(void *)(UINT64_C(0x1000000000)+(uint64_t)(i-2)*UINT64_C(0x40000000)));
        }
        return pe_cache_marker(argc)<0;
    }
    CHECK(argc==4);
    int same=!strcmp(argv[1],"same");
    CHECK(same || !strcmp(argv[1],"identity"));
    unsigned rounds=(unsigned)strtoul(argv[2],NULL,10);CHECK(rounds>0 && rounds<=2048);
    void *old=NULL;size_t old_size=0;
    for (unsigned i=0;i<rounds;++i) {
        struct timespec times[2]={{0,UTIME_OMIT},{1000000000+(time_t)i,0}};
        CHECK(!utimensat(AT_FDCWD,argv[3],times,0));
        if (!same || !old) {
            size_t size;void *p=mapped(argv[3],&size,NULL);
            if (old) CHECK(!munmap(old,old_size));
            old=p;old_size=size;
        }
        pe_cache_marker((int)i);
    }
    CHECK(!munmap(old,old_size));return 0;
}
