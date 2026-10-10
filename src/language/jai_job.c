#include "jai_job.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#define INPUT_LIMIT (64u*1024u*1024u)
#define RESULT_LIMIT (64u*1024u*1024u)
static pthread_mutex_t budget_mutex=PTHREAD_MUTEX_INITIALIZER;
static struct xjai_job_usage usage;
struct xjai_job {
    pthread_mutex_t mutex;
    struct xjai_region *regions;size_t count,total;
    struct xjai_graph *graph;const char *reason;
    enum xjai_job_state state;int abandoned;
};
static void input_free(struct xjai_job *j)
{
    for (size_t i=0;i<j->count;++i) free((void *)j->regions[i].data);
    free(j->regions);j->regions=NULL;j->count=0;
}
static void dispose(struct xjai_job *j)
{
    if (j->graph) {
        pthread_mutex_lock(&budget_mutex);usage.result_bytes-=j->graph->allocated_bytes;pthread_mutex_unlock(&budget_mutex);
        xjai_graph_free(j->graph);
    }
    pthread_mutex_destroy(&j->mutex);free(j);
}
static void *worker(void *context)
{
    struct xjai_job *j=context;
#ifdef XJAI_JOB_TEST
    extern void xjai_job_test_barrier(void);
    xjai_job_test_barrier();
#endif
    struct xjai_image image={j->regions,j->count};struct xjai_graph *g=NULL;
    const char *why=xjai_graph_build(&image,NULL,&g);
    input_free(j);
    pthread_mutex_lock(&budget_mutex);usage.input_bytes-=j->total;
    if (g) {
        if (g->allocated_bytes>RESULT_LIMIT-usage.result_bytes) {xjai_graph_free(g);g=NULL;why="JaiResultBudget";}
        else usage.result_bytes+=g->allocated_bytes;
    }
    pthread_mutex_unlock(&budget_mutex);
    pthread_mutex_lock(&j->mutex);
    j->graph=g;j->reason=why;j->state=why?XJAI_JOB_FAILED:XJAI_JOB_READY;
    int abandoned=j->abandoned;pthread_mutex_unlock(&j->mutex);
    /* No access to j after publication unless the owner already abandoned it. */
    if (abandoned) dispose(j);
    pthread_mutex_lock(&budget_mutex);--usage.active;pthread_mutex_unlock(&budget_mutex);
#ifdef XJAI_JOB_TEST
    extern void xjai_job_test_finished(void);
    xjai_job_test_finished();
#endif
    return NULL;
}
static void unreserve(size_t size)
{
    pthread_mutex_lock(&budget_mutex);--usage.active;usage.input_bytes-=size;pthread_mutex_unlock(&budget_mutex);
}
const char *xjai_job_start(const struct xjai_image *image,struct xjai_job **out)
{
    if (!out) return "JaiInvalidArgument";
    *out=NULL;
    if (!image || !image->regions || !image->count || image->count>XJAI_REGIONS) return "JaiInvalidImage";
    size_t total=0;
    for (size_t i=0;i<image->count;++i) {
        const struct xjai_region *r=&image->regions[i];
        if (!r->data || !r->size || r->address>UINT64_MAX-r->size ||
            (i && image->regions[i-1].address+image->regions[i-1].size>r->address)) return "JaiInvalidImage";
        if (r->size>INPUT_LIMIT-total) return "JaiImageLimit";
        total+=r->size;
    }
    pthread_mutex_lock(&budget_mutex);
    if (usage.active==2 || total>INPUT_LIMIT-usage.input_bytes) {pthread_mutex_unlock(&budget_mutex);return "JaiWorkerBusy";}
    ++usage.active;usage.input_bytes+=total;pthread_mutex_unlock(&budget_mutex);
    struct xjai_job *j=calloc(1,sizeof *j);
    if (!j) {unreserve(total);return "JaiOutOfMemory";}
    if (pthread_mutex_init(&j->mutex,NULL)) {free(j);unreserve(total);return "JaiWorkerUnavailable";}
    j->total=total;j->regions=calloc(image->count,sizeof *j->regions);
    if (!j->regions) {dispose(j);unreserve(total);return "JaiOutOfMemory";}
    j->count=image->count;
    for (size_t i=0;i<j->count;++i) {
        j->regions[i]=image->regions[i];j->regions[i].data=malloc(j->regions[i].size);
        if (!j->regions[i].data) {input_free(j);dispose(j);unreserve(total);return "JaiOutOfMemory";}
        memcpy((void *)j->regions[i].data,image->regions[i].data,j->regions[i].size);
    }
    pthread_attr_t attr;int rc=pthread_attr_init(&attr);
    if (rc) {input_free(j);dispose(j);unreserve(total);return "JaiWorkerUnavailable";}
    rc=pthread_attr_setdetachstate(&attr,PTHREAD_CREATE_DETACHED);pthread_t thread;
    if (!rc) rc=pthread_create(&thread,&attr,worker,j);
    pthread_attr_destroy(&attr);
    if (rc) {input_free(j);dispose(j);unreserve(total);return "JaiWorkerUnavailable";}
    *out=j;return NULL;
}
void xjai_job_poll(struct xjai_job *j,struct xjai_job_snapshot *out)
{
    if (!out) return;
    if (!j) {*out=(struct xjai_job_snapshot){.state=XJAI_JOB_FAILED,.reason="JaiInvalidArgument"};return;}
    pthread_mutex_lock(&j->mutex);*out=(struct xjai_job_snapshot){j->state,j->reason,j->graph};pthread_mutex_unlock(&j->mutex);
}
void xjai_job_release(struct xjai_job *j)
{
    if (!j) return;
    pthread_mutex_lock(&j->mutex);
    if (j->state==XJAI_JOB_PENDING) {j->abandoned=1;pthread_mutex_unlock(&j->mutex);return;}
    pthread_mutex_unlock(&j->mutex);dispose(j);
}
void xjai_job_usage(struct xjai_job_usage *out)
{
    if (!out) return;
    pthread_mutex_lock(&budget_mutex);*out=usage;pthread_mutex_unlock(&budget_mutex);
}
