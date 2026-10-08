#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "object_cache.h"
#include "cache_io.h"
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__x86_64__) && (defined(__GNUC__) || defined(__clang__))
#include <nmmintrin.h>
#endif

#define BLOCK 16384u
#define HEADER 512u
#define RECORD 16u
#define FILE_LIMIT INT64_MAX
enum xbo_status xbc_extent(uint64_t size, uint64_t *out) {
    if (!out || !size) return XBO_MALFORMED;
    *out = 0;
    if (size > FILE_LIMIT) return XBO_LIMIT;
    uint64_t metadata = HEADER + ((size + BLOCK - 1) / BLOCK) * RECORD;
    if (size > FILE_LIMIT - metadata) return XBO_LIMIT;
    *out = size + metadata;
    return XBO_OK;
}
struct xbc_cache {
    struct xbo_source source;
    struct xbo_identity identity;
    struct xbc_progress progress;
    int fd,changed;
    uint64_t blocks,data,extent;
    unsigned char scratch[BLOCK];
};
static int same(const struct xbo_identity *a,const struct xbo_identity *b) {
    return a->device==b->device&&a->inode==b->inode&&a->size==b->size&&
        a->mtime_sec==b->mtime_sec&&a->mtime_nsec==b->mtime_nsec&&
        a->ctime_sec==b->ctime_sec&&a->ctime_nsec==b->ctime_nsec;
}
static enum xbo_status identity(void *ctx,struct xbo_identity *out) {
    struct xbc_cache *c=ctx;if(c->changed)return XBO_CHANGED;
    enum xbo_status status=c->source.identity(c->source.context,out);
    if(status!=XBO_OK){if(status==XBO_CHANGED)c->changed=1;return status;}
    if(!same(&c->identity,out)){c->changed=1;return XBO_CHANGED;}
    return XBO_OK;
}
static uint32_t block_size(const struct xbc_cache *c,uint64_t block) {
    uint64_t size=c->identity.size-block*BLOCK;return (uint32_t)(size<BLOCK?size:BLOCK);
}
static int range(struct xbc_cache *c,uint64_t block,uint32_t *low,uint32_t *high) {
    unsigned char rec[RECORD];uint64_t at=HEADER+block*RECORD;
    if(xc_io(c->fd,rec,sizeof rec,at,0))return -1;
    *low=(uint32_t)xc_get(rec,4);*high=(uint32_t)xc_get(rec+4,4);
    if(!*high&&!*low&&!xc_get(rec+8,8))return 0;
    if(*low>=*high||*high>block_size(c,block)||xc_get(rec+12,4))goto corrupt;
    if(xc_io(c->fd,c->scratch,*high-*low,c->data+block*BLOCK+*low,0))return -1;
    if(xc_checksum(c->scratch,*high-*low)!=(uint32_t)xc_get(rec+8,4))goto corrupt;
    return 1;
corrupt:
    c->progress.corrupt_ranges++;*low=*high=0;memset(rec,0,sizeof rec);
    return xc_io(c->fd,rec,sizeof rec,at,1)?-1:0;
}
static int store(struct xbc_cache *c,uint64_t block,uint32_t start,const unsigned char *data,uint32_t size) {
    uint32_t low,high;int valid=range(c,block,&low,&high);if(valid<0)return -1;
    uint32_t end=start+size;
    if(valid&&start>=low&&end<=high)return 0;
    /* One contiguous interval per block. Disjoint reads keep the larger
     * interval; no unobserved gap is ever marked present. */
    uint32_t first=start,last=end;
    if(valid&&end>=low&&start<=high) {
        memmove(c->scratch+low-(start<low?start:low),c->scratch,high-low);
        first=start<low?start:low;last=end>high?end:high;
    } else if(valid&&size<high-low)return 0;
    memcpy(c->scratch+start-first,data,size);
    unsigned char empty[RECORD]={0},rec[RECORD]={0};uint64_t at=HEADER+block*RECORD;
    /* Invalidate first. A crash can leave a miss or a failed xc_checksum, never
     * a valid record pointing at a partially overwritten range. */
    if(xc_io(c->fd,empty,sizeof empty,at,1)||xc_io(c->fd,c->scratch,last-first,c->data+block*BLOCK+first,1))return -1;
    xc_put(rec,first,4);xc_put(rec+4,last,4);xc_put(rec+8,xc_checksum(c->scratch,last-first),4);
    return xc_io(c->fd,rec,sizeof rec,at,1);
}
static enum xbo_status read_source(void *ctx,uint64_t at,void *data,size_t size) {
    struct xbc_cache *c=ctx;struct xbo_identity current;
    enum xbo_status status=identity(c,&current);if(status!=XBO_OK)return status;
    if(at>c->identity.size||size>c->identity.size-at||size>65536)return XBO_MALFORMED;
    unsigned char *out=data;uint64_t pos=at;size_t left=size;int hit=1;
    while(left) {
        uint64_t block=pos/BLOCK;uint32_t start=(uint32_t)(pos%BLOCK),n=(uint32_t)(BLOCK-start);
        if(n>left)n=(uint32_t)left;
        uint32_t low,high;int valid=range(c,block,&low,&high);if(valid<0)return XBO_IO;
        if(!valid||start<low||start>high||n>high-start){hit=0;break;}
        memcpy(out,c->scratch+start-low,n);out+=n;pos+=n;left-=n;
    }
    if(hit){c->progress.cache_bytes+=size;c->progress.cache_reads++;return identity(c,&current);}
    c->progress.source_bytes+=size;c->progress.source_reads++;
    status=c->source.read(c->source.context,at,data,size);
    enum xbo_status after=identity(c,&current);if(after!=XBO_OK)return after;
    if(status!=XBO_OK)return status;
    out=data;pos=at;left=size;
    while(left) {
        uint64_t block=pos/BLOCK;uint32_t start=(uint32_t)(pos%BLOCK),n=(uint32_t)(BLOCK-start);
        if(n>left)n=(uint32_t)left;
        if(store(c,block,start,out,n))return XBO_IO;
        out+=n;pos+=n;left-=n;
    }
    return XBO_OK;
}
enum xbo_status xbc_create(const struct xbo_source *source,const struct xbo_identity *expected,
                           const unsigned char *id,size_t id_size,int fd,uint64_t file_limit,struct xbc_cache **out) {
    if(!out)return XBO_MALFORMED;
    *out=NULL;
    if(!source||!source->identity||!source->read||!expected||id_size>64||(id_size&&!id)||!expected->size)return XBO_MALFORMED;
    if(expected->size>FILE_LIMIT||file_limit>FILE_LIMIT||expected->size>file_limit)return XBO_LIMIT;
    struct stat st;
    if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=geteuid()||(st.st_mode&077)||st.st_nlink!=1)return XBO_IO;
    if(flock(fd,LOCK_EX|LOCK_NB))return errno==EWOULDBLOCK?XBO_AGAIN:XBO_IO;
    struct xbc_cache *c=calloc(1,sizeof *c);
    if(!c){flock(fd,LOCK_UN);return XBO_NOMEM;}
    c->source=*source;c->identity=*expected;c->fd=fd;c->blocks=(expected->size+BLOCK-1)/BLOCK;
    c->data=HEADER+c->blocks*RECORD;
    if(expected->size>(uint64_t)INT64_MAX-c->data){flock(fd,LOCK_UN);free(c);return XBO_LIMIT;}
    c->extent=c->data+expected->size;
    if(c->extent>file_limit){flock(fd,LOCK_UN);free(c);return XBO_LIMIT;}
    c->progress.file_limit=c->extent;c->progress.memory_bytes=sizeof *c;
    struct xbo_identity actual;enum xbo_status status=identity(c,&actual);if(status!=XBO_OK)goto fail;
    unsigned char header[HEADER]={0},previous[HEADER];
    memcpy(header,"XOBCACHE",8);xc_put(header+8,1,4);xc_put(header+12,BLOCK,4);
    xc_put(header+16,expected->device,8);xc_put(header+24,expected->inode,8);xc_put(header+32,expected->size,8);
    xc_put(header+40,(uint64_t)expected->mtime_sec,8);xc_put(header+48,expected->mtime_nsec,4);
    xc_put(header+56,(uint64_t)expected->ctime_sec,8);xc_put(header+64,expected->ctime_nsec,4);
    xc_put(header+72,id_size,4);if(id_size)memcpy(header+80,id,id_size);
    xc_put(header+144,c->data,8);xc_put(header+152,c->extent,8);xc_put(header+HEADER-4,xc_checksum(header,HEADER-4),4);
    if(!st.st_size) {
        if(ftruncate(fd,(off_t)c->extent)||xc_io(fd,header,sizeof header,0,1)){status=XBO_IO;goto fail;}
    } else {
        if((uint64_t)st.st_size!=c->extent||xc_io(fd,previous,sizeof previous,0,0)){status=XBO_MALFORMED;goto fail;}
        if(memcmp(header,previous,sizeof header)){status=XBO_CHANGED;goto fail;}
    }
    *out=c;return XBO_OK;
fail:
    flock(fd,LOCK_UN);free(c);return status;
}
void xbc_destroy(struct xbc_cache *c) {if(c){flock(c->fd,LOCK_UN);free(c);}}
struct xbo_source xbc_source(struct xbc_cache *c) {return (struct xbo_source){c,identity,read_source};}
void xbc_progress(const struct xbc_cache *c,struct xbc_progress *out) {if(out){memset(out,0,sizeof *out);if(c)*out=c->progress;}}
