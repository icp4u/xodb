#ifndef XODB_RUNTIME_FDFLOW_JOIN_H
#define XODB_RUNTIME_FDFLOW_JOIN_H
#include "xrt_fdflow_count.h"
/* Shared sampled identity join. Callers validate sorted process/fd tables and
 * their bounds. This never proves the kernel file chosen by concurrent fdget. */
static inline uint32_t xrt_fdflow_match(const struct xrt_fd_snapshot *s,
    const struct xrt_fdflow_count_row *r,uint32_t *process_index)
{
    uint32_t lo=0,hi=s->process_count;
    while (lo<hi) {uint32_t m=lo+(hi-lo)/2;if (s->processes[m].pid<r->pid) lo=m+1;else hi=m;}
    if (!r->active || lo==s->process_count || s->processes[lo].pid!=r->pid || s->processes[lo].start!=r->start) return UINT32_MAX;
    const struct xrt_fd_process *p=&s->processes[lo];*process_index=lo;
    if (p->first>s->fd_count || p->count>s->fd_count-p->first) return UINT32_MAX;
    lo=p->first;hi=lo+p->count;
    while (lo<hi) {uint32_t m=lo+(hi-lo)/2;if (s->fds[m].fd<r->fd) lo=m+1;else hi=m;}
    if (lo==p->first+p->count || s->fds[lo].fd!=r->fd) return UINT32_MAX;
    const struct xrt_fd *f=&s->fds[lo];
    if (f->inode!=r->inode || f->device!=r->device || f->kind!=r->kind || !xrt_fd_identity_current(s,p,f)) return UINT32_MAX;
    return lo;
}
#endif
