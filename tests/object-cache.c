#define _GNU_SOURCE 1
#include "../src/binary/object_cache.h"
#include <assert.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#define SIZE (4*16384+100)
#define QUOTA (SIZE+512+5*16)
struct source {struct xbo_identity identity;unsigned char bytes[SIZE];unsigned reads;int change,reported_change;};
static enum xbo_status identity(void *ctx,struct xbo_identity *out) {struct source *s=ctx;if(s->reported_change)return XBO_CHANGED;*out=s->identity;return XBO_OK;}
static enum xbo_status read_source(void *ctx,uint64_t at,void *dst,size_t size) {
    struct source *s=ctx;assert(at<=SIZE&&size<=SIZE-at);memcpy(dst,s->bytes+at,size);s->reads++;
    if(s->change)s->identity.ctime_nsec++;
    return XBO_OK;
}
static void read_check(struct source *s,struct xbo_source *cache,uint64_t at,size_t size) {
    unsigned char bytes[65536];memset(bytes,0,sizeof bytes);
    assert(cache->read(cache->context,at,bytes,size)==XBO_OK);assert(!memcmp(bytes,s->bytes+at,size));
}
int main(int argc,char **argv) {
    assert(argc==2);int fd=open(argv[1],O_CREAT|O_EXCL|O_RDWR|O_CLOEXEC,0600);assert(fd>=0);
    struct source source={.identity={.device=1,.inode=2,.size=SIZE,.mtime_sec=3,.ctime_sec=4}};
    uint32_t random=42;for(size_t i=0;i<SIZE;i++){random=random*1664525+1013904223;source.bytes[i]=(unsigned char)(random>>24);}
    struct xbo_source original={&source,identity,read_source};struct xbc_cache *cache;
    unsigned char id[]={1,2,3};
    assert(xbc_create(&original,&source.identity,id,3,fd,SIZE,&cache)==XBO_LIMIT);
    assert(xbc_create(&original,&source.identity,id,3,fd,QUOTA-1,&cache)==XBO_LIMIT);
    struct stat initial;assert(!fstat(fd,&initial) && !initial.st_size);
    assert(xbc_create(&original,&source.identity,id,3,fd,QUOTA,&cache)==XBO_OK);
    struct xbo_source cached=xbc_source(cache);
    // Random overlapping, adjacent and disjoint ranges, then repeated hits.
    for(unsigned i=0;i<2000;i++) {
        random=random*1664525+1013904223;size_t size=random%20000+1;
        random=random*1664525+1013904223;uint64_t at=random%(SIZE-size);
        read_check(&source,&cached,at,size);read_check(&source,&cached,at,size);
    }
    read_check(&source,&cached,0,65536);read_check(&source,&cached,65536,100);
    unsigned reads=source.reads;
    for(unsigned i=0;i<20;i++)read_check(&source,&cached,100,50000);
    assert(source.reads==reads);
    struct xbc_progress p;xbc_progress(cache,&p);assert(p.cache_reads>1000&&p.source_reads==source.reads);assert(!p.corrupt_ranges);
    printf("random ranges: source=%llu cached=%llu reads=%u memory=%llu\n",(unsigned long long)p.source_bytes,(unsigned long long)p.cache_bytes,source.reads,(unsigned long long)p.memory_bytes);
    int second=open(argv[1],O_RDWR|O_CLOEXEC);assert(second>=0);struct xbc_cache *other;
    assert(xbc_create(&original,&source.identity,id,3,second,QUOTA,&other)==XBO_AGAIN);close(second);
    xbc_destroy(cache);
    // Reopening the cache makes no source reads for already persisted ranges.
    assert(xbc_create(&original,&source.identity,id,3,fd,QUOTA,&cache)==XBO_OK);cached=xbc_source(cache);
    read_check(&source,&cached,100,50000);assert(source.reads==reads);
    // Corrupt a cached data byte; checksum turns it into a source-backed miss.
    unsigned char byte;uint64_t data=512+5*16;
    assert(pread(fd,&byte,1,(off_t)data+100)==1);byte^=1;assert(pwrite(fd,&byte,1,(off_t)data+100)==1);
    read_check(&source,&cached,0,16384);assert(source.reads==reads+1);
    xbc_progress(cache,&p);assert(p.corrupt_ranges==1);reads=source.reads;
    // Invalid metadata is also a miss, and never authorizes a hole.
    unsigned char corrupt[16];memset(corrupt,255,sizeof corrupt);assert(pwrite(fd,corrupt,16,512+16)==16);
    read_check(&source,&cached,16384+100,20);assert(source.reads==reads+1);
    read_check(&source,&cached,16384+400,20);assert(source.reads==reads+2);
    read_check(&source,&cached,16384,16384);reads=source.reads;
    // Source changes refuse retained hits and do not contaminate a new cache.
    source.identity.mtime_nsec++;
    unsigned char out[128];assert(cached.read(cached.context,0,out,sizeof out)==XBO_CHANGED);assert(source.reads==reads);
    xbc_destroy(cache);
    assert(xbc_create(&original,&source.identity,id,3,fd,QUOTA,&other)==XBO_CHANGED);
    source.identity.mtime_nsec--;assert(xbc_create(&original,&source.identity,id,3,fd,QUOTA,&cache)==XBO_OK);
    cached=xbc_source(cache);
    // Force a miss and change identity in the source read callback.
    memset(corrupt,0,sizeof corrupt);assert(pwrite(fd,corrupt,16,512+16*3)==16);source.change=1;
    assert(cached.read(cached.context,3*16384,out,sizeof out)==XBO_CHANGED);xbc_destroy(cache);source.change=0;source.identity.ctime_nsec--;
    assert(xbc_create(&original,&source.identity,id,3,fd,QUOTA,&cache)==XBO_OK);cached=xbc_source(cache);reads=source.reads;
    read_check(&source,&cached,3*16384,sizeof out);assert(source.reads==reads+1);xbc_destroy(cache);
    assert(xbc_create(&original,&source.identity,id,3,fd,QUOTA,&cache)==XBO_OK);cached=xbc_source(cache);
    source.reported_change=1;assert(cached.read(cached.context,0,out,sizeof out)==XBO_CHANGED);source.reported_change=0;
    assert(cached.read(cached.context,0,out,sizeof out)==XBO_CHANGED);xbc_destroy(cache);
    assert(fchmod(fd,0644)==0);assert(xbc_create(&original,&source.identity,id,3,fd,QUOTA,&cache)==XBO_IO);assert(fchmod(fd,0600)==0);
    assert(xbc_create(&original,&source.identity,id,3,fd,SIZE-1,&cache)==XBO_LIMIT);
    assert(xbc_create(&original,&source.identity,id,3,fd,UINT64_MAX,&cache)==XBO_LIMIT);
    struct xbo_identity too_big=source.identity;too_big.size=INT64_MAX;
    assert(xbc_create(&original,&too_big,id,3,fd,INT64_MAX,&cache)==XBO_LIMIT);
    assert(ftruncate(fd,700)==0);assert(xbc_create(&original,&source.identity,id,3,fd,QUOTA,&cache)==XBO_MALFORMED);
    close(fd);puts("range cache persistence, corruption, gaps, identity, permissions and lease checks passed");return 0;
}
