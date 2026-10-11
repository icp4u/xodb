#include "pdb.h"
#include <stdlib.h>
#include <string.h>
#include <limits.h>

/* Layout references: LLVM's PDB/MSF documentation and CodeView headers.
 * Decode scalars explicitly; no packed structs, casts or unaligned loads. */
struct block { void *data; size_t size; };
struct stream { uint32_t size; const unsigned char *pages; };
struct xpdb {
    struct xpdb_info info;
    struct xpdb_public *publics;
    const struct xpdb_public **by_name;
    struct xpdb_line *lines;
    struct xpdb_section sections[96];
    unsigned section_count;
    struct block symbols, names;
};
struct parser {
    const unsigned char *bytes;
    size_t size, allocated, peak;
    uint64_t work;
    uint32_t page_size, page_count, stream_count;
    struct block directory, streams, ownership;
    struct xpdb *out;
};
static uint16_t u16(const unsigned char *p) { return (uint16_t)(p[0] | (unsigned)p[1]<<8); }
static uint32_t u32(const unsigned char *p) { return (uint32_t)u16(p) | (uint32_t)u16(p+2)<<16; }
static int span(size_t at, size_t n, size_t total) { return at <= total && n <= total-at; }
static size_t pages(size_t n, size_t page) { return n/page + (n%page != 0); }
/* libc qsort may allocate a second full array outside the parser's budget.
 * Heap sort keeps both construction work and auxiliary storage explicit. */
static void swap(unsigned char *a,unsigned char *b,size_t size) {
    unsigned char temporary[64];
    memcpy(temporary,a,size);memcpy(a,b,size);memcpy(b,temporary,size);
}
static void sift(unsigned char *data,size_t root,size_t count,size_t size,int (*compare)(const void *,const void *)) {
    while(root<count/2) {
        size_t child=root*2+1;
        if(child+1<count && compare(data+child*size,data+(child+1)*size)<0)++child;
        if(compare(data+root*size,data+child*size)>=0)return;
        swap(data+root*size,data+child*size,size);root=child;
    }
}
static void sort(void *data,size_t count,size_t size,int (*compare)(const void *,const void *)) {
    _Static_assert(sizeof(struct xpdb_public)<=64 && sizeof(struct xpdb_line)<=64 && sizeof(void *)<=64,"sort scratch");
    if(count<2)return;
    unsigned char *bytes=data;
    for(size_t i=count/2;i>0;--i)sift(bytes,i-1,count,size,compare);
    for(size_t i=count-1;i>0;--i){swap(bytes,bytes+i*size,size);sift(bytes,0,i,size,compare);}
}
static enum xpdb_status alloc(struct parser *p, struct block *b, size_t n) {
    if (n > XPDB_MAX_ALLOCATED_BYTES-p->allocated) return XPDB_LIMIT;
    b->data = n ? malloc(n) : NULL;
    if (n && !b->data) return XPDB_NOMEM;
    b->size=n; p->allocated+=n;
    if (p->allocated>p->peak) p->peak=p->allocated;
    return XPDB_OK;
}
static void drop(struct parser *p, struct block *b) {
    free(b->data); p->allocated-=b->size; *b=(struct block){0};
}
static enum xpdb_status charge(struct parser *p, size_t n) {
    if (n > UINT64_C(256)*1024*1024-p->work) return XPDB_LIMIT;
    p->work+=n; return XPDB_OK;
}
static enum xpdb_status claim(struct parser *p, uint32_t page) {
    if (page>=p->page_count || ((unsigned char *)p->ownership.data)[page]) return XPDB_MALFORMED;
    ((unsigned char *)p->ownership.data)[page]=1; return XPDB_OK;
}
static enum xpdb_status stream(struct parser *p, unsigned index, struct block *out) {
    if (index>=p->stream_count) return XPDB_MALFORMED;
    const struct stream *s=&((struct stream *)p->streams.data)[index];
    if (s->size==UINT32_MAX) return XPDB_MALFORMED;
    enum xpdb_status status=charge(p,s->size);
    if (status!=XPDB_OK) return status;
    status=alloc(p,out,s->size);
    if (status!=XPDB_OK) return status;
    size_t at=0;
    while (at<s->size) {
        size_t n=s->size-at; if(n>p->page_size)n=p->page_size;
        uint32_t page=u32(s->pages+(at/p->page_size)*4);
        memcpy((unsigned char *)out->data+at,p->bytes+(size_t)page*p->page_size,n); at+=n;
    }
    return XPDB_OK;
}
static enum xpdb_status directory(struct parser *p) {
    static const unsigned char magic[32]="Microsoft C/C++ MSF 7.00\r\n\032DS\0\0";
    if(p->size<32 || memcmp(p->bytes,magic,32))return XPDB_NOT_PDB;
    if(p->size<56)return XPDB_MALFORMED;
    if(p->size>XPDB_MAX_FILE_BYTES)return XPDB_LIMIT;
    p->page_size=u32(p->bytes+32);p->page_count=u32(p->bytes+40);
    if(p->page_size!=512 && p->page_size!=1024 && p->page_size!=2048 && p->page_size!=4096)return XPDB_UNSUPPORTED;
    if((uint64_t)p->page_size*p->page_count!=p->size || p->page_count<4 ||
        (u32(p->bytes+36)!=1 && u32(p->bytes+36)!=2))return XPDB_MALFORMED;
    size_t n=u32(p->bytes+44), count=pages(n,p->page_size);
    if(!n || count>p->page_size/4)return XPDB_LIMIT;
    enum xpdb_status status=alloc(p,&p->ownership,p->page_count);
    if(status!=XPDB_OK)return status;
    memset(p->ownership.data,0,p->ownership.size);
    ((unsigned char *)p->ownership.data)[0]=1;
    for(size_t i=1;i<p->page_count;i+=p->page_size) {
        ((unsigned char *)p->ownership.data)[i]=1;
        if(i+1<p->page_count)((unsigned char *)p->ownership.data)[i+1]=1;
    }
    uint32_t map=u32(p->bytes+52);
    if((status=claim(p,map))!=XPDB_OK)return status;
    const unsigned char *map_bytes=p->bytes+(size_t)map*p->page_size;
    if((status=alloc(p,&p->directory,n))!=XPDB_OK)return status;
    for(size_t i=0,at=0;i<count;++i) {
        uint32_t page=u32(map_bytes+i*4);
        if((status=claim(p,page))!=XPDB_OK)return status;
        size_t len=n-at;if(len>p->page_size)len=p->page_size;
        memcpy((unsigned char *)p->directory.data+at,p->bytes+(size_t)page*p->page_size,len);at+=len;
    }
    const unsigned char *d=p->directory.data;
    if(n<4)return XPDB_MALFORMED;
    p->stream_count=u32(d);
    if(p->stream_count>65536)return XPDB_LIMIT;
    if(p->stream_count<4 || !span(4,(size_t)p->stream_count*4,n))return XPDB_MALFORMED;
    if((status=alloc(p,&p->streams,p->stream_count*sizeof(struct stream)))!=XPDB_OK)return status;
    size_t at=4+(size_t)p->stream_count*4;
    for(unsigned i=0;i<p->stream_count;++i) {
        uint32_t len=u32(d+4+i*4);size_t blocks=len==UINT32_MAX?0:pages(len,p->page_size);
        if(!span(at,blocks*4,n))return XPDB_MALFORMED;
        ((struct stream *)p->streams.data)[i]=(struct stream){len,d+at};
        for(size_t j=0;j<blocks;++j)if((status=claim(p,u32(d+at+j*4)))!=XPDB_OK)return status;
        at+=blocks*4;
    }
    return at==n?XPDB_OK:XPDB_MALFORMED;
}
/* Strings are metadata, never file requests. Bound each scan, including
 * repeated references to the named-stream map and source name table. */
static const char *string_at(const unsigned char *b,size_t n,size_t at) {
    if(at>=n)return NULL;
    size_t remaining=n-at;if(remaining>4096)remaining=4096;
    return memchr(b+at,0,remaining)?(const char *)b+at:NULL;
}
static enum xpdb_status pdb_info(struct parser *p,const unsigned char guid[16],uint32_t age,unsigned *names) {
    struct block b={0};enum xpdb_status status=stream(p,1,&b);
    if(status!=XPDB_OK)return status;
    const unsigned char *d=b.data;size_t n=b.size,at=28;
    if(n<32){status=XPDB_MALFORMED;goto done;}
    if(u32(d)!=20000404){status=XPDB_UNSUPPORTED;goto done;}
    if(u32(d+8)!=age || memcmp(d+12,guid,16)){status=XPDB_MISMATCH;goto done;}
    size_t strings=u32(d+at);at+=4;
    if(!span(at,strings,n)){status=XPDB_MALFORMED;goto done;}
    const unsigned char *str=d+at;at+=strings;
    if(!span(at,8,n)){status=XPDB_MALFORMED;goto done;}
    uint32_t count=u32(d+at),capacity=u32(d+at+4);at+=8;
    if(count>4096 || capacity>65536){status=XPDB_LIMIT;goto done;}
    if(!capacity || count>capacity){status=XPDB_MALFORMED;goto done;}
    const unsigned char *present=NULL,*deleted=NULL;uint32_t words[2]={0};
    for(unsigned i=0;i<2;++i) {
        if(!span(at,4,n)){status=XPDB_MALFORMED;goto done;}
        words[i]=u32(d+at);at+=4;
        if(words[i]>pages(capacity,32) || !span(at,(size_t)words[i]*4,n)){status=XPDB_MALFORMED;goto done;}
        if(i==0)present=d+at;else deleted=d+at;
        at+=(size_t)words[i]*4;
    }
    unsigned found=0;*names=UINT_MAX;
    for(uint32_t i=0;i<capacity;++i) {
        int used=i/32<words[0] && (u32(present+(i/32)*4)&(UINT32_C(1)<<(i%32)));
        int gone=i/32<words[1] && (u32(deleted+(i/32)*4)&(UINT32_C(1)<<(i%32)));
        if(used && gone){status=XPDB_MALFORMED;goto done;}
        if(!used)continue;
        if(++found>count || !span(at,8,n)){status=XPDB_MALFORMED;goto done;}
        const char *name=string_at(str,strings,u32(d+at));unsigned index=u32(d+at+4);at+=8;
        if(!name || index>=p->stream_count){status=XPDB_MALFORMED;goto done;}
        if(!strcmp(name,"/names")) {
            if(*names!=UINT_MAX){status=XPDB_MALFORMED;goto done;}
            *names=index;
        }
    }
    if(found!=count || (n-at)%4){status=XPDB_MALFORMED;goto done;}
    for(;at<n;at+=4)if(u32(d+at)==0x494e494d){status=XPDB_UNSUPPORTED;goto done;} /* FASTLINK */
done:drop(p,&b);return status;
}
static int rva(struct xpdb *p,unsigned section,uint32_t offset,uint32_t size,uint32_t *out) {
    if(!section || section>p->section_count)return 0;
    const struct xpdb_section *s=&p->sections[section-1];
    if(offset>=s->size || size>s->size-offset || offset>UINT32_MAX-s->rva)return 0;
    *out=s->rva+offset;return size<=UINT32_MAX-*out;
}
static int public_compare(const void *av,const void *bv) {
    const struct xpdb_public *a=av,*b=bv;
    if(a->rva!=b->rva)return a->rva<b->rva?-1:1;
    return strcmp(a->name,b->name);
}
static int name_compare(const void *av,const void *bv) {
    const struct xpdb_public *const *a=av,*const *b=bv;
    return strcmp((*a)->name,(*b)->name);
}
static enum xpdb_status public_map(struct parser *p,unsigned index) {
    struct block map={0},selected={0};enum xpdb_status status=stream(p,index,&map);
    if(status!=XPDB_OK)return status;
    const unsigned char *d=map.data;size_t n=map.size;
    if(n<28){status=XPDB_MALFORMED;goto done;}
    size_t hash=u32(d),addresses=u32(d+4);
    if(!span(28,hash,n) || !span(28+hash,addresses,n) || (addresses&3)){status=XPDB_MALFORMED;goto done;}
    if(u32(d+8) || u32(d+24) || 28+hash+addresses!=n){status=XPDB_UNSUPPORTED;goto done;}
    if(addresses/4>p->out->info.public_count){status=XPDB_MALFORMED;goto done;}
    if((status=alloc(p,&selected,p->out->info.public_count))!=XPDB_OK)goto done;
    if(selected.size)memset(selected.data,0,selected.size);
    unsigned char *seen=selected.data;uint32_t previous=0;
    for(size_t i=0;i<addresses/4;++i) {
        uint32_t offset=u32(d+28+hash+i*4);size_t lo=0,hi=p->out->info.public_count;
        while(lo<hi) {
            size_t mid=lo+(hi-lo)/2;
            size_t at=(const unsigned char *)p->out->publics[mid].name-(const unsigned char *)p->out->symbols.data-14;
            if(at<offset)lo=mid+1;else hi=mid;
        }
        if(lo==p->out->info.public_count || seen[lo] ||
            (const unsigned char *)p->out->publics[lo].name-(const unsigned char *)p->out->symbols.data-14!=offset ||
            (i && p->out->publics[lo].rva<previous)){status=XPDB_MALFORMED;goto done;}
        seen[lo]=1;previous=p->out->publics[lo].rva;
    }
    unsigned kept=0;
    for(unsigned i=0;i<p->out->info.public_count;++i)if(seen[i])p->out->publics[kept++]=p->out->publics[i];
    p->out->info.public_count=kept;
done:drop(p,&selected);drop(p,&map);return status;
}
static enum xpdb_status publics(struct parser *p,unsigned index,unsigned map_index) {
    if(map_index==UINT16_MAX)return XPDB_OK;
    enum xpdb_status status=stream(p,index,&p->out->symbols);
    if(status!=XPDB_OK)return status;
    const unsigned char *d=p->out->symbols.data;size_t n=p->out->symbols.size;
    unsigned count=0;
    for(size_t at=0;at<n;) {
        if(!span(at,4,n))return XPDB_MALFORMED;
        size_t size=(size_t)u16(d+at)+2;
        if(size<4 || !span(at,size,n))return XPDB_MALFORMED;
        if(u16(d+at+2)==0x110e) {
            if(size<15 || !string_at(d+at,size,14))return XPDB_MALFORMED;
            uint32_t address;
            if(!rva(p->out,u16(d+at+12),u32(d+at+8),0,&address))return XPDB_MALFORMED;
            if(++count>XPDB_MAX_ROWS)return XPDB_LIMIT;
        }
        at+=size;
    }
    struct block b={0};if((status=alloc(p,&b,count*sizeof(struct xpdb_public)))!=XPDB_OK)return status;
    p->out->publics=b.data;p->out->info.public_count=count;count=0;
    for(size_t at=0;at<n;) {
        size_t size=(size_t)u16(d+at)+2;
        if(u16(d+at+2)==0x110e) {
            struct xpdb_public *s=&p->out->publics[count++];s->name=(const char *)d+at+14;
            s->flags=u32(d+at+4);s->section=u16(d+at+12);
            if(!rva(p->out,s->section,u32(d+at+8),0,&s->rva))return XPDB_MALFORMED;
        }
        at+=size;
    }
    /* Ignore unreferenced stale records from incremental linking. The public
     * address map must point at actual S_PUB32 record boundaries. */
    if((status=public_map(p,map_index))!=XPDB_OK)return status;
    count=p->out->info.public_count;
    sort(p->out->publics,count,sizeof(struct xpdb_public),public_compare);
    b=(struct block){0};
    if((status=alloc(p,&b,count*sizeof(*p->out->by_name)))!=XPDB_OK)return status;
    p->out->by_name=b.data;
    for(unsigned i=0;i<count;++i)p->out->by_name[i]=&p->out->publics[i];
    sort(p->out->by_name,count,sizeof(*p->out->by_name),name_compare);
    return XPDB_OK;
}
static int line_compare(const void *av,const void *bv) {
    const struct xpdb_line *a=av,*b=bv;
    return a->rva==b->rva?0:(a->rva<b->rva?-1:1);
}
struct lines { struct block rows; size_t count,capacity; };
static enum xpdb_status add_line(struct parser *p,struct lines *rows,struct xpdb_line line) {
    if(rows->count==XPDB_MAX_ROWS)return XPDB_LIMIT;
    if(rows->count==rows->capacity) {
        size_t capacity=rows->capacity?rows->capacity*2:256;
        struct block b={0};enum xpdb_status status=alloc(p,&b,capacity*sizeof(line));
        if(status!=XPDB_OK)return status;
        if(rows->count)memcpy(b.data,rows->rows.data,rows->count*sizeof(line));
        drop(p,&rows->rows);rows->rows=b;rows->capacity=capacity;
    }
    ((struct xpdb_line *)rows->rows.data)[rows->count++]=line;return XPDB_OK;
}
static enum xpdb_status lines_block(struct parser *p,struct lines *rows,const unsigned char *d,size_t n,
    const unsigned char *checksums,size_t checksums_size) {
    if(n<12)return XPDB_MALFORMED;
    uint32_t start,end,code_size=u32(d+8);uint16_t flags=u16(d+6);
    if(flags&~1u)return XPDB_UNSUPPORTED;
    if(!code_size || !rva(p->out,u16(d+4),u32(d),code_size,&start))return XPDB_MALFORMED;
    end=start+code_size;size_t first=rows->count;
    for(size_t at=12;at<n;) {
        if(!span(at,12,n))return XPDB_MALFORMED;
        uint32_t name=u32(d+at),count=u32(d+at+4),bytes=u32(d+at+8);
        if(count>XPDB_MAX_ROWS || bytes!=12+(uint64_t)count*((flags&1)?12:8) || !span(at,bytes,n))return XPDB_MALFORMED;
        /* NameIndex must designate the start of a checksum record, not an
         * arbitrary interior byte that happens to resemble a string offset. */
        size_t check=0;
        while(check<checksums_size && check<name) {
            if(!span(check,6,checksums_size))return XPDB_MALFORMED;
            check+=(6+(size_t)checksums[check+4]+3)&~(size_t)3;
        }
        if(check!=name || !span(check,6,checksums_size))return XPDB_MALFORMED;
        const unsigned char *names=p->out->names.data;
        const char *path=names?string_at(names+12,u32(names+8),u32(checksums+check)):NULL;
        if(!path)return XPDB_MALFORMED;
        if(charge(p,check+strlen(path)+1)!=XPDB_OK)return XPDB_LIMIT;
        uint32_t previous=0;
        for(unsigned i=0;i<count;++i) {
            const unsigned char *row=d+at+12+(size_t)i*8;
            uint32_t off=u32(row),line=u32(row+4)&0xffffff;
            if(off>=code_size || (i && off<previous))return XPDB_MALFORMED;
            previous=off;
            if(line>=0xfeefee)line=0; /* hidden rows still terminate the previous range */
            struct xpdb_line value={path,start+off,end,line,0,u32(row+4)>>31};
            if(flags&1)value.column=u16(d+at+12+(size_t)count*8+(size_t)i*4);
            enum xpdb_status status=add_line(p,rows,value);if(status!=XPDB_OK)return status;
        }
        at+=bytes;
    }
    struct xpdb_line *values=rows->rows.data;
    if(rows->count>first)sort(values+first,rows->count-first,sizeof *values,line_compare);
    for(size_t i=first;i+1<rows->count;++i) {
        if(values[i].rva==values[i+1].rva && (values[i].line!=values[i+1].line || strcmp(values[i].path,values[i+1].path)))return XPDB_UNSUPPORTED;
        values[i].end=values[i+1].rva;
    }
    return XPDB_OK;
}
static enum xpdb_status module_lines(struct parser *p,struct lines *rows,unsigned index,uint32_t symbols,uint32_t c11,uint32_t c13) {
    if(!c13)return XPDB_OK;
    if(c11)return XPDB_UNSUPPORTED;
    struct block b={0};enum xpdb_status status=stream(p,index,&b);
    if(status!=XPDB_OK)return status;
    if(symbols<4 || b.size<4 || u32(b.data)!=4 || !span(symbols,c13,b.size)){status=XPDB_MALFORMED;goto done;}
    const unsigned char *d=(unsigned char *)b.data+symbols,*checksums=NULL;size_t checksum_size=0;
    for(size_t at=0;at<c13;) {
        if(!span(at,8,c13)){status=XPDB_MALFORMED;goto done;}
        uint32_t kind=u32(d+at),size=u32(d+at+4);at+=8;
        if(!span(at,size,c13)){status=XPDB_MALFORMED;goto done;}
        if(kind==0xf4) {
            if(checksums){status=XPDB_MALFORMED;goto done;}
            checksums=d+at;checksum_size=size;
            for(size_t c=0;c<size;) {
                if(!span(c,6,size)){status=XPDB_MALFORMED;goto done;}
                unsigned len=checksums[c+4],type=checksums[c+5];
                if(type>3 || len!=(type==0?0:type==1?16:type==2?20:32)){status=XPDB_UNSUPPORTED;goto done;}
                size_t total=(6+(size_t)len+3)&~(size_t)3;
                if(!span(c,total,size)){status=XPDB_MALFORMED;goto done;}c+=total;
            }
        }
        if(kind==0xf3){status=XPDB_UNSUPPORTED;goto done;} /* object-local string tables */
        size_t padded=((size_t)size+3)&~(size_t)3;
        if(!span(at,padded,c13)){status=XPDB_MALFORMED;goto done;}at+=padded;
    }
    for(size_t at=0;at<c13;) {
        uint32_t kind=u32(d+at),size=u32(d+at+4);at+=8;
        if(kind==0xf2 && (status=lines_block(p,rows,d+at,size,checksums,checksum_size))!=XPDB_OK)goto done;
        at+=((size_t)size+3)&~(size_t)3;
    }
done:drop(p,&b);return status;
}
static enum xpdb_status dbi(struct parser *p,uint32_t age,unsigned names_index) {
    struct block b={0},sections={0};struct lines rows={0};
    enum xpdb_status status=stream(p,3,&b);if(status!=XPDB_OK)return status;
    const unsigned char *d=b.data;size_t n=b.size;
    if(n<64 || u32(d)!=UINT32_MAX){status=XPDB_MALFORMED;goto done;}
    if(u32(d+4)!=19990903 || u16(d+58)!=0x8664){status=XPDB_UNSUPPORTED;goto done;}
    if(u32(d+8)!=age){status=XPDB_MISMATCH;goto done;}
    size_t lengths[7]={u32(d+24),u32(d+28),u32(d+32),u32(d+36),u32(d+40),u32(d+52),u32(d+48)};
    size_t at=64;
    for(unsigned i=0;i<7;++i) {
        if(lengths[i]>INT32_MAX || !span(at,lengths[i],n)){status=XPDB_MALFORMED;goto done;}
        at+=lengths[i];
    }
    if(at!=n || lengths[6]<12 || (lengths[6]&1)){status=XPDB_UNSUPPORTED;goto done;}
    const unsigned char *optional=d+n-lengths[6];
    if(u16(optional+6)!=UINT16_MAX || u16(optional+8)!=UINT16_MAX){status=XPDB_UNSUPPORTED;goto done;} /* OMAP */
    if((status=stream(p,u16(optional+10),&sections))!=XPDB_OK)goto done;
    if(sections.size!=p->out->section_count*40u){status=XPDB_MISMATCH;goto done;}
    for(unsigned i=0;i<p->out->section_count;++i) {
        const unsigned char *s=(unsigned char *)sections.data+i*40;
        uint32_t size=u32(s+8);if(u32(s+16)>size)size=u32(s+16);
        if(u32(s+12)!=p->out->sections[i].rva || size!=p->out->sections[i].size){status=XPDB_MISMATCH;goto done;}
    }
    drop(p,&sections);
    if((status=publics(p,u16(d+20),u16(d+16)))!=XPDB_OK)goto done;
    if(names_index!=UINT_MAX) {
        if((status=stream(p,names_index,&p->out->names))!=XPDB_OK)goto done;
        const unsigned char *names=p->out->names.data;size_t size=p->out->names.size;
        if(size<12 || u32(names)!=0xeffeeffe || (u32(names+4)!=1 && u32(names+4)!=2) || !span(12,u32(names+8),size)){status=XPDB_MALFORMED;goto done;}
    }
    for(at=64;at<64+lengths[0];) {
        size_t end=64+lengths[0];
        if(!span(at,64,end)){status=XPDB_MALFORMED;goto done;}
        const unsigned char *m=d+at;at+=64;
        for(unsigned i=0;i<2;++i) {
            const char *name=string_at(d,end,at);
            if(!name){status=XPDB_MALFORMED;goto done;}at+=strlen(name)+1;
        }
        at=(at+3)&~(size_t)3;if(at>end){status=XPDB_MALFORMED;goto done;}
        status=module_lines(p,&rows,u16(m+34),u32(m+36),u32(m+40),u32(m+44));
        if(status!=XPDB_OK)goto done;
    }
    sort(rows.rows.data,rows.count,sizeof(struct xpdb_line),line_compare);
    struct xpdb_line *values=rows.rows.data;size_t keep=0;
    for(size_t i=0;i<rows.count;++i) {
        if(!values[i].line || values[i].end<=values[i].rva)continue;
        if(keep && values[keep-1].end>values[i].rva) {
            if(values[keep-1].rva==values[i].rva && values[keep-1].end==values[i].end && values[keep-1].line==values[i].line && !strcmp(values[keep-1].path,values[i].path))continue;
            status=XPDB_UNSUPPORTED;goto done; /* ambiguous folded/overlapping line ranges */
        }
        values[keep++]=values[i];
    }
    p->out->lines=rows.rows.data;p->out->info.line_count=(uint32_t)keep;rows.rows=(struct block){0};
done:drop(p,&rows.rows);drop(p,&sections);drop(p,&b);return status;
}
enum xpdb_status xpdb_load(const void *bytes,size_t size,const unsigned char guid[16],uint32_t age,
    const struct xpdb_section *sections,unsigned count,struct xpdb **out) {
    if(!out)return XPDB_MALFORMED;
    *out=NULL;
    if((size && !bytes) || !guid || !sections || !count || count>96)return XPDB_MALFORMED;
    struct parser p={.bytes=bytes,.size=size,.allocated=sizeof(struct xpdb),.peak=sizeof(struct xpdb)};
    p.out=calloc(1,sizeof *p.out);if(!p.out)return XPDB_NOMEM;
    p.out->section_count=count;memcpy(p.out->sections,sections,count*sizeof *sections);
    for(unsigned i=0;i<count;++i)if(sections[i].size>UINT32_MAX-sections[i].rva){xpdb_destroy(p.out);return XPDB_MALFORMED;}
    enum xpdb_status status=directory(&p);unsigned names=UINT_MAX;
    if(status==XPDB_OK)status=pdb_info(&p,guid,age,&names);
    if(status==XPDB_OK)status=dbi(&p,age,names);
    drop(&p,&p.ownership);drop(&p,&p.streams);drop(&p,&p.directory);
    if(status==XPDB_OK) {
        p.out->info.retained_bytes=p.allocated;p.out->info.peak_bytes=p.peak;p.out->info.work_bytes=p.work;*out=p.out;
    } else xpdb_destroy(p.out);
    return status;
}
void xpdb_destroy(struct xpdb *p) {
    if(!p)return;
    free(p->by_name);free(p->publics);free(p->lines);free(p->symbols.data);free(p->names.data);free(p);
}
const struct xpdb_info *xpdb_info(const struct xpdb *p){return p?&p->info:NULL;}
const struct xpdb_public *xpdb_public(const struct xpdb *p,unsigned i){return p && i<p->info.public_count?&p->publics[i]:NULL;}
const struct xpdb_public *xpdb_find_public(const struct xpdb *p,const char *name) {
    if(!p || !name)return NULL;
    size_t lo=0,hi=p->info.public_count;
    while(lo<hi) {
        size_t mid=lo+(hi-lo)/2;int order=strcmp(name,p->by_name[mid]->name);
        if(!order)return p->by_name[mid];
        if(order>0)lo=mid+1;else hi=mid;
    }
    return NULL;
}
const struct xpdb_public *xpdb_public_at(const struct xpdb *p,uint32_t address) {
    if(!p)return NULL;
    size_t lo=0,hi=p->info.public_count;
    while(lo<hi){size_t mid=lo+(hi-lo)/2;if(p->publics[mid].rva<=address)lo=mid+1;else hi=mid;}
    if(!lo)return NULL;
    const struct xpdb_public *s=&p->publics[lo-1];
    const struct xpdb_section *section=&p->sections[s->section-1];
    return address-section->rva<section->size?s:NULL;
}
const struct xpdb_line *xpdb_line(const struct xpdb *p,unsigned i){return p && i<p->info.line_count?&p->lines[i]:NULL;}
const struct xpdb_line *xpdb_line_at(const struct xpdb *p,uint32_t address) {
    if(!p)return NULL;
    size_t lo=0,hi=p->info.line_count;
    while(lo<hi){size_t mid=lo+(hi-lo)/2;if(p->lines[mid].rva<=address)lo=mid+1;else hi=mid;}
    return lo && address<p->lines[lo-1].end?&p->lines[lo-1]:NULL;
}
const char *xpdb_status_name(enum xpdb_status s) {
    switch(s) {
    case XPDB_OK:return "ok";case XPDB_NOT_PDB:return "not_pdb";case XPDB_MALFORMED:return "malformed";
    case XPDB_UNSUPPORTED:return "unsupported";case XPDB_MISMATCH:return "mismatch";
    case XPDB_LIMIT:return "limit";case XPDB_NOMEM:return "out_of_memory";
    }return "invalid";
}
