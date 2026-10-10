#include "jai.h"
#include <stdlib.h>
#include <string.h>
#include "jai_live_internal.h"
static uint64_t extend(uint64_t bits,uint64_t size,int sign)
{
    if (!sign || size==8) return bits;
    unsigned n=(unsigned)size*8;uint64_t mask=(UINT64_C(1)<<n)-1;
    return bits&(UINT64_C(1)<<(n-1)) ? bits|~mask : bits;
}
struct walk_value {
    const struct xjai_graph *g;struct xjai_live_reader *r;struct xjai_values *out;
    struct xjai_value_options options;
    uint32_t types[XJAI_VALUE_DEPTH+1];uint64_t addresses[XJAI_VALUE_DEPTH+1];
    const char *fatal;
};
static void bad(struct walk_value *w,uint32_t row,const char *why)
{
    w->out->rows[row].reason=why;w->out->partial=1;
    if (!w->out->reason) w->out->reason=why;
}
static uint32_t append(struct walk_value *w,uint32_t type,uint64_t at,uint32_t parent,uint32_t member,uint64_t index)
{
    struct xjai_values *v=w->out;
    if (v->count==XJAI_VALUE_ROWS) {v->partial=1;v->reason="JaiValueRowLimit";return XJAI_NONE;}
    if (v->count==v->capacity) {
        uint32_t n=v->capacity?v->capacity*2:16;
        struct xjai_value_row *p=realloc(v->rows,(size_t)n*sizeof *p);
        if (!p) {w->fatal="JaiOutOfMemory";return XJAI_NONE;}
        v->rows=p;v->capacity=n;
    }
    uint32_t row=v->count++;
    v->rows[row]=(struct xjai_value_row){.type=type,.address=at,.parent=parent,.member=member,.index=index,.referenced_type=XJAI_NONE,.enum_name=XJAI_NONE};return row;
}
static void value(struct walk_value *w,uint32_t ti,uint64_t address,uint32_t parent,uint32_t member,uint64_t index,uint32_t depth)
{
    uint32_t row=append(w,ti,address,parent,member,index);if (row==XJAI_NONE) return;
    if (ti>=w->g->type_count) {bad(w,row,"JaiValueTypeUnavailable");return;}
    const struct xjai_type *t=&w->g->types[ti];
    if (t->reason) {bad(w,row,t->reason);return;}
    if (!address || address>UINT64_MAX-t->size) {bad(w,row,"JaiValueAddressInvalid");return;}
    for (uint32_t i=0;i<depth;++i) if (w->types[i]==ti && w->addresses[i]==address) {bad(w,row,"JaiValueCycle");return;}
    w->types[depth]=ti;w->addresses[depth]=address;
    struct xjai_value_row *r=&w->out->rows[row];unsigned char data[16];const char *why;
    if (t->tag==0 || t->tag==1 || t->tag==2 || t->tag==4 || t->tag==11 || t->tag==13) {
        if (!t->size || t->size>8) {bad(w,row,"JaiScalarWidthUnproved");return;}
        if ((why=read_exact(w->r,address,data,(size_t)t->size))) {bad(w,row,why);return;}
        r->bits=extend(little(data,(unsigned)t->size),t->size,t->is_signed);r->has_bits=1;
        if (t->tag==2 && r->bits>1) {r->has_bits=0;bad(w,row,"JaiBooleanInvalid");return;}
        if (t->tag==11) for (uint32_t i=0;i<t->enum_count;++i) {
            const struct xjai_enum_value *e=&w->g->enums[t->first_enum+i];
            if (e->bits==r->bits) {r->enum_name=e->name;break;}
        }
        if (t->tag==13) {
            r->referenced_type=xjai_type_at(w->g,r->bits);
            if (r->referenced_type==XJAI_NONE) bad(w,row,"JaiTypePointerUnknown");
        } else if (t->tag==4 && w->options.follow_pointers && r->bits) {
            if (depth==w->options.depth) {r->truncated=1;return;}
            value(w,t->element,r->bits,row,XJAI_NONE,0,depth+1);
        }
        return;
    }
    if (t->tag==6) return;
    if (t->tag==3) {
        if ((why=read_exact(w->r,address,data,16))) {bad(w,row,why);return;}
        uint64_t count=little(data,8),pointer=little(data+8,8);r->total_count=count;
        if (count>INT64_MAX || pointer>UINT64_MAX-count) {bad(w,row,"JaiStringHeaderInvalid");return;}
        if (!count) return;
        size_t n=count>XJAI_VALUE_PREVIEW?XJAI_VALUE_PREVIEW:(size_t)count;
        if ((why=read_exact(w->r,pointer,r->preview,n))) {bad(w,row,why);return;}
        r->preview_bytes=(uint32_t)n;r->truncated=n<count;return;
    }
    if (t->tag==7) {
        uint64_t total=0;for (uint32_t i=0;i<t->member_count;++i) {
            uint32_t flags=w->g->members[t->first_member+i].flags;
            if (!(flags&(w->g->layout.flags[XJAI_F_CONSTANT]|w->g->layout.flags[XJAI_F_IMPORTED]))) ++total;
        }
        r->total_count=total;
        if (depth==w->options.depth) {r->truncated=total!=0;return;}
        uint64_t start=depth?0:w->options.start,seen=0,emitted=0;
        if (start>total) {bad(w,row,"JaiValuePageOutOfRange");return;}
        r->truncated=start!=0 || total-start>w->options.limit;
        for (uint32_t i=0;i<t->member_count && !w->fatal;++i) {
            uint32_t mi=t->first_member+i;const struct xjai_member *m=&w->g->members[mi];
            if (m->flags&(w->g->layout.flags[XJAI_F_CONSTANT]|w->g->layout.flags[XJAI_F_IMPORTED])) continue;
            if (seen++<start) continue;
            if (emitted++==w->options.limit) break;
            if (m->reason || m->offset>UINT64_MAX-address) {
                uint32_t child=append(w,m->type,0,row,mi,seen-1);
                if (child!=XJAI_NONE) bad(w,child,m->reason?m->reason:"JaiValueAddressInvalid");
            } else value(w,m->type,address+m->offset,row,mi,seen-1,depth+1);
        }
        return;
    }
    if (t->tag==8) {
        struct xjai_array_span span;
        if ((why=xjai_array_span(w->g,ti,address,w->r,&span))) {bad(w,row,why);return;}
        uint64_t count=span.count,pointer=span.data,size=w->g->types[t->element].size;
        r->total_count=count;
        if (depth==w->options.depth) {r->truncated=count!=0;return;}
        uint64_t start=depth?0:w->options.start;
        if (start>count) {bad(w,row,"JaiValuePageOutOfRange");return;}
        uint64_t n=count-start;if (n>w->options.limit) n=w->options.limit;
        r->truncated=start!=0 || n<count;
        for (uint64_t i=0;i<n && !w->fatal;++i) value(w,t->element,pointer+(start+i)*size,row,XJAI_NONE,start+i,depth+1);
        return;
    }
    bad(w,row,"JaiValueCategoryUnsupported");
}
void xjai_values_free(struct xjai_values *v)
{
    if (!v) return;
    free(v->rows);free(v);
}
const char *xjai_value_read(const struct xjai_graph *g,uint32_t type,uint64_t address,
    const struct xjai_value_options *options,struct xjai_live_reader *reader,struct xjai_values **out)
{
    if (!out) return "JaiInvalidArgument";
    *out=NULL;
    if (!g || type>=g->type_count || !reader || !reader->read) return "JaiInvalidArgument";
    struct xjai_value_options o=options?*options:(struct xjai_value_options){.depth=3,.limit=32};
    if (o.depth>XJAI_VALUE_DEPTH || !o.limit || o.limit>64) return "JaiInvalidValueLimits";
    struct xjai_values *v=calloc(1,sizeof *v);if (!v) return "JaiOutOfMemory";
    struct walk_value w={.g=g,.r=reader,.out=v,.options=o};value(&w,type,address,XJAI_NONE,XJAI_NONE,0,0);
    if (w.fatal) {xjai_values_free(v);return w.fatal;}
    *out=v;return NULL;
}
static int prefix_type(const struct xjai_graph *g,uint32_t candidate,uint32_t base,unsigned depth,unsigned *work)
{
    if (++*work>4096) return -1;
    if (candidate==base) return 1;
    if (depth==XJAI_FIELD_DEPTH) return -1;
    if (candidate>=g->type_count) return 0;
    const struct xjai_type *t=&g->types[candidate];if (t->reason || t->tag!=7) return 0;
    for (uint32_t i=0;i<t->member_count;++i) {
        if (++*work>4096) return -1;
        const struct xjai_member *m=&g->members[t->first_member+i];
        if (!m->reason && !m->offset && (m->flags&g->layout.flags[XJAI_F_USING]) &&
            !(m->flags&(g->layout.flags[XJAI_F_CONSTANT]|g->layout.flags[XJAI_F_IMPORTED]))) {
            int found=prefix_type(g,m->type,base,depth+1,work);if (found) return found;
        }
    }
    return 0;
}
const char *xjai_self_type(const struct xjai_graph *g,uint32_t declared,uint64_t address,
    uint32_t member,struct xjai_live_reader *r,uint32_t *resolved)
{
    if (!resolved) return "JaiInvalidArgument";
    *resolved=XJAI_NONE;
    if (!g || declared>=g->type_count) return "JaiInvalidArgument";
    const struct xjai_type *t=&g->types[declared];
    if (t->reason || t->tag!=7 || member<t->first_member || member-t->first_member>=t->member_count) return "JaiSelfTypeFieldUnproved";
    const struct xjai_member *m=&g->members[member];
    if (m->reason || m->type>=g->type_count || g->types[m->type].tag!=13 || g->types[m->type].reason ||
        (m->flags&g->layout.flags[XJAI_F_CONSTANT]) || m->offset>UINT64_MAX-address) return "JaiSelfTypeFieldUnproved";
    unsigned char data[8];const char *why=read_exact(r,address+m->offset,data,8);if (why) return why;
    uint32_t actual=xjai_type_at(g,little(data,8));
    if (actual==XJAI_NONE || g->types[actual].reason || g->types[actual].tag!=7) return "JaiTypePointerUnknown";
    unsigned work=0;
    int match=prefix_type(g,actual,declared,0,&work);
    if (match<0) return "JaiDynamicTypeTraversalLimit";
    if (!match) return "JaiDynamicTypeIncompatible";
    *resolved=actual;return NULL;
}

const char *xjai_array_span(const struct xjai_graph *g,uint32_t ti,uint64_t address,
    struct xjai_live_reader *r,struct xjai_array_span *out)
{
    if (!out) return "JaiInvalidArgument";
    *out=(struct xjai_array_span){0};
    if (!g || ti>=g->type_count || !r || !r->read) return "JaiInvalidArgument";
    const struct xjai_type *t=&g->types[ti];
    if (t->reason || t->tag!=8 || t->element>=g->type_count || g->types[t->element].reason) return "JaiArrayTypeUnproved";
    if (!address || address>UINT64_MAX-t->size) return "JaiValueAddressInvalid";
    uint64_t count=t->array_count,pointer=address,capacity=count;
    if (t->array_kind) {
        if (g->layout.profile!=XJAI_PROFILE || t->array_kind>2 || t->size!=(t->array_kind==1?16u:40u)) return "JaiArrayHeaderUnproved";
        unsigned char data[24];const char *why=read_exact(r,address,data,t->array_kind==1?16:24);
        if (why) return why;
        count=little(data,8);pointer=little(data+8,8);capacity=t->array_kind==1?count:little(data+16,8);
    }
    uint64_t size=g->types[t->element].size;
    if (count>INT64_MAX || capacity>INT64_MAX || count>capacity ||
        (size && capacity>UINT64_MAX/size) || pointer>UINT64_MAX-capacity*size || (capacity && !pointer) ||
        (!t->array_kind && count*size!=t->size)) return "JaiArrayHeaderInvalid";
    *out=(struct xjai_array_span){.data=pointer,.count=count,.capacity=capacity,.element=t->element};return NULL;
}
