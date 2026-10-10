#include "jai_live_internal.h"
#include <string.h>

static const struct xjai_member *field(const struct xjai_graph *g,const struct xjai_type *t,const char *name)
{
    const struct xjai_member *found=NULL;
    for (uint32_t i=0;i<t->member_count;++i) {
        const struct xjai_member *m=&g->members[t->first_member+i];
        if (m->flags&(g->layout.flags[XJAI_F_CONSTANT]|g->layout.flags[XJAI_F_IMPORTED])) continue;
        if (strcmp(g->text+m->name,name)) continue;
        if (found || m->reason || m->type>=g->type_count || g->types[m->type].reason ||
            m->offset>t->size || g->types[m->type].size>t->size-m->offset) return NULL;
        found=m;
    }
    return found;
}
static int overlap(const struct xjai_graph *g,const struct xjai_member *a,const struct xjai_member *b)
{
    return a->offset<b->offset+g->types[b->type].size && b->offset<a->offset+g->types[a->type].size;
}
const char *xjai_container_read(const struct xjai_graph *g,uint32_t ti,uint64_t address,
    uint64_t start,struct xjai_container_row *rows,size_t capacity,struct xjai_live_reader *reader,
    struct xjai_container_page *out)
{
    if (!out) return "JaiInvalidArgument";
    *out=(struct xjai_container_page){0};
    if (!g || ti>=g->type_count || !reader || !reader->read || !rows || !capacity || capacity>XJAI_CONTAINER_ROWS) return "JaiInvalidArgument";
    const struct xjai_type *t=&g->types[ti];
    if (t->reason) return t->reason;
    if (!address || address>UINT64_MAX-t->size) return "JaiValueAddressInvalid";
    const char *why;struct xjai_array_span span;
    if (t->tag==8) {
        if ((why=xjai_array_span(g,ti,address,reader,&span))) return why;
        if (!g->types[span.element].size) return "JaiContainerElementUnproved";
        if (start>span.count) return "JaiValuePageOutOfRange";
        uint64_t n=span.count-start;if (n>capacity) n=capacity;
        for (uint32_t i=0;i<n;++i) rows[i]=(struct xjai_container_row){span.data+(start+i)*g->types[span.element].size,start+i,span.element};
        *out=(struct xjai_container_page){span.count,span.capacity,(uint32_t)n,start!=0 || n<span.count};return NULL;
    }
    if (t->tag!=7) return "JaiContainerTypeUnsupported";
    const char *name=g->text+t->name;
    if (!strcmp(name,"Table")) return "JaiTableOccupancyUnproved";
    if (strcmp(name,"Bucket")) return "JaiContainerTypeUnsupported";
    const struct xjai_member *occupied=field(g,t,"occupied"),*data=field(g,t,"data"),*count=field(g,t,"count");
    if (!occupied || !data || !count || overlap(g,occupied,data) || overlap(g,occupied,count) || overlap(g,data,count)) return "JaiBucketLayoutUnproved";
    const struct xjai_type *o=&g->types[occupied->type],*d=&g->types[data->type],*c=&g->types[count->type];
    if (o->tag!=8 || o->array_kind || o->element>=g->type_count ||
        g->types[o->element].reason || g->types[o->element].tag!=2 || g->types[o->element].size!=1 ||
        o->array_count!=o->size || d->tag!=8 || d->array_kind || o->array_count!=d->array_count ||
        c->tag!=0 || c->size!=8 || !c->is_signed) return "JaiBucketLayoutUnproved";
    if (o->array_count>XJAI_BUCKET_SLOTS) return "JaiBucketSlotLimit";
    if ((why=xjai_array_span(g,data->type,address+data->offset,reader,&span))) return why;
    if (!g->types[span.element].size) return "JaiContainerElementUnproved";
    unsigned char flags[XJAI_BUCKET_SLOTS],word[8];uint64_t total=0;
    if ((why=read_exact(reader,address+count->offset,word,8))) return why;
    uint64_t expected=little(word,8);
    if (expected>span.count) return "JaiBucketCountMismatch";
    if (o->array_count && (why=read_exact(reader,address+occupied->offset,flags,(size_t)o->array_count))) return why;
    for (uint64_t i=0;i<o->array_count;++i) {
        if (flags[i]>1) return "JaiBucketOccupancyInvalid";
        total+=flags[i];
    }
    if (total!=expected) return "JaiBucketCountMismatch";
    if (start>total) return "JaiValuePageOutOfRange";
    uint64_t seen=0;uint32_t n=0;
    for (uint64_t i=0;i<span.count && n<capacity;++i) if (flags[i] && seen++>=start)
        rows[n++]=(struct xjai_container_row){span.data+i*g->types[span.element].size,i,span.element};
    *out=(struct xjai_container_page){total,span.count,n,start!=0 || n<total};return NULL;
}
const char *xjai_instance_candidate(const struct xjai_graph *g,uint32_t declared,
    uint32_t member,uint64_t hit,struct xjai_live_reader *reader,uint64_t *address,uint32_t *actual)
{
    if (!address || !actual) return "JaiInvalidArgument";
    *address=0;*actual=XJAI_NONE;
    if (!g || declared>=g->type_count || member>=g->member_count) return "JaiInvalidArgument";
    const struct xjai_member *m=&g->members[member];
    if (m->offset>=hit) return "JaiCandidateAddressInvalid";
    uint64_t base=hit-m->offset;uint32_t resolved;
    const char *why=xjai_self_type(g,declared,base,member,reader,&resolved);
    if (why) return why;
    if (base>UINT64_MAX-g->types[resolved].size) return "JaiCandidateAddressInvalid";
    *address=base;*actual=resolved;return NULL;
}
