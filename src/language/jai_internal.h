#ifndef XODB_JAI_INTERNAL_H
#define XODB_JAI_INTERNAL_H
#include "jai.h"
#include <string.h>
struct reader { const struct xjai_image *image;size_t reads_left,bytes_left;int bounded,exhausted; };
static inline const unsigned char *bytes(struct reader *r,uint64_t at,size_t n)
{
    if (r->bounded) {
        if (!r->reads_left || n>r->bytes_left) {r->exhausted=1;return NULL;}
        --r->reads_left;r->bytes_left-=n;
    }
    if (at>UINT64_MAX-n) return NULL;
    size_t lo=0,hi=r->image->count;
    while (lo<hi) {
        size_t m=lo+(hi-lo)/2;
        if (r->image->regions[m].address<=at) lo=m+1;else hi=m;
    }
    if (!lo) return NULL;
    const struct xjai_region *s=&r->image->regions[lo-1];uint64_t off=at-s->address;
    if (off>s->size || n>s->size-off) return NULL;
    return s->data+(size_t)off;
}
static inline uint64_t word(const unsigned char *p,unsigned n)
{
    uint64_t v=0;for (unsigned i=0;i<n;++i) v|=(uint64_t)p[i]<<(8*i);return v;
}
static inline int get(struct reader *r,uint64_t at,unsigned n,uint64_t *out)
{
    const unsigned char *p=bytes(r,at,n);if (!p) return 0;*out=word(p,n);return 1;
}
static inline int str_eq(struct reader *r,uint64_t at,const char *want)
{
    const unsigned char *p=bytes(r,at,16);if (!p) return 0;
    uint64_t n=word(p,8),address=word(p+8,8);size_t length=strlen(want);
    if (n!=length) return 0;
    p=bytes(r,address,length);return p && !memcmp(p,want,length);
}
static inline int type(struct reader *r,uint64_t at,unsigned tag,uint64_t size)
{
    const unsigned char *p=bytes(r,at,16);
    return p && word(p,4)==tag && word(p+8,8)==size;
}
static inline int integer(struct reader *r,uint64_t at,uint64_t size,int sign)
{
    uint64_t v;return bytes(r,at,17) && type(r,at,0,size) && get(r,at+16,1,&v) && v==(uint64_t)sign;
}
static inline int array(struct reader *r,uint64_t at,uint64_t *count,uint64_t *data,uint64_t cap,size_t stride)
{
    const unsigned char *p=bytes(r,at,16);if (!p) return 0;
    *count=word(p,8);*data=word(p+8,8);
    return *count<=cap && (!*count || bytes(r,*data,(size_t)*count*stride));
}
#endif
