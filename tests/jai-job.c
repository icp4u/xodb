/* Fast lane: deterministic worker barriers, no timing-based success claims. */
#define _GNU_SOURCE 1
#define JAI_READER_NO_MAIN
#include "jai-reader.c"
#include "../src/language/jai_job.h"
#include <pthread.h>
#include <time.h>
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed=PTHREAD_COND_INITIALIZER;
static unsigned entered,finished;static int open_gate;
void xjai_job_test_barrier(void)
{
    pthread_mutex_lock(&lock);++entered;pthread_cond_broadcast(&changed);
    while (!open_gate) CHECK(!pthread_cond_wait(&changed,&lock));
    pthread_mutex_unlock(&lock);
}
void xjai_job_test_finished(void)
{
    pthread_mutex_lock(&lock);++finished;pthread_cond_broadcast(&changed);pthread_mutex_unlock(&lock);
}
static void await(unsigned *counter,unsigned wanted)
{
    struct timespec until;CHECK(!clock_gettime(CLOCK_REALTIME,&until));until.tv_sec+=10;
    pthread_mutex_lock(&lock);
    while (*counter<wanted) CHECK(!pthread_cond_timedwait(&changed,&lock,&until));
    pthread_mutex_unlock(&lock);
}
int main(int argc,char **argv)
{
    struct xjai_region region;struct xjai_image im=graph_fixture(&region);
    struct xjai_job *a=NULL,*b=NULL,*c=(void *)1;
    CHECK(!xjai_job_start(&im,&a) && !xjai_job_start(&im,&b));await(&entered,2);
    struct xjai_job_snapshot s;xjai_job_poll(a,&s);CHECK(s.state==XJAI_JOB_PENDING && !s.graph && !s.reason);
    CHECK(!strcmp(xjai_job_start(&im,&c),"JaiWorkerBusy") && !c);
    struct xjai_job_usage u;xjai_job_usage(&u);CHECK(u.active==2 && u.input_bytes==region.size*2 && !u.result_bytes);
    /* If release joins, this test cannot reach the gate-open below. */
    xjai_job_release(a);memset(arena,0,sizeof arena);
    pthread_mutex_lock(&lock);open_gate=1;pthread_cond_broadcast(&changed);pthread_mutex_unlock(&lock);
    await(&finished,2);xjai_job_poll(b,&s);CHECK(s.state==XJAI_JOB_READY && s.graph && !s.reason);
    uint32_t object=find(s.graph,"FixtureObject");CHECK(object!=XJAI_NONE && s.graph->types[object].size==sizeof(struct object_value));
    uint32_t type_count=s.graph->type_count;
    xjai_job_usage(&u);CHECK(!u.active && !u.input_bytes && u.result_bytes==s.graph->allocated_bytes);
    xjai_job_release(b);xjai_job_usage(&u);CHECK(!u.active && !u.input_bytes && !u.result_bytes);
    /* A bounded parse failure still frees its copied input and publishes a reason. */
    im=graph_fixture(&region);put(self+16,UINT64_MAX,8);CHECK(!xjai_job_start(&im,&c));await(&finished,3);
    xjai_job_poll(c,&s);CHECK(s.state==XJAI_JOB_FAILED && !s.graph && !strcmp(s.reason,"JaiLayoutUnavailable"));
    xjai_job_release(c);xjai_job_usage(&u);CHECK(!u.active && !u.input_bytes && !u.result_bytes);
    im.count=0;c=(void *)1;CHECK(!strcmp(xjai_job_start(&im,&c),"JaiInvalidImage") && !c);
    im=graph_fixture(&region);region.size=XJAI_IMAGE_BYTES+1;c=(void *)1;
    CHECK(!strcmp(xjai_job_start(&im,&c),"JaiImageLimit") && !c);
    CHECK(type_count==(argc>1 && !strcmp(argv[1],"--wrong-oracle")?28u:27u));
    puts("Jai worker: copied bytes, deterministic busy/pending, nonblocking abandonment, failure and zero budgets PASS");return 0;
}
