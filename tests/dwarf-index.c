#define _GNU_SOURCE 1
#include "../src/debug/dwarf_index.h"
#include <assert.h>
#include <dwarf.h>
#include <elfutils/libdw.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
struct oracle {Dwarf *dwarf;uint64_t offsets[8192];size_t count;const char *name;};
static void walk(struct oracle *o,Dwarf_Die *die,unsigned depth) {
    assert(depth<128);Dwarf_Attribute a;const char *name=dwarf_attr(die,DW_AT_name,&a)?dwarf_formstring(&a):NULL;
    if(name&&!strcmp(name,o->name)){assert(o->count<8192);o->offsets[o->count++]=dwarf_dieoffset(die);}
    Dwarf_Die child;int rc=dwarf_child(die,&child);assert(rc>=0);
    if(!rc)do {walk(o,&child,depth+1);}while((rc=dwarf_siblingof(&child,&child))==0);
    assert(rc>=0);
}
static int cancelled(void *p) {return *(int *)p;}
static size_t query(struct xdi_index *index,struct xbo_object *object,Dwarf *dwarf,const char *name) {
    struct oracle expected={.dwarf=dwarf,.name=name};Dwarf_Off at=0,next;size_t header;
    while(!dwarf_nextcu(dwarf,at,&next,&header,NULL,NULL,NULL)) {Dwarf_Die root;assert(dwarf_offdie(dwarf,at+header,&root));walk(&expected,&root,0);at=next;}
    struct xdi_query *q;assert(xdi_query(index,name,&q)==XBO_OK);size_t count=0;unsigned seen[8192]={0};
    for(;;) {
        struct xbo_budget budget={.bytes_left=13,.reads_left=1,.deadline_ns=xbo_now_ns()+100000000};struct xdn_hit hit;
        enum xbo_status s=xdi_next(q,&budget,1,&hit);
        assert(!budget.bytes_read);
        if(s==XBO_NOT_FOUND)break;
        if(s==XBO_AGAIN)continue;
        assert(s==XBO_OK&&hit.has_die);Dwarf_Die die;assert(dwarf_offdie(dwarf,hit.die,&die));
        assert((unsigned)dwarf_tag(&die)==hit.tag);assert(!strcmp(dwarf_diename(&die),name));
        size_t k=0;while(k<expected.count&&expected.offsets[k]!=hit.die)k++;assert(k<expected.count&&!seen[k]);seen[k]=1;count++;
    }
    assert(count==expected.count);xdi_query_destroy(q);(void)object;return count;
}
int main(int argc,char **argv) {
    assert(argc==3);int fd=open(argv[1],O_RDONLY|O_CLOEXEC|O_NONBLOCK);assert(fd>=0);
    int cache_fd=open(argv[2],O_CREAT|O_EXCL|O_RDWR|O_CLOEXEC,0600);assert(cache_fd>=0);
    struct xbo_local local={fd};struct xbo_source source=xbo_local_source(&local);struct xbo_object *object;
    assert(xbo_create(&source,&object)==XBO_OK);struct xbo_budget b={.bytes_left=1048576,.reads_left=65536};assert(xbo_prepare(object,&b)==XBO_OK);
    struct xdi_index *index;assert(xdi_open(object,cache_fd,4096+65536*16+80,&index)==XBO_OK);
    int cancel=1;b=(struct xbo_budget){.bytes_left=100,.reads_left=1,.context=&cancel,.cancelled=cancelled};
    assert(xdi_build(index,&b,100)==XBO_CANCELLED);assert(!b.bytes_read);
    b=(struct xbo_budget){.bytes_left=100,.reads_left=1,.deadline_ns=1};assert(xdi_build(index,&b,100)==XBO_AGAIN);
    struct xdi_query *q;assert(xdi_query(index,"Record",&q)==XBO_AGAIN);
    int locked=open(argv[2],O_RDONLY|O_CLOEXEC);assert(locked>=0);struct xdi_index *blocked;
    assert(xdi_open(object,locked,64*1024*1024,&blocked)==XBO_AGAIN);close(locked);
    char *partial;assert(asprintf(&partial,"%s.partial",argv[2])>0);
    int incomplete=open(partial,O_CREAT|O_EXCL|O_RDWR|O_CLOEXEC,0600);free(partial);assert(incomplete>=0);
    assert(xdi_open(object,incomplete,64*1024*1024,&blocked)==XBO_OK);xdi_destroy(blocked);
    assert(xdi_open(object,incomplete,64*1024*1024,&blocked)==XBO_AGAIN);close(incomplete);

    uint64_t slices=0,bytes=0;int quota=0;
    for(;;) {
        b=(struct xbo_budget){.bytes_left=97,.reads_left=3,.deadline_ns=xbo_now_ns()+100000000};
        enum xbo_status s=xdi_build(index,&b,7);bytes+=b.bytes_read;slices++;
        if(s==XBO_LIMIT&&!quota) {
            assert(!strcmp(xdi_error(index),"DwarfIndexFileLimit"));
            assert(xdi_set_file_limit(index,64*1024*1024)==XBO_OK);quota=1;continue;
        }
        if(s!=XBO_OK&&s!=XBO_AGAIN){fprintf(stderr,"refused %s %s\n",xbo_status_name(s),xdi_error(index));return 2;}
        assert(slices<1000000);if(s==XBO_OK)break;
    }
    struct xdi_progress p;xdi_progress(index,&p);assert(p.complete&&quota);
    assert(xdi_set_file_limit(index,UINT64_MAX)==XBO_LIMIT);
    Dwarf *dwarf=dwarf_begin(fd,DWARF_C_READ);assert(dwarf);
    size_t count=query(index,object,dwarf,"Record");assert(count==2);
    assert(query(index,object,dwarf,"calculate")==1);assert(query(index,object,dwarf,"Missing")==0);
    int second=open(argv[2],O_RDONLY|O_CLOEXEC);assert(second>=0);struct xdi_index *other;
    assert(xdi_open(object,second,64*1024*1024,&other)==XBO_OK);
    assert(query(other,object,dwarf,"Record")==count);xdi_destroy(other);close(second);
    printf("built: records=%"PRIu64" file=%"PRIu64" memory=%"PRIu64" slices=%"PRIu64" bytes=%"PRIu64"\n",p.records,p.file_bytes,p.memory_bytes,slices,bytes);
    xdi_destroy(index);assert(xdi_open(object,cache_fd,64*1024*1024,&index)==XBO_OK);
    assert(query(index,object,dwarf,"Record")==count);assert(query(index,object,dwarf,"calculate")==1);
    // Cached records are checked before their contents can be returned.
    struct stat st;assert(!fstat(cache_fd,&st));unsigned char byte;
    uint32_t hash=5381;for(const char *s="Record";*s;s++)hash=hash*33+(unsigned char)*s;
    uint64_t bucket=4096+(hash%65536)*16;assert(pread(cache_fd,&byte,1,(off_t)bucket)==1);byte^=1;assert(pwrite(cache_fd,&byte,1,(off_t)bucket)==1);
    assert(xdi_query(index,"Record",&q)==XBO_MALFORMED);assert(!strcmp(xdi_error(index),"DwarfCacheBucketChecksum"));
    byte^=1;assert(pwrite(cache_fd,&byte,1,(off_t)bucket)==1);assert(query(index,object,dwarf,"Record")==count);
    unsigned char link[8];assert(pread(cache_fd,link,8,(off_t)bucket)==8);uint64_t record=0;
    for(unsigned k=0;k<8;k++)record|=(uint64_t)link[k]<<(8*k);
    assert(pread(cache_fd,&byte,1,(off_t)record+24)==1);byte^=1;assert(pwrite(cache_fd,&byte,1,(off_t)record+24)==1);
    assert(xdi_query(index,"Record",&q)==XBO_OK);b=(struct xbo_budget){.bytes_left=100,.reads_left=3};struct xdn_hit malformed;
    assert(xdi_next(q,&b,10,&malformed)==XBO_MALFORMED);assert(!strcmp(xdi_error(index),"DwarfCacheRecordChecksum"));xdi_query_destroy(q);
    byte^=1;assert(pwrite(cache_fd,&byte,1,(off_t)record+24)==1);
    assert(pread(cache_fd,&byte,1,(off_t)record+48)==1);byte^=1;assert(pwrite(cache_fd,&byte,1,(off_t)record+48)==1);
    assert(xdi_query(index,"Record",&q)==XBO_OK);assert(xdi_next(q,&b,10,&malformed)==XBO_MALFORMED);
    assert(!strcmp(xdi_error(index),"DwarfCacheNameChecksum"));xdi_query_destroy(q);byte^=1;assert(pwrite(cache_fd,&byte,1,(off_t)record+48)==1);
    // A projected index records its exact name list and refuses outside queries.
    char *filtered_path;assert(asprintf(&filtered_path,"%s.filtered",argv[2])>0);
    int filtered=open(filtered_path,O_CREAT|O_EXCL|O_RDWR|O_CLOEXEC,0600);free(filtered_path);assert(filtered>=0);
    const char *names[]={"Record","calculate","value"};struct xdi_index *projection;
    assert(xdi_open_names(object,filtered,64*1024*1024,names,3,&projection)==XBO_OK);
    for(;;) {
        b=(struct xbo_budget){.bytes_left=97,.reads_left=3};
        enum xbo_status status=xdi_build(projection,&b,7);
        assert(status==XBO_OK||status==XBO_AGAIN);if(status==XBO_OK)break;
    }
    assert(query(projection,object,dwarf,"Record")==count);
    assert(query(projection,object,dwarf,"calculate")==1);
    (void)query(projection,object,dwarf,"value");
    assert(xdi_query(projection,"Missing",&q)==XBO_LIMIT);
    xdi_destroy(projection);
    assert(xdi_open(object,filtered,64*1024*1024,&projection)==XBO_CHANGED);
    assert(xdi_open_names(object,filtered,64*1024*1024,names,2,&projection)==XBO_CHANGED);
    assert(xdi_open_names(object,filtered,64*1024*1024,names,3,&projection)==XBO_OK);
    assert(query(projection,object,dwarf,"Record")==count);xdi_destroy(projection);close(filtered);
    // A retained query also refuses changed source identity.
    assert(xdi_query(index,"Record",&q)==XBO_OK);assert(!fstat(fd,&st));struct timespec times[2]={st.st_atim,st.st_mtim};
    if(++times[1].tv_nsec==1000000000){times[1].tv_nsec=0;times[1].tv_sec++;}assert(!futimens(fd,times));
    b=(struct xbo_budget){.bytes_left=100,.reads_left=3};struct xdn_hit hit;assert(xdi_next(q,&b,3,&hit)==XBO_CHANGED);
    xdi_query_destroy(q);xdi_destroy(index);dwarf_end(dwarf);xbo_destroy(object);close(fd);close(cache_fd);
    puts("persistent direct-name index matches libdw before and after reopen; corruption and source changes refused");return 0;
}
