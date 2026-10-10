#define _GNU_SOURCE 1
#include "xrt_fdinherit.h"
#include "xrt_fdgraph.h"
#include <fcntl.h>
#include <stdlib.h>

void xrt_fdinherit_free(struct xrt_fdinherit *v)
{
    if (!v) return;
    free(v->rows);free(v);
}
static uint32_t parent_index(const struct xrt_fd_snapshot *s,int32_t pid)
{
    uint32_t lo=0,hi=s->process_count;
    while (lo<hi) {uint32_t mid=lo+(hi-lo)/2;if (s->processes[mid].pid<pid) lo=mid+1;else hi=mid;}
    return lo<s->process_count && s->processes[lo].pid==pid ? lo : UINT32_MAX;
}
/* A parent listed without a readable fd table: denied, or a kernel task. */
static const struct xrt_fd_unseen *unseen(const struct xrt_fd_snapshot *s,int32_t pid)
{
    if (!s->unseen) return NULL;
    uint32_t lo=0,hi=s->unseen_count;
    while (lo<hi) {uint32_t mid=lo+(hi-lo)/2;if (s->unseen[mid].pid<pid) lo=mid+1;else hi=mid;}
    return lo<s->unseen_count && s->unseen[lo].pid==pid ? &s->unseen[lo] : NULL;
}
static uint32_t fd_index(const struct xrt_fd_snapshot *s,const struct xrt_fd_process *p,int32_t fd)
{
    uint32_t lo=p->first,hi=lo+p->count;
    while (lo<hi) {uint32_t mid=lo+(hi-lo)/2;if (s->fds[mid].fd<fd) lo=mid+1;else hi=mid;}
    return lo<p->first+p->count && s->fds[lo].fd==fd ? lo : UINT32_MAX;
}
static int identity_known(const struct xrt_fd *f)
{
    return (f->flags&XRT_FD_STAT) && f->inode && f->kind!=XRT_FD_ANON && f->kind!=XRT_FD_OTHER;
}
static int flags_known(const struct xrt_fd_process *p,const struct xrt_fd *f)
{
    return !(p->flags&XRT_FDP_STALE) && (f->flags&XRT_FD_INFO) && !(f->flags&XRT_FD_INFO_STALE);
}
enum xrt_status xrt_fdinherit_build(const struct xrt_fd_snapshot *s,uint32_t max_rows,struct xrt_fdinherit **out)
{
    if (out) *out=NULL;
    if (!s || !out || !max_rows || max_rows>262144 || s->process_count>16384 || s->fd_count>262144 ||
        (s->process_count && !s->processes) || (s->fd_count && !s->fds)) return XRT_INVALID_ARGUMENT;
    uint32_t end=0;
    for (uint32_t i=0;i<s->process_count;++i) {
        const struct xrt_fd_process *p=&s->processes[i];
        if (p->pid<=0 || !p->start || p->first!=end || p->count>s->fd_count-end ||
            (i && s->processes[i-1].pid>=p->pid)) return XRT_INVALID_ARGUMENT;
        int32_t previous=-1;
        for (uint32_t j=0;j<p->count;++j) {
            const struct xrt_fd *f=&s->fds[p->first+j];
            if (f->fd<=previous || f->kind>=XRT_FD_KINDS) return XRT_INVALID_ARGUMENT;
            previous=f->fd;
        }
        end+=p->count;
    }
    if (end!=s->fd_count) return XRT_INVALID_ARGUMENT;
    struct xrt_fdinherit *v=calloc(1,sizeof *v);
    if (!v) return XRT_OUT_OF_MEMORY;
    v->sequence=s->sequence;v->taken_ns=s->taken_ns;v->allocated_bytes=sizeof *v;
    /* Pass 0 counts every pair and keeps rows for fds above 2; pass 1 fills
     * what max_rows leaves with std fds, which most children share. */
    for (int pass=0;pass<2;++pass)
    for (uint32_t child=0;child<s->process_count;++child) {
        const struct xrt_fd_process *p=&s->processes[child];
        uint32_t parent=parent_index(s,p->ppid);
        /* A reused PID born after its purported child cannot establish this
         * relationship. Reparented children are still just sampled pairs. */
        if (parent==UINT32_MAX || parent==child || s->processes[parent].start>p->start) {
            if (pass) continue;
            const struct xrt_fd_unseen *u=parent==UINT32_MAX && p->ppid>0 ? unseen(s,p->ppid) : NULL;
            if (u && !u->kernel) ++v->parent_denied;
            else if (parent==UINT32_MAX && p->ppid>0 && !u) ++v->parent_absent;
            else if (parent!=UINT32_MAX && parent!=child) ++v->parent_reused;
            ++v->parent_unavailable;v->parent_unavailable_fds+=p->count;continue;
        }
        const struct xrt_fd_process *q=&s->processes[parent];v->parent_pairs+=!pass;
        for (uint32_t j=0;j<p->count;++j) {
            uint32_t child_fd=p->first+j,parent_fd=fd_index(s,q,s->fds[child_fd].fd);
            const int std_fd=s->fds[child_fd].fd<=2;const uint32_t count=!pass;
            if (pass && !std_fd) continue;
            if (parent_fd==UINT32_MAX) {v->no_parent_fd+=count;continue;}
            const struct xrt_fd *cf=&s->fds[child_fd],*pf=&s->fds[parent_fd];
            if (!identity_known(cf) || !identity_known(pf)) {v->identity_unknown+=count;continue;}
            if (cf->kind!=pf->kind || cf->device!=pf->device || cf->inode!=pf->inode) {v->different_object+=count;continue;}
            uint32_t flags=0;
            if (q->flags&XRT_FDP_STALE) flags|=XRT_FDINH_PARENT_STALE;
            if (p->flags&XRT_FDP_STALE) flags|=XRT_FDINH_CHILD_STALE;
            if (!xrt_fd_identity_current(s,p,cf) || !xrt_fd_identity_current(s,q,pf)) flags|=XRT_FDINH_IDENTITY_STALE;
            if (flags) v->stale+=count;
            if (flags_known(q,pf)) {
                flags|=XRT_FDINH_PARENT_FLAGS_KNOWN;
                if (pf->open_flags&O_CLOEXEC) flags|=XRT_FDINH_PARENT_CLOEXEC;
            }
            if (flags_known(p,cf)) {
                flags|=XRT_FDINH_CHILD_FLAGS_KNOWN;
                if (cf->open_flags&O_CLOEXEC) {flags|=XRT_FDINH_CHILD_CLOEXEC;v->cloexec+=count;}
                else v->no_cloexec+=count;
            } else v->flags_unknown+=count;
            v->matched+=count;
            if (pass!=std_fd) continue;
            if (v->count==max_rows) {++v->dropped;continue;}
            if (v->count==v->capacity) {
                uint32_t cap=v->capacity ? v->capacity*2 : 64;
                if (cap>max_rows) cap=max_rows;
                struct xrt_fdinherit_row *rows=realloc(v->rows,(size_t)cap*sizeof *rows);
                if (!rows) {xrt_fdinherit_free(v);return XRT_OUT_OF_MEMORY;}
                v->rows=rows;v->capacity=cap;v->allocated_bytes=sizeof *v+(size_t)cap*sizeof *rows;
            }
            v->rows[v->count++]=(struct xrt_fdinherit_row){parent,child,parent_fd,child_fd,flags};
        }
    }
    *out=v;return XRT_OK;
}
