#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "dwarf_index.h"
#include "../binary/cache_io.h"
#include <dwarf.h>
#include <errno.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/stat.h>

#define HEADER 4096u
#define BUCKETS 65536u
#define LINK 16u
#define START (HEADER+BUCKETS*LINK)
#define NAME 65536u
#define RECORD 48u
#define BUFFER 65536u
#define MAX_FILE INT64_MAX
struct xdi_index {
    struct xbo_object *object;
    struct xdw_cursor *cursor;
    struct xbo_budget *budget;
    int fd,complete,failed;
    uint64_t file_limit,end,records;
    unsigned char header[HEADER];
    uint64_t heads[BUCKETS];
    unsigned char buffer[BUFFER];
    size_t buffered;
    uint32_t final_bucket;
    char name[NAME];
    size_t filter_count;
    const char *filter[64];
    const char *error;
};
struct xdi_query {struct xdi_index *index;uint64_t at;uint32_t hash;size_t size;char name[NAME];};
#define TRY(e) do {enum xbo_status s_=(e);if(s_!=XBO_OK)return s_;} while(0)
static enum xbo_status bad(struct xdi_index *i,const char *why) {i->error=why;return XBO_MALFORMED;}
static uint32_t hash(const char *s) {uint32_t h=5381;while(*s)h=h*33+(unsigned char)*s++;return h;}
static enum xbo_status tick(struct xbo_budget *b) {
    if(!b)return XBO_LIMIT;
    if(b->cancelled&&b->cancelled(b->context))return XBO_CANCELLED;
    if(b->deadline_ns&&xbo_now_ns()>=b->deadline_ns)return XBO_AGAIN;
    return XBO_OK;
}
static int indexed(unsigned tag) {
    switch(tag) {
    case DW_TAG_class_type:case DW_TAG_structure_type:case DW_TAG_union_type:
    case DW_TAG_enumeration_type:case DW_TAG_typedef:case DW_TAG_base_type:
    case DW_TAG_subprogram:case DW_TAG_namespace:case DW_TAG_variable:
    case DW_TAG_constant:case DW_TAG_enumerator:case DW_TAG_member:
    case DW_TAG_compile_unit:case DW_TAG_partial_unit:return 1;
    default:return 0;
    }
}
static int selected(const struct xdi_index *i, const char *name) {
    if (!i->filter_count) return 1;
    for (size_t n = 0; n < i->filter_count; ++n) if (!strcmp(name, i->filter[n])) return 1;
    return 0;
}
static enum xbo_status flush(struct xdi_index *i) {
    if(i->buffered&&xc_io(i->fd,i->buffer,i->buffered,i->end-i->buffered,1))return XBO_IO;
    i->buffered=0;return XBO_OK;
}
static enum xbo_status append(struct xdi_index *i,const unsigned char *data,size_t size) {
    while(size) {
        size_t n=BUFFER-i->buffered;if(n>size)n=size;
        memcpy(i->buffer+i->buffered,data,n);i->buffered+=n;i->end+=n;data+=n;size-=n;
        if(i->buffered==BUFFER)TRY(flush(i));
    }return XBO_OK;
}
static enum xbo_status add(void *ctx,const struct xdw_die *die,enum xdw_action *action) {
    struct xdi_index *i=ctx;(void)action;
    if(!indexed(die->tag))return XBO_OK;
    enum xbo_status status=xdw_name(i->cursor,die,i->name,sizeof i->name,i->budget);
    if(status==XBO_NOT_FOUND)return XBO_OK;
    if(status!=XBO_OK)return status;
    if(!selected(i,i->name))return XBO_OK;
    size_t size=strlen(i->name)+1;
    if(size==1)return XBO_OK;
    if(RECORD+size>i->file_limit-i->end){i->error="DwarfIndexFileLimit";return XBO_LIMIT;}
    uint32_t h=hash(i->name);uint64_t previous=i->heads[h%BUCKETS];
    unsigned char record[RECORD]={0};
    xc_put(record,previous,8);xc_put(record+8,die->unit,8);xc_put(record+16,die->offset,8);
    xc_put(record+24,die->tag,4);xc_put(record+28,h,4);xc_put(record+32,size,4);
    xc_put(record+36,xc_checksum((unsigned char *)i->name,size),4);xc_put(record+44,xc_checksum(record,44),4);
    uint64_t offset=i->end;
    TRY(append(i,record,sizeof record));TRY(append(i,(unsigned char *)i->name,size));
    i->heads[h%BUCKETS]=offset;i->records++;return XBO_OK;
}
enum xbo_status xdi_open(struct xbo_object *object,int fd,uint64_t file_limit,struct xdi_index **out) {
    return xdi_open_names(object,fd,file_limit,NULL,0,out);
}
enum xbo_status xdi_open_names(struct xbo_object *object,int fd,uint64_t file_limit,
        const char *const *names,size_t count,struct xdi_index **out) {
    if(!out)return XBO_MALFORMED;
    *out=NULL;
    if(!object || count>64 || (count && !names))return XBO_MALFORMED;
    size_t filter_bytes=0;
    for(size_t n=0;n<count;++n) {
        if(!names[n] || !*names[n])return XBO_MALFORMED;
        size_t size=strnlen(names[n],256);
        if(size==256 || size+1>3000-filter_bytes)return XBO_LIMIT;
        filter_bytes+=size+1;
    }
    const struct xbo_identity *identity=xbo_identity(object);
    if(!identity||file_limit<START||file_limit>MAX_FILE)return XBO_LIMIT;
    struct stat st;if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=geteuid()||(st.st_mode&077)||st.st_nlink!=1)return XBO_IO;
    if(flock(fd,(st.st_size?LOCK_SH:LOCK_EX)|LOCK_NB))return errno==EWOULDBLOCK?XBO_AGAIN:XBO_IO;
    struct xdi_index *i=calloc(1,sizeof *i);if(!i){flock(fd,LOCK_UN);return XBO_NOMEM;}
    i->object=object;i->fd=fd;i->file_limit=file_limit;i->end=START;
    unsigned char *h=i->header;memcpy(h,"XODBNIDX",8);xc_put(h+8,2,4);xc_put(h+12,BUCKETS,4);
    xc_put(h+16,identity->device,8);xc_put(h+24,identity->inode,8);xc_put(h+32,identity->size,8);
    xc_put(h+40,(uint64_t)identity->mtime_sec,8);xc_put(h+48,identity->mtime_nsec,4);
    xc_put(h+56,(uint64_t)identity->ctime_sec,8);xc_put(h+64,identity->ctime_nsec,4);
    size_t id_size;const unsigned char *id=xbo_build_id(object,&id_size);
    xc_put(h+72,id_size,4);if(id_size)memcpy(h+80,id,id_size);
    xc_put(h+168,count,4);xc_put(h+172,filter_bytes,4);
    size_t filter_at=176;i->filter_count=count;
    for(size_t n=0;n<count;++n) {
        size_t size=strlen(names[n])+1;i->filter[n]=(char *)h+filter_at;
        memcpy(h+filter_at,names[n],size);filter_at+=size;
    }
    enum xbo_status status=XBO_OK;
    if(st.st_size) {
        unsigned char existing[HEADER];
        if(st.st_size<START||(uint64_t)st.st_size>file_limit||xc_io(fd,existing,sizeof existing,0,0)){status=XBO_MALFORMED;goto fail;}
        if(xc_get(existing+HEADER-4,4)!=xc_checksum(existing,HEADER-4)){status=XBO_MALFORMED;goto fail;}
        if(memcmp(existing,h,144)||memcmp(existing+168,h+168,HEADER-172)){status=XBO_CHANGED;goto fail;}
        if(xc_get(existing+144,8)!=1){status=XBO_AGAIN;goto fail;}
        i->end=xc_get(existing+152,8);i->records=xc_get(existing+160,8);
        if(i->end!=(uint64_t)st.st_size||i->end<START||i->records>(i->end-START)/(RECORD+2)){status=XBO_MALFORMED;goto fail;}
        i->complete=1;
    } else {
        xc_put(h+HEADER-4,xc_checksum(h,HEADER-4),4);
        if(ftruncate(fd,START)||xc_io(fd,h,HEADER,0,1)){status=XBO_IO;goto fail;}
        status=xdw_create(object,&i->cursor);if(status!=XBO_OK)goto fail;
    }
    *out=i;return XBO_OK;
fail:
    xdw_destroy(i->cursor);flock(fd,LOCK_UN);free(i);return status;
}
void xdi_destroy(struct xdi_index *i) {if(i){xdw_destroy(i->cursor);flock(i->fd,LOCK_UN);free(i);}}
enum xbo_status xdi_set_file_limit(struct xdi_index *i,uint64_t size) {
    if(!i)return XBO_MALFORMED;
    if(size<i->end||size>MAX_FILE)return XBO_LIMIT;
    i->file_limit=size;return XBO_OK;
}
enum xbo_status xdi_build(struct xdi_index *i,struct xbo_budget *budget,uint64_t work) {
    if(!i)return XBO_MALFORMED;
    i->error=NULL;TRY(xbo_validate(i->object,budget));if(i->complete)return XBO_OK;
    if(i->failed)return XBO_IO;
    i->budget=budget;enum xbo_status status=xdw_walk(i->cursor,budget,work,add,i);i->budget=NULL;
    if(status!=XBO_OK){if(status==XBO_IO)i->failed=1;if(!i->error)i->error=xdw_error(i->cursor);return status;}
    struct xdw_progress p;xdw_progress(i->cursor,&p);if(!p.complete)return XBO_AGAIN;
    TRY(xbo_validate(i->object,budget));
    TRY(flush(i));
    /* Bucket publication is resumable too. The completion header is written
     * only after all records and bucket checksums are present. */
    while(i->final_bucket<BUCKETS) {
        TRY(tick(budget));unsigned char links[BUFFER];size_t n=0;
        uint32_t start=i->final_bucket;
        while(start+n/LINK<BUCKETS&&n+LINK<=sizeof links) {
            uint64_t head=i->heads[start+n/LINK];memset(links+n,0,LINK);
            if(head){xc_put(links+n,head,8);xc_put(links+n+8,xc_checksum(links+n,8),4);}
            n+=LINK;
        }
        if(xc_io(i->fd,links,n,HEADER+(uint64_t)start*LINK,1))return XBO_IO;
        i->final_bucket+=(uint32_t)(n/LINK);
    }
    TRY(xbo_validate(i->object,budget));
    xc_put(i->header+144,1,8);xc_put(i->header+152,i->end,8);xc_put(i->header+160,i->records,8);
    xc_put(i->header+HEADER-4,xc_checksum(i->header,HEADER-4),4);
    if(xc_io(i->fd,i->header,HEADER,0,1))return XBO_IO;
    i->complete=1;
    if(flock(i->fd,LOCK_SH|LOCK_NB))return XBO_IO;
    return XBO_OK;
}
void xdi_progress(const struct xdi_index *i,struct xdi_progress *p) {
    if(!p)return;
    memset(p,0,sizeof *p);if(!i)return;
    struct xdw_progress c={0};if(i->cursor)xdw_progress(i->cursor,&c);
    *p=(struct xdi_progress){.units=c.units,.dies=c.dies,.info_next=c.next,.info_size=c.info_size,
        .records=i->records,.file_bytes=i->end,.memory_bytes=sizeof *i+c.memory_bytes,.complete=i->complete};
}
enum xbo_status xdi_query(struct xdi_index *i,const char *name,struct xdi_query **out) {
    if(!out)return XBO_MALFORMED;
    *out=NULL;if(!i||!name||!*name)return XBO_MALFORMED;
    if(!i->complete)return XBO_AGAIN;
    if(!selected(i,name))return XBO_LIMIT;
    size_t size=strnlen(name,NAME);if(size==NAME)return XBO_LIMIT;
    struct xdi_query *q=calloc(1,sizeof *q);if(!q)return XBO_NOMEM;
    q->index=i;q->hash=hash(name);q->size=size+1;memcpy(q->name,name,q->size);
    unsigned char link[LINK];if(xc_io(i->fd,link,LINK,HEADER+(q->hash%BUCKETS)*LINK,0)){free(q);return XBO_IO;}
    q->at=xc_get(link,8);
    if((q->at||xc_get(link+8,8))&&(xc_get(link+8,4)!=xc_checksum(link,8)||xc_get(link+12,4))){free(q);return bad(i,"DwarfCacheBucketChecksum");}
    *out=q;return XBO_OK;
}
void xdi_query_destroy(struct xdi_query *q) {free(q);}
enum xbo_status xdi_next(struct xdi_query *q,struct xbo_budget *budget,uint64_t work,struct xdn_hit *out) {
    if(!q||!out)return XBO_MALFORMED;
    struct xdi_index *i=q->index;i->error=NULL;TRY(xbo_validate(i->object,budget));
    while(q->at) {
        TRY(tick(budget));if(!work--)return XBO_AGAIN;
        if(q->at<START||q->at>i->end||RECORD>i->end-q->at)return bad(i,"DwarfCacheRecordExtent");
        unsigned char rec[RECORD];if(xc_io(i->fd,rec,sizeof rec,q->at,0))return XBO_IO;
        if(xc_checksum(rec,44)!=xc_get(rec+44,4))return bad(i,"DwarfCacheRecordChecksum");
        uint64_t next=xc_get(rec,8),unit=xc_get(rec+8,8),die=xc_get(rec+16,8);
        uint32_t tag=(uint32_t)xc_get(rec+24,4),h=(uint32_t)xc_get(rec+28,4),size=(uint32_t)xc_get(rec+32,4);
        if((next&&(next<START||next>=q->at))||size<2||size>NAME||size>i->end-q->at-RECORD||!indexed(tag)||unit>=die)return bad(i,"DwarfCacheRecordInvalid");
        if(h%BUCKETS!=q->hash%BUCKETS)return bad(i,"DwarfCacheBucketInvalid");
        if(h==q->hash&&size==q->size) {
            if(xc_io(i->fd,i->name,size,q->at+RECORD,0))return XBO_IO;
            if(xc_checksum((unsigned char *)i->name,size)!=xc_get(rec+36,4))return bad(i,"DwarfCacheNameChecksum");
            if(!memcmp(i->name,q->name,size)) {
                TRY(xbo_validate(i->object,budget));q->at=next;
                *out=(struct xdn_hit){.unit=unit,.die=die,.tag=tag,.has_die=1};return XBO_OK;
            }
        }
        q->at=next;
    }return XBO_NOT_FOUND;
}
const char *xdi_error(const struct xdi_index *i) {return i?i->error:"DwarfIndexUnavailable";}
