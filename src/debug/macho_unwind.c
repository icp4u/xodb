#include "macho_unwind.h"
#include <stdlib.h>

#define MAX_ROWS 262144u
struct xmu_table { struct xmu_row *rows; size_t count, bytes; };
static uint16_t r16(const unsigned char *p) { return (uint16_t)((uint16_t)p[0]|(uint16_t)p[1]<<8); }
static uint32_t r32(const unsigned char *p) { return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
static int span(size_t size, uint64_t start, uint64_t bytes) { return start<=size && bytes<=size-start; }
static int disjoint(uint64_t a, uint64_t n, uint64_t b, uint64_t m) { return !n || !m || a+n<=b || b+m<=a; }
static enum xmo_status decode(const unsigned char *data, size_t size, struct xmu_row *out, size_t *count) {
    *count=0;
    if (size<28) return XMO_MALFORMED;
    if (r32(data)!=1) return XMO_UNSUPPORTED;
    uint32_t common=r32(data+4),nc=r32(data+8),personalities=r32(data+12),np=r32(data+16),index=r32(data+20),ni=r32(data+24);
    if (nc>256 || np>3 || ni>32768) return XMO_LIMIT;
    if (ni<2 || !span(size,common,(uint64_t)nc*4) || !span(size,personalities,(uint64_t)np*4) || !span(size,index,(uint64_t)ni*12)) return XMO_MALFORMED;
    if ((common|personalities|index)&3) return XMO_MALFORMED;
    uint64_t minimum=28;
    if (nc && (uint64_t)common+nc*4>minimum) minimum=(uint64_t)common+nc*4;
    if (np && (uint64_t)personalities+np*4>minimum) minimum=(uint64_t)personalities+np*4;
    if ((uint64_t)index+ni*12>minimum) minimum=(uint64_t)index+ni*12;
    if ((nc && common<28) || (np && personalities<28) || index<28 ||
        !disjoint(common,(uint64_t)nc*4,personalities,(uint64_t)np*4) ||
        !disjoint(common,(uint64_t)nc*4,index,(uint64_t)ni*12) ||
        !disjoint(personalities,(uint64_t)np*4,index,(uint64_t)ni*12)) return XMO_MALFORMED;
    for (uint32_t i=0;i<ni-1;++i) {
        const unsigned char *entry=data+index+(size_t)i*12;
        uint32_t base=r32(entry),page=r32(entry+4),end=r32(entry+12),lsda=r32(entry+8),next_lsda=r32(entry+20);
        if (base>=end || page<minimum || page&3 || !span(size,page,8)) return XMO_MALFORMED;
        if (lsda>next_lsda || !span(size,lsda,next_lsda-lsda) || (next_lsda-lsda)%8) return XMO_MALFORMED;
        size_t page_size=size-page<4096 ? size-page : 4096;
        const unsigned char *p=data+page;
        uint32_t kind=r32(p);uint16_t offset=r16(p+4),n=r16(p+6),encoding_offset=0,nencoding=0;
        unsigned stride=kind==2 ? 8 : 4;
        if (kind!=2 && kind!=3) return XMO_UNSUPPORTED;
        unsigned header=kind==2 ? 8 : 12;
        if (page_size<header || !n || n>(kind==2 ? 511 : 1021) || offset<header || offset%4 || !span(page_size,offset,(uint64_t)n*stride)) return XMO_MALFORMED;
        if (kind==3) {
            encoding_offset=r16(p+8);nencoding=r16(p+10);
            if ((unsigned)nencoding+nc>256 || (nencoding && encoding_offset<header) || encoding_offset%4 ||
                !span(page_size,encoding_offset,(uint64_t)nencoding*4) ||
                !disjoint(offset,(uint64_t)n*stride,encoding_offset,(uint64_t)nencoding*4)) return XMO_MALFORMED;
        }
        if (n>MAX_ROWS-*count) return XMO_LIMIT;
        uint32_t previous=0;
        for (uint32_t j=0;j<n;++j) {
            const unsigned char *row=p+offset+(size_t)j*stride;
            uint32_t value=r32(row),address=value,encoding=0;
            if (kind==2) encoding=r32(row+4);
            else {
                uint32_t e=value>>24,delta=value&0x00ffffff;
                if (delta>UINT32_MAX-base || e>=nc+nencoding) return XMO_MALFORMED;
                address=base+delta;
                encoding=e<nc ? r32(data+common+(size_t)e*4) : r32(p+encoding_offset+(size_t)(e-nc)*4);
            }
            if (address<base || address>=end || (!j && address!=base) || (j && address<=previous)) return XMO_MALFORMED;
            if (out) {
                if (j) out[*count-1].end=address;
                out[*count]=(struct xmu_row){address,end,encoding};
            }
            ++*count;previous=address;
        }
    }
    if (r32(data+index+(size_t)(ni-1)*12+4)!=0) return XMO_MALFORMED;
    return XMO_OK;
}
enum xmo_status xmu_create(const unsigned char *data, size_t size, uint64_t allowance, struct xmu_table **out) {
    if (!data || !out) return XMO_MALFORMED;
    *out=NULL;
    if (size>16*1024*1024) return XMO_LIMIT;
    size_t count=0;
    enum xmo_status status=decode(data,size,NULL,&count);
    if (status!=XMO_OK) return status;
    uint64_t bytes=sizeof(struct xmu_table)+count*sizeof(struct xmu_row);
    if (bytes>allowance) return XMO_LIMIT;
    struct xmu_table *table=calloc(1,sizeof *table);
    if (!table) return XMO_NOMEM;
    table->rows=calloc(count ? count : 1,sizeof *table->rows);
    if (!table->rows) { free(table);return XMO_NOMEM; }
    table->bytes=(size_t)bytes;
    status=decode(data,size,table->rows,&table->count);
    if (status!=XMO_OK || table->count!=count) { xmu_destroy(table);return status==XMO_OK ? XMO_CHANGED : status; }
    *out=table;return XMO_OK;
}
void xmu_destroy(struct xmu_table *table) { if (table) { free(table->rows);free(table); } }
size_t xmu_bytes(const struct xmu_table *table) { return table ? table->bytes : 0; }
enum xmo_status xmu_lookup(const struct xmu_table *table, uint64_t pc, struct xmu_row *out) {
    if (!table || !out) return XMO_MALFORMED;
    size_t lo=0,hi=table->count;
    while (lo<hi) { size_t mid=lo+(hi-lo)/2;if (table->rows[mid].start<=pc) lo=mid+1;else hi=mid; }
    if (!lo || pc>=table->rows[lo-1].end) return XMO_NOT_FOUND;
    *out=table->rows[lo-1];return out->encoding ? XMO_OK : XMO_UNAVAILABLE;
}
