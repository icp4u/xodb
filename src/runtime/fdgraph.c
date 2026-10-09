#include "xrt_fdgraph.h"
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#define PROCESS_LIMIT 16384u
#define FD_LIMIT 262144u
#define PEER_LIMIT 262144u
struct graph_key {
    uint64_t device, inode;
    uint32_t kind, unique, process, fd;
};
struct socket_key { uint64_t inode; uint32_t node; };
static int key_compare(const void *left, const void *right)
{
    const struct graph_key *a=left,*b=right;
#define CMP(field) if (a->field!=b->field) return a->field<b->field ? -1 : 1
    CMP(unique); CMP(kind); CMP(device); CMP(inode); CMP(process); CMP(fd);
#undef CMP
    return 0;
}
static int same_key(const struct graph_key *a,const struct graph_key *b)
{
    return a->unique==b->unique && a->kind==b->kind && a->device==b->device && a->inode==b->inode;
}
static int socket_compare(const void *left,const void *right)
{
    const struct socket_key *a=left,*b=right;
    return a->inode<b->inode ? -1 : a->inode!=b->inode;
}
static uint32_t socket_node(const struct socket_key *keys,uint32_t count,uint32_t inode)
{
    uint32_t low=0,high=count;
    while (low<high) { uint32_t mid=low+(high-low)/2; if (keys[mid].inode<inode) low=mid+1; else high=mid; }
    if (low==count || keys[low].inode!=inode || (low+1<count && keys[low+1].inode==inode)) return UINT32_MAX;
    return keys[low].node;
}
static int edge_compare(const void *left,const void *right)
{
    const struct xrt_fdgraph_edge *a=left,*b=right;
    if (a->from!=b->from) return a->from<b->from ? -1 : 1;
    return a->to<b->to ? -1 : a->to!=b->to;
}
int xrt_fd_identity_current(const struct xrt_fd_snapshot *s,const struct xrt_fd_process *p,const struct xrt_fd *f)
{
    if (!s || !p || !f || (p->flags&XRT_FDP_STALE) || !(f->flags&XRT_FD_STAT) || !f->inode) return 0;
    if (!(f->flags&XRT_FD_STAT_STALE)) return 1;
    /* Pipes/sockets refresh identity by reading their kernel inode-bearing
     * link. fdinfo and nonidentity stat fields may deliberately stay cached. */
    const char *prefix=f->kind==XRT_FD_SOCKET ? "socket:[" : f->kind==XRT_FD_PIPE ? "pipe:[" : NULL;
    if (!prefix || (f->flags&(XRT_FD_LINK_STALE|XRT_FD_LINK_CUT)) || !s->strings ||
        f->link>=s->strings_length || f->link_length>=s->strings_length-f->link) return 0;
    const char *text=s->strings+f->link;size_t n=strlen(prefix),end=f->link_length;
    if (end<n+2 || memcmp(text,prefix,n) || text[end-1]!=']' || text[end]) return 0;
    uint64_t inode=0;
    for (size_t i=n;i+1<end;++i) {
        if (text[i]<'0' || text[i]>'9' || inode>(UINT64_MAX-(uint64_t)(text[i]-'0'))/10) return 0;
        inode=inode*10+(unsigned)(text[i]-'0');
    }
    return inode==f->inode;
}
static uint32_t descriptor_flags(const struct xrt_fd_snapshot *s,const struct xrt_fd_process *p,const struct xrt_fd *f)
{
    uint32_t flags=0;
    if ((p->flags&XRT_FDP_STALE) || (f->flags&(XRT_FD_STAT_STALE|XRT_FD_INFO_STALE|XRT_FD_LINK_STALE))) flags|=XRT_FDG_STALE;
    if (!xrt_fd_identity_current(s,p,f)) flags|=XRT_FDG_IDENTITY_STALE;
    if (f->flags&XRT_FD_DELETED) flags|=XRT_FDG_DELETED;
    if (!(f->flags&XRT_FD_STAT) || !f->inode || f->kind==XRT_FD_ANON || f->kind==XRT_FD_OTHER) flags|=XRT_FDG_IDENTITY_UNKNOWN;
    return flags;
}
void xrt_fdgraph_free(struct xrt_fdgraph *g)
{
    if (!g) return;
    free(g->nodes); free(g->edges); free(g->members); free(g->groups); free(g);
}
struct cgroup_key {const char *path;uint32_t process;};
static int cgroup_compare(const void *left,const void *right)
{
    const struct cgroup_key *a=left,*b=right;return strcmp(a->path,b->path);
}
static int graph_groups(const struct xrt_fd_snapshot *s,struct xrt_fdgraph *g)
{
    g->groups=calloc(g->processes ? g->processes : 1,sizeof *g->groups);
    struct cgroup_key *keys=calloc(s->process_count ? s->process_count : 1,sizeof *keys);
    if (!g->groups || !keys) {free(keys);return 0;}
    g->allocated_bytes+=(g->processes ? g->processes : 1)*sizeof *g->groups;
    uint32_t count=0;
    for (uint32_t i=0;i<g->processes;++i) {
        g->groups[i]=(UINT64_C(1)<<63)|((uint64_t)i+1);
        if (i>=s->process_count) continue;
        const struct xrt_fd_process *p=&s->processes[i];
        if ((p->flags&XRT_FDP_STALE) || p->cgroup_status!=XRT_FD_CGROUP_CURRENT || !p->cgroup_length ||
            !s->strings || p->cgroup>=s->strings_length || p->cgroup_length>=s->strings_length-p->cgroup) continue;
        const char *path=s->strings+p->cgroup;
        if (path[0]!='/' || path[p->cgroup_length] || memchr(path,0,p->cgroup_length)) continue;
        keys[count++]=(struct cgroup_key){path,i};
    }
    qsort(keys,count,sizeof *keys,cgroup_compare);
    for (uint32_t i=0;i<count;++i) {
        if (!i || strcmp(keys[i-1].path,keys[i].path)) ++g->cgroup_count;
        g->groups[keys[i].process]=g->cgroup_count;
    }
    g->cgroup_processes=count;free(keys);return 1;
}
enum xrt_status xrt_fdgraph_build(const struct xrt_fd_snapshot *s,
                                 const struct xrt_unix_peer *peers,uint32_t peer_count,
                                 struct xrt_fdgraph **out)
{
    if (out) *out=NULL;
    if (!s || !out || (s->process_count && !s->processes) || (s->fd_count && !s->fds) ||
        (s->unseen_count && !s->unseen) || (peer_count && !peers) || s->process_count>PROCESS_LIMIT ||
        s->unseen_count>PROCESS_LIMIT || s->fd_count>FD_LIMIT || peer_count>PEER_LIMIT) return XRT_INVALID_ARGUMENT;
    uint32_t end=0;
    for (uint32_t i=0;i<s->process_count;++i) {
        const struct xrt_fd_process *p=&s->processes[i];
        if (p->pid<=0 || !p->start || p->first!=end || p->count>s->fd_count-end ||
            (i && s->processes[i-1].pid>=p->pid)) return XRT_INVALID_ARGUMENT;
        int32_t previous=-1;
        for (uint32_t j=0;j<p->count;++j) {
            const struct xrt_fd *f=&s->fds[p->first+j];
            if (f->kind>=XRT_FD_KINDS || f->fd<=previous) return XRT_INVALID_ARGUMENT;
            previous=f->fd;
        }
        end+=p->count;
    }
    if (end!=s->fd_count) return XRT_INVALID_ARGUMENT;
    uint32_t visible=0;
    for (uint32_t i=0;i<s->unseen_count;++i) {
        int32_t pid=s->unseen[i].pid;
        if (pid<=0 || (i && s->unseen[i-1].pid>=pid)) return XRT_INVALID_ARGUMENT;
        while (visible<s->process_count && s->processes[visible].pid<pid) ++visible;
        if (visible<s->process_count && s->processes[visible].pid==pid) return XRT_INVALID_ARGUMENT;
    }
    for (uint32_t i=0;i<peer_count;++i)
        if (!peers[i].inode || (i && peers[i-1].inode>=peers[i].inode)) return XRT_INVALID_ARGUMENT;
    struct xrt_fdgraph *g=calloc(1,sizeof *g);
    if (!g) return XRT_OUT_OF_MEMORY;
    size_t node_capacity=(size_t)s->process_count+s->unseen_count+s->fd_count;
    size_t edge_capacity=(size_t)s->fd_count+peer_count;
    g->nodes=calloc(node_capacity ? node_capacity : 1,sizeof *g->nodes);
    g->edges=calloc(edge_capacity ? edge_capacity : 1,sizeof *g->edges);
    g->members=calloc(s->fd_count ? s->fd_count : 1,sizeof *g->members);
    struct graph_key *keys=calloc(s->fd_count ? s->fd_count : 1,sizeof *keys);
    struct socket_key *sockets=calloc(s->fd_count ? s->fd_count : 1,sizeof *sockets);
    if (!g->nodes || !g->edges || !g->members || !keys || !sockets) {
        free(keys); free(sockets); xrt_fdgraph_free(g); return XRT_OUT_OF_MEMORY;
    }
    g->allocated_bytes=sizeof *g+(node_capacity ? node_capacity : 1)*sizeof *g->nodes+
        (edge_capacity ? edge_capacity : 1)*sizeof *g->edges+
        (s->fd_count ? s->fd_count : 1)*sizeof *g->members;
    g->sequence=s->sequence;g->taken_ns=s->taken_ns;
    g->dropped_processes=s->dropped_processes;g->dropped_descriptors=s->dropped_fds;
    g->unscanned_processes=s->unscanned;g->gone_processes=s->gone;
    g->processes=s->process_count+s->unseen_count;
    for (uint32_t i=0;i<s->process_count;++i) {
        const struct xrt_fd_process *p=&s->processes[i];
        struct xrt_fdgraph_node *n=&g->nodes[g->node_count++];
        *n=(struct xrt_fdgraph_node){.type=XRT_FDG_PROCESS,.source_process=i,.source_fd=UINT32_MAX,
            .pid=p->pid,.start=p->start,.descriptors=p->count,.holders=1};
        if (p->flags&XRT_FDP_STALE) n->flags|=XRT_FDG_STALE;
        if (p->flags&XRT_FDP_TRUNCATED) n->flags|=XRT_FDG_TRUNCATED;
        for (uint32_t j=0;j<p->count;++j) {
            uint32_t at=p->first+j;const struct xrt_fd *f=&s->fds[at];
            uint32_t flags=descriptor_flags(s,p,f);
            struct graph_key *k=&keys[at];
            *k=(struct graph_key){.device=f->device,.inode=f->inode,.kind=f->kind,.process=i,.fd=at};
            if (flags&XRT_FDG_IDENTITY_UNKNOWN) {k->unique=at+1;++g->unknown_descriptors;}
            if (flags&XRT_FDG_STALE) ++g->stale_descriptors;
        }
    }
    for (uint32_t i=0;i<s->unseen_count;++i) {
        const struct xrt_fd_unseen *p=&s->unseen[i];
        struct xrt_fdgraph_node *n=&g->nodes[g->node_count++];
        *n=(struct xrt_fdgraph_node){.type=XRT_FDG_PROCESS,.source_process=UINT32_MAX,.source_fd=UINT32_MAX,
            .pid=p->pid,.start=p->start,.flags=p->kernel ? XRT_FDG_KERNEL : XRT_FDG_DENIED};
        if (p->stale) n->flags|=XRT_FDG_STALE;
        if (!p->kernel) ++g->denied_processes;
    }
    qsort(keys,s->fd_count,sizeof *keys,key_compare);
    uint32_t socket_count=0;
    for (uint32_t i=0;i<s->fd_count;) {
        const struct graph_key *key=&keys[i];uint32_t index=g->node_count++;
        struct xrt_fdgraph_node *n=&g->nodes[index];
        *n=(struct xrt_fdgraph_node){.type=XRT_FDG_RESOURCE,.kind=key->kind,.source_process=key->process,
            .source_fd=key->fd,.device=key->device,.inode=key->inode};
        if (key->unique) n->flags|=XRT_FDG_IDENTITY_UNKNOWN;
        uint32_t j=i;
        while (j<s->fd_count && same_key(key,&keys[j])) {
            uint32_t process=keys[j].process;
            struct xrt_fdgraph_edge *e=&g->edges[g->edge_count++];
            *e=(struct xrt_fdgraph_edge){.from=process,.to=index,.kind=XRT_FDG_HOLDS,.source_fd=keys[j].fd};
            do {
                const struct xrt_fd *f=&s->fds[keys[j].fd];
                uint32_t flags=descriptor_flags(s,&s->processes[process],f);
                e->flags|=flags;n->flags|=flags;++e->descriptors;++n->descriptors;
                g->members[g->member_count++]=(struct xrt_fdgraph_member){.process=process,.resource=index,.source_fd=keys[j].fd,.flags=flags};
                if (!(flags&XRT_FDG_STALE) && (f->flags&XRT_FD_INFO) && f->info_interval_ns &&
                    (f->kind==XRT_FD_REGULAR || f->kind==XRT_FD_MEMFD) && isfinite(f->rate) && f->rate>=0) {
                    ++e->measured_descriptors;++n->measured_descriptors;
                    ++g->nodes[process].measured_descriptors;e->offset_rate+=f->rate;
                }
                ++j;
            } while (j<s->fd_count && same_key(key,&keys[j]) && keys[j].process==process);
            ++n->holders;n->offset_rate+=e->offset_rate;
            g->nodes[process].offset_rate+=e->offset_rate;
        }
        if (n->kind==XRT_FD_SOCKET && !(n->flags&(XRT_FDG_IDENTITY_UNKNOWN|XRT_FDG_IDENTITY_STALE)))
            sockets[socket_count++]=(struct socket_key){.inode=n->inode,.node=index};
        ++g->resources;i=j;
    }
    qsort(sockets,socket_count,sizeof *sockets,socket_compare);
    uint32_t first_peer=g->edge_count;
    for (uint32_t i=0;i<peer_count;++i) {
        if (!peers[i].peer) continue;
        uint32_t from=socket_node(sockets,socket_count,peers[i].inode),to=socket_node(sockets,socket_count,peers[i].peer);
        if (from==UINT32_MAX || to==UINT32_MAX) {++g->unmatched_peers;continue;}
        if (from==to) continue;
        if (from>to) {uint32_t swap=from;from=to;to=swap;}
        g->edges[g->edge_count++]=(struct xrt_fdgraph_edge){.from=from,.to=to,.kind=XRT_FDG_UNIX_PEER,.source_fd=UINT32_MAX};
    }
    qsort(g->edges+first_peer,g->edge_count-first_peer,sizeof *g->edges,edge_compare);
    uint32_t write=first_peer;
    for (uint32_t i=first_peer;i<g->edge_count;++i) {
        if (write>first_peer && !edge_compare(&g->edges[write-1],&g->edges[i])) continue;
        g->edges[write++]=g->edges[i];
    }
    g->edge_count=write;g->peer_edges=write-first_peer;
    free(keys);free(sockets);
    if (!graph_groups(s,g)) {xrt_fdgraph_free(g);return XRT_OUT_OF_MEMORY;}
    *out=g;return XRT_OK;
}

struct group_key { uint64_t group; uint32_t process; };
static int group_compare(const void *left,const void *right)
{
    const struct group_key *a=left,*b=right;
    if (a->group!=b->group) return a->group<b->group ? -1 : 1;
    return a->process<b->process ? -1 : a->process!=b->process;
}
void xrt_fdgraph_projection_free(struct xrt_fdgraph_projection *p)
{
    if (!p) return;
    free(p->stars);free(p->particles);free(p->process_to_star);free(p);
}
enum xrt_status xrt_fdgraph_project(const struct xrt_fdgraph *g,
                                   const struct xrt_fdgraph_project_options *o,
                                   struct xrt_fdgraph_projection **out)
{
    if (out) *out=NULL;
    if (!g || !o || !out || !o->max_stars || o->max_stars>1024 ||
        o->max_particles<o->max_stars*XRT_FD_KINDS || o->max_particles>16384 ||
        (o->focus_process!=UINT32_MAX && o->focus_process>=g->processes)) return XRT_INVALID_ARGUMENT;
    uint32_t count=0;
    for (uint32_t i=0;i<g->processes;++i)
        if ((o->focus_process==UINT32_MAX || o->focus_process==i) &&
            (!o->focus_group || g->groups[i]==o->focus_group)) ++count;
    struct xrt_fdgraph_projection *v=calloc(1,sizeof *v);
    struct group_key *keys=calloc(count ? count : 1,sizeof *keys);
    uint32_t *star=malloc((g->processes ? g->processes : 1)*sizeof *star);
    if (!v || !keys || !star) {free(v);free(keys);free(star);return XRT_OUT_OF_MEMORY;}
    uint32_t stars=count<o->max_stars ? count : o->max_stars;
    uint32_t particles=o->focus_process==UINT32_MAX ? stars*XRT_FD_KINDS :
        (g->nodes[o->focus_process].descriptors<o->max_particles-XRT_FD_KINDS ?
         g->nodes[o->focus_process].descriptors+XRT_FD_KINDS : o->max_particles);
    v->stars=calloc(stars ? stars : 1,sizeof *v->stars);
    v->particles=calloc(particles ? particles : 1,sizeof *v->particles);
    if (!v->stars || !v->particles) {
        free(keys);free(star);xrt_fdgraph_projection_free(v);return XRT_OUT_OF_MEMORY;
    }
    v->allocated_bytes=sizeof *v+(stars ? stars : 1)*sizeof *v->stars+
        (particles ? particles : 1)*sizeof *v->particles;
    for (uint32_t i=0;i<g->processes;++i) star[i]=UINT32_MAX;
    uint32_t used_keys=0;
    const uint64_t *groups=o->groups ? o->groups : o->collapse_cgroups ? g->groups : NULL;
    for (uint32_t process=0;process<g->processes;++process) {
        if ((o->focus_process!=UINT32_MAX && o->focus_process!=process) ||
            (o->focus_group && g->groups[process]!=o->focus_group)) continue;
        keys[used_keys++]=(struct group_key){.group=groups ? groups[process] : process,.process=process};
    }
    qsort(keys,count,sizeof *keys,group_compare);
    uint32_t at=0;
    for (uint32_t i=0;i<count;++i) {
        if (i && keys[i].group!=keys[i-1].group && at+1<stars) ++at;
        uint32_t process=keys[i].process;star[process]=at;
        struct xrt_fdgraph_star *s=&v->stars[at];
        if (!s->processes) {s->source_node=process;s->sample_node=process;s->group=keys[i].group;}
        else {s->source_node=UINT32_MAX;if (s->group!=keys[i].group) s->mixed_groups=1;}
        ++s->processes;s->descriptors+=g->nodes[process].descriptors;
        if (g->nodes[process].flags&XRT_FDG_DENIED) ++s->denied;
        if (g->nodes[process].flags&XRT_FDG_STALE) ++s->stale;
    }
    v->star_count=count ? at+1 : 0;v->represented_processes=count;
    uint32_t base=v->star_count*XRT_FD_KINDS;
    v->particle_count=base;
    for (uint32_t i=0;i<base;++i) {
        v->particles[i]=(struct xrt_fdgraph_particle){.star=i/XRT_FD_KINDS,.kind=i%XRT_FD_KINDS,
            .source_node=UINT32_MAX,.source_fd=UINT32_MAX};
    }
    for (uint32_t i=0;i<g->member_count;++i) {
        const struct xrt_fdgraph_member *m=&g->members[i];uint32_t owner=star[m->process];
        if (owner==UINT32_MAX) continue;
        const struct xrt_fdgraph_node *n=&g->nodes[m->resource];
        struct xrt_fdgraph_particle *p;
        if (o->focus_process!=UINT32_MAX && v->particle_count<particles) {
            p=&v->particles[v->particle_count++];
            *p=(struct xrt_fdgraph_particle){.star=owner,.kind=n->kind,.source_node=m->resource,.source_fd=m->source_fd};
        } else p=&v->particles[owner*XRT_FD_KINDS+n->kind];
        ++p->descriptors;++v->represented_descriptors;
        if (m->flags&XRT_FDG_DELETED) ++p->deleted;
        if (m->flags&XRT_FDG_STALE) ++p->stale;
    }
    uint32_t used=0;
    for (uint32_t i=0;i<v->particle_count;++i) if (v->particles[i].descriptors) {
        if (v->particles[i].source_fd==UINT32_MAX) ++v->grouped_particles;
        v->particles[used++]=v->particles[i];
    }
    v->particle_count=used;
    for (uint32_t i=0;i<v->star_count;++i) if (v->stars[i].processes>1) ++v->grouped_stars;
    v->process_to_star=star;v->allocated_bytes+=(g->processes ? g->processes : 1)*sizeof *star;
    free(keys);*out=v;return XRT_OK;
}

struct xrt_fdgraph *xrt_fdgraph_copy(const struct xrt_fdgraph *source)
{
    if (!source) return NULL;
    struct xrt_fdgraph *g=malloc(sizeof *g);
    if (!g) return NULL;
    *g=*source;
    g->nodes=malloc((source->node_count ? source->node_count : 1)*sizeof *g->nodes);
    g->edges=malloc((source->edge_count ? source->edge_count : 1)*sizeof *g->edges);
    g->members=malloc((source->member_count ? source->member_count : 1)*sizeof *g->members);
    g->groups=malloc((source->processes ? source->processes : 1)*sizeof *g->groups);
    if (!g->nodes || !g->edges || !g->members || !g->groups) {xrt_fdgraph_free(g);return NULL;}
    if (g->processes) memcpy(g->groups,source->groups,g->processes*sizeof *g->groups);
    if (g->node_count) memcpy(g->nodes,source->nodes,g->node_count*sizeof *g->nodes);
    if (g->edge_count) memcpy(g->edges,source->edges,g->edge_count*sizeof *g->edges);
    if (g->member_count) memcpy(g->members,source->members,g->member_count*sizeof *g->members);
    g->allocated_bytes=sizeof *g+(g->node_count ? g->node_count : 1)*sizeof *g->nodes+
        (g->edge_count ? g->edge_count : 1)*sizeof *g->edges+(g->member_count ? g->member_count : 1)*sizeof *g->members+
        (g->processes ? g->processes : 1)*sizeof *g->groups;
    return g;
}
