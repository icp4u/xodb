#define _GNU_SOURCE 1
#include "../src/debug/dwarf_names.h"
#include <assert.h>
#include <dwarf.h>
#include <elfutils/libdw.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
static int cancelled(void *ctx) {return *(int *)ctx;}
int main(int argc,char **argv) {
    assert(argc>=3&&argc<=5);int raw=argc>3&&!strcmp(argv[3],"raw");
    uint64_t bytes_per_slice=argc>4?strtoull(argv[4],NULL,0):97;
    int fd=open(argv[1],O_RDONLY|O_CLOEXEC|O_NONBLOCK);assert(fd>=0);
    struct xbo_local local={fd};struct xbo_source source=xbo_local_source(&local);struct xbo_object *object;
    assert(xbo_create(&source,&object)==XBO_OK);
    struct xbo_budget budget={.bytes_left=1048576,.reads_left=65536};assert(xbo_prepare(object,&budget)==XBO_OK);
    struct xdn_query *q;enum xbo_status status=xdn_create(object,argv[2],&q);
    if(status!=XBO_OK){printf("create %s\n",xbo_status_name(status));xbo_destroy(object);close(fd);return 3;}
    Dwarf *dwarf=raw?NULL:dwarf_begin(fd,DWARF_C_READ);assert(raw||dwarf);
    int cancel=1;budget=(struct xbo_budget){.bytes_left=100,.reads_left=3,.cancelled=cancelled,.context=&cancel};
    struct xdn_hit hit;assert(xdn_next(q,&budget,20,&hit)==XBO_CANCELLED);assert(!budget.bytes_read);
    budget=(struct xbo_budget){.bytes_left=100,.reads_left=3,.deadline_ns=1};assert(xdn_next(q,&budget,20,&hit)==XBO_AGAIN);assert(!budget.bytes_read);
    if(argc>3&&!strcmp(argv[3],"mutate")) {
        budget=(struct xbo_budget){.bytes_left=13,.reads_left=1};
        assert(xdn_next(q,&budget,3,&hit)==XBO_AGAIN);
        struct stat st;assert(!fstat(fd,&st));struct timespec times[2]={st.st_atim,st.st_mtim};
        if(++times[1].tv_nsec==1000000000){times[1].tv_nsec=0;times[1].tv_sec++;}
        assert(!futimens(fd,times));
        budget=(struct xbo_budget){.bytes_left=10000,.reads_left=20};
        assert(xdn_next(q,&budget,100,&hit)==XBO_CHANGED);assert(!budget.bytes_read);
        assert(xdn_next(q,&budget,100,&hit)==XBO_CHANGED);
        if(dwarf)dwarf_end(dwarf);
        xdn_destroy(q);xbo_destroy(object);close(fd);puts("identity changed: retained lookup refused before further bytes");return 0;
    }
    uint64_t slices=0,bytes=0,hits=0;
    for(;;) {
        budget=(struct xbo_budget){.bytes_left=bytes_per_slice,.reads_left=5,.deadline_ns=xbo_now_ns()+UINT64_C(100000000)};
        status=xdn_next(q,&budget,3,&hit);bytes+=budget.bytes_read;slices++;
        assert(budget.bytes_read<=bytes_per_slice&&budget.reads<=5&&slices<1000000);
        if(status==XBO_OK) {
            if(!raw) {
                size_t header=0;Dwarf_Off next;
                assert(dwarf_nextcu(dwarf,hit.unit,&next,&header,NULL,NULL,NULL)==0);
                if(hit.has_die) {
                    assert(hit.die>=hit.unit+header&&hit.die<next);Dwarf_Die die;
                    assert(dwarf_offdie(dwarf,hit.die,&die));
                    assert((unsigned)dwarf_tag(&die)==hit.tag);
                    const char *name=dwarf_diename(&die);assert(name&&!strcmp(name,argv[2]));
                } else assert(hit.unit_size==next-hit.unit);
            }
            printf("hit %"PRIx64" %"PRIx64" %"PRIx64" %x %u\n",hit.unit,hit.die,hit.unit_size,hit.tag,hit.has_die);hits++;
        } else if(status==XBO_NOT_FOUND)break;
        else if(status!=XBO_AGAIN) {fprintf(stderr,"refused %s: %s\n",xbo_status_name(status),xdn_error(q));break;}
    }
    printf("status=%s kind=%u hits=%"PRIu64" slices=%"PRIu64" bytes=%"PRIu64" memory=%"PRIu64"\n",xbo_status_name(status),xdn_kind(q),hits,slices,bytes,xdn_memory_bytes(q));
    if(dwarf)dwarf_end(dwarf);
    xdn_destroy(q);xbo_destroy(object);close(fd);return status==XBO_NOT_FOUND?0:2;
}
