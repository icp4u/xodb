#ifndef XODB_JAI_LIVE_INTERNAL_H
#define XODB_JAI_LIVE_INTERNAL_H
#include "jai.h"
static inline const char *read_exact(struct xjai_live_reader *r,uint64_t at,void *out,size_t n)
{
    if (!r || !r->read || !at || at>UINT64_MAX-n) return "JaiValueAddressInvalid";
    if (r->reads>=512 || r->bytes>65536 || n>65536-r->bytes) return "JaiValueReadBudget";
    ++r->reads;r->bytes+=n;
    if (!r->read(r->context,at,out,n)) return "JaiValueUnreadable";
    return NULL;
}
static inline uint64_t little(const unsigned char *p,unsigned n)
{
    uint64_t v=0;for (unsigned i=0;i<n;++i) v|=(uint64_t)p[i]<<(8*i);return v;
}
#endif
