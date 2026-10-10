#include "xrt_fdtreemap.h"
#include "fdflow_join.h"
#include <float.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#define NONE UINT32_MAX
struct builder {
    struct xrt_fdtreemap *tree;
    struct xrt_fdtreemap_options options;
    uint32_t node_capacity,text_capacity,hash_capacity,*slots;
};
static uint64_t sum64(uint64_t a,uint64_t b,uint32_t *flags)
{
    if (UINT64_MAX-a<b) {*flags|=XRT_FDT_SATURATED;return UINT64_MAX;}
    return a+b;
}
static double sumrate(double a,double b,uint32_t *flags)
{
    if (DBL_MAX-a<b) {*flags|=XRT_FDT_SATURATED;return DBL_MAX;}
    return a+b;
}
static void add(struct xrt_fdtreemap_metric *a,const struct xrt_fdtreemap_metric *b)
{
    a->descriptors+=b->descriptors;a->stale+=b->stale;a->deleted+=b->deleted;
    a->unknown_paths+=b->unknown_paths;a->stale_paths+=b->stale_paths;
    a->offset_measured+=b->offset_measured;a->flow_measured+=b->flow_measured;a->unexpanded+=b->unexpanded;a->flags|=b->flags;
    a->read_bytes=sum64(a->read_bytes,b->read_bytes,&a->flags);
    a->write_bytes=sum64(a->write_bytes,b->write_bytes,&a->flags);
    a->offset_rate=sumrate(a->offset_rate,b->offset_rate,&a->flags);
    a->read_rate=sumrate(a->read_rate,b->read_rate,&a->flags);
    a->write_rate=sumrate(a->write_rate,b->write_rate,&a->flags);
    if (b->last_ns>a->last_ns) a->last_ns=b->last_ns;
}
static void contribute(struct xrt_fdtreemap *t,uint32_t encoded,const struct xrt_fdtreemap_metric *m)
{
    uint32_t node=encoded&~XRT_FDT_OVERFLOW_BIT;
    add(encoded&XRT_FDT_OVERFLOW_BIT?&t->nodes[node].overflow:&t->nodes[node].own,m);
    do {add(&t->nodes[node].total,m);node=t->nodes[node].parent;} while (node!=NONE);
}
void xrt_fdtreemap_free(struct xrt_fdtreemap *t)
{
    if (t) {free(t->nodes);free(t->text);free(t->fd_nodes);free(t);}
}
static uint64_t hashkey(uint32_t parent,uint32_t kind,const char *s,size_t n)
{
    uint64_t h=UINT64_C(14695981039346656037)^((uint64_t)parent<<32)^kind;
    for (size_t i=0;i<n;++i) {h^=(unsigned char)s[i];h*=UINT64_C(1099511628211);}
    return h;
}
/* 1 success, 0 explicit capacity, -1 allocation failure. */
static int node(struct builder *b,uint32_t parent,uint32_t kind,const char *s,uint32_t n,uint32_t *out)
{
    struct xrt_fdtreemap *t=b->tree;uint64_t h=hashkey(parent,kind,s,n);
    if (b->hash_capacity) {
        uint32_t at=(uint32_t)h&(b->hash_capacity-1);
        while (b->slots[at]) {
            uint32_t i=b->slots[at]-1;const struct xrt_fdtreemap_node *p=&t->nodes[i];
            if (p->hash==h && p->parent==parent && p->kind==kind && p->name_length==n && !memcmp(t->text+p->name,s,n)) {*out=i;return 1;}
            at=(at+1)&(b->hash_capacity-1);
        }
    }
    if (t->count==b->options.max_nodes || n+1>b->options.max_text-t->text_length) return 0;
    if (t->count==b->node_capacity) {
        uint32_t cap=b->node_capacity?b->node_capacity*2:16;if (cap>b->options.max_nodes) cap=b->options.max_nodes;
        struct xrt_fdtreemap_node *p=realloc(t->nodes,cap*sizeof *p);if (!p) return -1;
        t->nodes=p;b->node_capacity=cap;
    }
    if (n+1>b->text_capacity-t->text_length) {
        uint32_t cap=b->text_capacity?b->text_capacity:256;
        while (cap<t->text_length+n+1) cap*=2;
        if (cap>b->options.max_text) cap=b->options.max_text;
        char *p=realloc(t->text,cap);if (!p) return -1;t->text=p;b->text_capacity=cap;
    }
    if (!b->hash_capacity || (t->count+1)*2>b->hash_capacity) {
        uint32_t cap=b->hash_capacity?b->hash_capacity*2:32;
        uint32_t *slots=calloc(cap,sizeof *slots);if (!slots) return -1;
        for (uint32_t i=0;i<t->count;++i) {
            uint32_t at=(uint32_t)t->nodes[i].hash&(cap-1);while (slots[at]) at=(at+1)&(cap-1);slots[at]=i+1;
        }
        free(b->slots);b->slots=slots;b->hash_capacity=cap;
    }
    uint32_t i=t->count++;struct xrt_fdtreemap_node *p=&t->nodes[i];
    *p=(struct xrt_fdtreemap_node){.parent=parent,.first_child=NONE,.next=NONE,.name=t->text_length,.name_length=n,.kind=kind,.sample_fd=NONE,.hash=h};
    memcpy(t->text+t->text_length,s,n);t->text[t->text_length+n]=0;t->text_length+=n+1;
    if (parent!=NONE) {p->next=t->nodes[parent].first_child;t->nodes[parent].first_child=i;}
    uint32_t at=(uint32_t)h&(b->hash_capacity-1);while (b->slots[at]) at=(at+1)&(b->hash_capacity-1);b->slots[at]=i+1;*out=i;return 1;
}
static int valid(const struct xrt_fd_snapshot *s)
{
    if (!s || s->fd_count>262144 || s->process_count>16384 || (s->fd_count && !s->fds) || (s->process_count && !s->processes)) return 0;
    uint32_t end=0;
    for (uint32_t i=0;i<s->process_count;++i) {
        const struct xrt_fd_process *p=&s->processes[i];
        if (p->pid<=0 || !p->start || (i && s->processes[i-1].pid>=p->pid) || p->first!=end || p->count>s->fd_count-end) return 0;
        int32_t previous=-1;
        for (uint32_t j=0;j<p->count;++j) {const struct xrt_fd *f=&s->fds[end+j];if (f->fd<=previous || f->kind>=XRT_FD_KINDS) return 0;previous=f->fd;}
        end+=p->count;
    }
    return end==s->fd_count;
}
static const char *path(const struct xrt_fd_snapshot *s,const struct xrt_fd *f)
{
    if (!s->strings || !f->link_length || f->link_length>4096 || (f->flags&XRT_FD_LINK_CUT) || f->link>=s->strings_length || f->link_length>=s->strings_length-f->link) return NULL;
    const char *p=s->strings+f->link;
    return p[f->link_length] || memchr(p,0,f->link_length)?NULL:p;
}
enum xrt_status xrt_fdtreemap_build(const struct xrt_fd_snapshot *s,const struct xrt_fdflow_live *flow,
    const struct xrt_fdtreemap_options *o,struct xrt_fdtreemap **out)
{
    if (out) *out=NULL;
    if (!out || !valid(s) || !o || o->max_nodes<16 || o->max_nodes>XRT_FDT_NODE_LIMIT || o->max_text<256 || o->max_text>XRT_FDT_TEXT_LIMIT || !o->max_depth || o->max_depth>32 ||
        (flow && (flow->counts.row_count>262144 || (flow->counts.row_count && (!flow->counts.rows || !flow->rates))))) return XRT_INVALID_ARGUMENT;
    struct xrt_fdtreemap *t=calloc(1,sizeof *t);if (!t) return XRT_OUT_OF_MEMORY;
    struct builder b={.tree=t,.options=*o};uint32_t root,buckets[XRT_FD_KINDS+1];
    const char *names[]={"[regular paths unavailable]","[directory paths unavailable]","[sockets]","[pipes]","[anonymous]","[memfd]","[device paths unavailable]","[other]","[paths unavailable]"};
    if (node(&b,NONE,0,"/",1,&root)!=1) goto oom;
    for (unsigned i=0;i<XRT_FD_KINDS+1;++i) if (node(&b,0,i+1,names[i],(uint32_t)strlen(names[i]),&buckets[i])!=1) goto oom;
    t->fd_nodes=calloc(s->fd_count?s->fd_count:1,sizeof *t->fd_nodes);if (!t->fd_nodes) goto oom;
    t->fd_count=s->fd_count;t->sequence=s->sequence;t->taken_ns=s->taken_ns;
    t->dropped_processes=s->dropped_processes;t->dropped_fds=s->dropped_fds;t->unscanned=s->unscanned;t->gone=s->gone;t->denied=s->hidden;
    for (uint32_t pi=0;pi<s->process_count;++pi) {
        const struct xrt_fd_process *p=&s->processes[pi];
        for (uint32_t j=0;j<p->count;++j) {
            uint32_t fi=p->first+j;const struct xrt_fd *f=&s->fds[fi];const char *name=path(s,f);
            int filesystem=f->kind==XRT_FD_REGULAR || f->kind==XRT_FD_DIRECTORY || f->kind==XRT_FD_DEVICE;
            uint32_t at=filesystem && name && *name=='/'?0:buckets[f->kind];
            int overflow=0;
            if (!at && f->link_length>1) {
                uint32_t start=1,depth=0;
                for (;;) {
                    uint32_t end=start;while (end<f->link_length && name[end]!='/') ++end;
                    if (end>start) { /* POSIX: "a//b" is "a/b"; trailing "/" names "a" */
                        if (depth++==o->max_depth) {overflow=1;break;}
                        uint32_t child;int r=node(&b,at,0,name+start,end-start,&child);
                        if (r<0) goto oom;
                        if (!r) {overflow=1;break;}
                        at=child;
                    }
                    if (end==f->link_length) break;
                    start=end+1;
                }
            }
            struct xrt_fdtreemap_metric m={.descriptors=1,.unexpanded=(uint32_t)overflow,.deleted=!!(f->flags&XRT_FD_DELETED),
                .stale=!!((p->flags&XRT_FDP_STALE) || (f->flags&(XRT_FD_INFO_STALE|XRT_FD_STAT_STALE|XRT_FD_LINK_STALE))),
                .stale_paths=!!((p->flags&XRT_FDP_STALE) || (f->flags&XRT_FD_LINK_STALE)),.unknown_paths=filesystem && (!name || *name!='/')};
            if (!m.stale && (f->flags&XRT_FD_INFO) && f->info_interval_ns && (f->kind==XRT_FD_REGULAR || f->kind==XRT_FD_MEMFD)) {
                if (!isfinite(f->rate) || f->rate<0) goto invalid;
                m.offset_measured=1;m.offset_rate=f->rate;
            }
            uint32_t encoded=at|(overflow?XRT_FDT_OVERFLOW_BIT:0);t->fd_nodes[fi]=encoded;
            for (uint32_t sample=at;sample!=NONE;sample=t->nodes[sample].parent)
                if (t->nodes[sample].sample_fd==NONE) {
                    t->nodes[sample].sample_fd=fi;
                    t->nodes[sample].holder=(struct xrt_fdtreemap_holder){.pid=p->pid,.fd=f->fd,.start=p->start};
                }
            contribute(t,encoded,&m);
        }
    }
    if (flow) {
        unsigned char *seen=calloc(s->fd_count?s->fd_count:1,1);if (!seen) goto oom;
        t->flow_present=1;t->flow_running=flow->stream.running;t->flow_status=flow->status;t->flow_sequence=flow->sequence;t->flow_flags=flow->stream.flags;t->count_flags=flow->counts.flags;
        for (uint32_t i=0;i<flow->counts.row_count;++i) {
            const struct xrt_fdflow_count_row *r=&flow->counts.rows[i];if (!r->active) continue;
            uint32_t pi=NONE,fi=xrt_fdflow_match(s,r,&pi);
            if (fi==NONE || (s->fds[fi].flags&XRT_FD_LINK_STALE)) {++t->unmatched_rows;continue;}
            if (seen[fi] || !isfinite(flow->rates[i].read) || !isfinite(flow->rates[i].write) || flow->rates[i].read<0 || flow->rates[i].write<0) {free(seen);goto invalid;}
            seen[fi]=1;++t->matched_rows;
            struct xrt_fdtreemap_metric m={.flow_measured=1,.read_bytes=r->read_bytes,.write_bytes=r->write_bytes,.last_ns=r->last_ns,
                .read_rate=flow->stream.running?flow->rates[i].read:0,.write_rate=flow->stream.running?flow->rates[i].write:0};
            contribute(t,t->fd_nodes[fi],&m);
        }
        free(seen);
    }
    t->allocated_bytes=sizeof *t+b.node_capacity*sizeof *t->nodes+b.text_capacity+(s->fd_count?s->fd_count:1)*sizeof *t->fd_nodes;
    free(b.slots);*out=t;return XRT_OK;
invalid:
    free(b.slots);xrt_fdtreemap_free(t);return XRT_INVALID_ARGUMENT;
oom:
    free(b.slots);xrt_fdtreemap_free(t);return XRT_OUT_OF_MEMORY;
}
enum xrt_status xrt_fdtreemap_path(const struct xrt_fdtreemap *t,uint32_t node,char *out,size_t size,size_t *needed)
{
    if (!t || node>=t->count || !needed || (!out && size)) return XRT_INVALID_ARGUMENT;
    uint32_t chain[33],n=0,at=node;size_t bytes=1;
    while (at && n<33) {chain[n++]=at;bytes+=t->nodes[at].name_length+1;at=t->nodes[at].parent;}
    if (at || (t->nodes[node].kind && n!=1)) return XRT_INVALID_ARGUMENT;
    if (t->nodes[node].kind) bytes=t->nodes[node].name_length+1;
    else if (!n) bytes=2;
    *needed=bytes;if (size<bytes) return XRT_BUFFER_TOO_SMALL;
    size_t pos=0;
    if (t->nodes[node].kind) {memcpy(out,t->text+t->nodes[node].name,bytes);return XRT_OK;}
    if (!n) out[pos++]='/';
    while (n) {const struct xrt_fdtreemap_node *p=&t->nodes[chain[--n]];out[pos++]='/';memcpy(out+pos,t->text+p->name,p->name_length);pos+=p->name_length;}
    out[pos]=0;return XRT_OK;
}
enum xrt_status xrt_fdtreemap_relocate(const struct xrt_fdtreemap *old,uint32_t node,
    const struct xrt_fdtreemap *fresh,uint32_t *out)
{
    if (out) *out=NONE;
    if (!old || !fresh || !out || node>=old->count || !fresh->count) return XRT_INVALID_ARGUMENT;
    uint32_t chain[33],count=0,at=node;
    while (at && count<33) {chain[count++]=at;at=old->nodes[at].parent;}
    if (at) return XRT_INVALID_ARGUMENT;
    at=0;
    while (count) {
        const struct xrt_fdtreemap_node *wanted=&old->nodes[chain[--count]];
        uint32_t child=fresh->nodes[at].first_child;
        while (child!=NONE) {
            const struct xrt_fdtreemap_node *n=&fresh->nodes[child];
            if (n->kind==wanted->kind && n->name_length==wanted->name_length &&
                !memcmp(fresh->text+n->name,old->text+wanted->name,wanted->name_length)) break;
            child=n->next;
        }
        if (child==NONE) return XRT_STALE_SNAPSHOT;
        at=child;
    }
    *out=at;return XRT_OK;
}
enum xrt_status xrt_fdtreemap_holder(const struct xrt_fdtreemap *t,uint32_t node,struct xrt_fdtreemap_holder *out)
{
    if (out) memset(out,0,sizeof *out);
    if (!t || !out || node>=t->count) return XRT_INVALID_ARGUMENT;
    if (t->nodes[node].sample_fd==NONE) return XRT_STALE_SNAPSHOT;
    *out=t->nodes[node].holder;return XRT_OK;
}
struct item {struct xrt_fdtreemap_tile tile;const char *name;};
static int by_weight(const void *a,const void *b)
{
    const struct item *x=a,*y=b;
    if (x->tile.metric.descriptors!=y->tile.metric.descriptors) return x->tile.metric.descriptors>y->tile.metric.descriptors?-1:1;
    int r=strcmp(x->name,y->name);return r?r:x->tile.kind<y->tile.kind?-1:x->tile.kind!=y->tile.kind;
}
static int by_name(const void *a,const void *b)
{
    const struct item *x=a,*y=b;int r=strcmp(x->name,y->name);return r?r:x->tile.kind<y->tile.kind?-1:x->tile.kind!=y->tile.kind;
}
static void divide(struct xrt_fdtreemap_tile *tiles,uint32_t n,double x,double y,double w,double h,double aspect)
{
    if (n==1) {tiles[0].x=(float)x;tiles[0].y=(float)y;tiles[0].w=(float)w;tiles[0].h=(float)h;return;}
    uint64_t total=0;for (uint32_t i=0;i<n;++i) total+=tiles[i].metric.descriptors;
    uint64_t left=tiles[0].metric.descriptors;uint32_t split=1;
    while (split+1<n && left+tiles[split].metric.descriptors<=total/2) left+=tiles[split++].metric.descriptors;
    double f=(double)left/(double)total;
    if (w*aspect>=h) {divide(tiles,split,x,y,w*f,h,aspect);divide(tiles+split,n-split,x+w*f,y,w*(1-f),h,aspect);}
    else {divide(tiles,split,x,y,w,h*f,aspect);divide(tiles+split,n-split,x,y+h*f,w,h*(1-f),aspect);}
}
void xrt_fdtreemap_layout_free(struct xrt_fdtreemap_layout *l) {if (l) {free(l->tiles);free(l);}}
enum xrt_status xrt_fdtreemap_layout(const struct xrt_fdtreemap *t,uint32_t node,uint32_t max_tiles,double aspect,struct xrt_fdtreemap_layout **out)
{
    if (out) *out=NULL;
    if (!out || !t || node>=t->count || !max_tiles || max_tiles>1024 || !isfinite(aspect) || aspect<.01 || aspect>100) return XRT_INVALID_ARGUMENT;
    const struct xrt_fdtreemap_node *p=&t->nodes[node];uint32_t count=!!p->own.descriptors+!!p->overflow.descriptors;
    for (uint32_t at=p->first_child;at!=NONE;at=t->nodes[at].next) if (t->nodes[at].total.descriptors) ++count;
    struct item *items=calloc(count?count:1,sizeof *items);struct xrt_fdtreemap_layout *l=calloc(1,sizeof *l);
    if (!items || !l) {free(items);free(l);return XRT_OUT_OF_MEMORY;}
    uint32_t n=0;
    if (p->own.descriptors) items[n++]=(struct item){{.node=node,.kind=XRT_FDT_DIRECT,.metric=p->own},"[this path]"};
    if (p->overflow.descriptors) items[n++]=(struct item){{.node=node,.kind=XRT_FDT_OVERFLOW,.metric=p->overflow},"[unexpanded]"};
    for (uint32_t at=p->first_child;at!=NONE;at=t->nodes[at].next) if (t->nodes[at].total.descriptors)
        items[n++]=(struct item){{.node=at,.kind=XRT_FDT_CHILD,.metric=t->nodes[at].total},t->text+t->nodes[at].name};
    qsort(items,n,sizeof *items,by_weight);
    if (n>max_tiles) {
        struct item other={{.node=NONE,.kind=XRT_FDT_OTHER,.hidden_items=n-max_tiles+1},"[other]"};
        for (uint32_t i=max_tiles-1;i<n;++i) add(&other.tile.metric,&items[i].tile.metric);
        l->hidden_items=other.tile.hidden_items;items[max_tiles-1]=other;n=max_tiles;
    }
    qsort(items,n,sizeof *items,by_name);l->count=n;l->tiles=calloc(n?n:1,sizeof *l->tiles);
    if (!l->tiles) {free(items);free(l);return XRT_OUT_OF_MEMORY;}
    for (uint32_t i=0;i<n;++i) l->tiles[i]=items[i].tile;
    if (n) divide(l->tiles,n,0,0,1,1,aspect);
    l->allocated_bytes=sizeof *l+(n?n:1)*sizeof *l->tiles;free(items);*out=l;return XRT_OK;
}
