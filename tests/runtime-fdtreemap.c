#define _GNU_SOURCE
#include "check.h"
#include "xrt_fdtreemap.h"
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
struct fixture {
    struct xrt_fd_process processes[3];
    struct xrt_fd fds[12];
    char names[1024];
    struct xrt_fdflow_count_row rows[12];
    struct xrt_fdflow_rate rates[12];
    struct xrt_fd_snapshot snapshot;
    struct xrt_fdflow_live flow;
};
static void fixture(struct fixture *f)
{
    memset(f,0,sizeof *f);
    const char *names[]={"/alpha/shared","/beta/alias","/alpha/zero","/alpha/stale","/alpha/shared","/alpha","pipe:[91]","/slash//leaf/","/bad","/stale-process","/live","/[pipes]"};
    size_t used=0;
    for (unsigned i=0;i<12;++i) {
        size_t n=strlen(names[i]);memcpy(f->names+used,names[i],n+1);
        f->fds[i]=(struct xrt_fd){.fd=(int32_t)(i%4+3),.kind=i==6?XRT_FD_PIPE:i==5?XRT_FD_DIRECTORY:XRT_FD_REGULAR,.flags=XRT_FD_STAT|XRT_FD_INFO,.device=1,.inode=100+i,.link=(uint32_t)used,.link_length=(uint16_t)n,.info_interval_ns=1000,.rate=1};used+=n+1;
        f->rows[i]=(struct xrt_fdflow_count_row){.pid=(int32_t)(100+i/4),.fd=f->fds[i].fd,.start=10+i/4,.device=1,.inode=100+i,.kind=f->fds[i].kind,.active=1,.read_bytes=10+i,.write_bytes=20+i,.last_ns=300+i};
        f->rates[i]=(struct xrt_fdflow_rate){.read=100+i,.write=200+i};
    }
    f->fds[1].inode=f->fds[0].inode;f->rows[1].inode=f->fds[1].inode; /* alias, same inode */
    f->fds[3].flags|=XRT_FD_LINK_STALE;
    f->fds[2].rate=0;f->rows[2].read_bytes=f->rows[2].write_bytes=0;f->rates[2].read=f->rates[2].write=0;
    f->fds[8].link_length=1000; /* malformed string range stays visible as unknown */
    for (unsigned i=0;i<3;++i) f->processes[i]=(struct xrt_fd_process){.pid=(int32_t)(100+i),.start=10+i,.first=i*4,.count=4};
    f->snapshot=(struct xrt_fd_snapshot){.sequence=5,.taken_ns=400,.processes=f->processes,.process_count=3,.fds=f->fds,.fd_count=12,.strings=f->names,.strings_length=(uint32_t)used,.dropped_fds=2,.hidden=3};
    f->flow=(struct xrt_fdflow_live){.sequence=7,.status=XRT_OK,.stream={.running=1},.counts={.rows=f->rows,.row_count=12},.rates=f->rates};
}
static const struct xrt_fdtreemap_options options={1024,8192,32};
static struct xrt_fdtreemap *build(struct fixture *f,const struct xrt_fdtreemap_options *o)
{
    struct xrt_fdtreemap *t=NULL;CHECK(xrt_fdtreemap_build(&f->snapshot,&f->flow,o,&t)==XRT_OK && t);return t;
}
static uint32_t find(const struct xrt_fdtreemap *t,const char *path)
{
    char buf[4098];size_t needed;
    for (uint32_t i=0;i<t->count;++i) {CHECK(xrt_fdtreemap_path(t,i,buf,sizeof buf,&needed)==XRT_OK && needed==strlen(buf)+1);if (!strcmp(buf,path)) return i;}
    CHECK(0);return 0;
}
static void geometry(struct xrt_fdtreemap *t,uint32_t node,uint32_t cap,double aspect)
{
    struct xrt_fdtreemap_layout *l=NULL;CHECK(xrt_fdtreemap_layout(t,node,cap,aspect,&l)==XRT_OK && l && l->count<=cap);
    uint32_t descriptors=0;double area=0;uint64_t read=0,write=0;
    for (uint32_t i=0;i<l->count;++i) {
        const struct xrt_fdtreemap_tile *p=&l->tiles[i];descriptors+=p->metric.descriptors;read+=p->metric.read_bytes;write+=p->metric.write_bytes;
        CHECK(isfinite(p->x) && isfinite(p->y) && p->x>=0 && p->y>=0 && p->w>0 && p->h>0 && p->x+p->w<=1.000001 && p->y+p->h<=1.000001);
        double a=(double)p->w*p->h;area+=a;CHECK(fabs(a-(double)p->metric.descriptors/t->nodes[node].total.descriptors)<.000001);
        for (uint32_t j=0;j<i;++j) {const struct xrt_fdtreemap_tile *q=&l->tiles[j];double w=fmin(p->x+p->w,q->x+q->w)-fmax(p->x,q->x),h=fmin(p->y+p->h,q->y+q->h)-fmax(p->y,q->y);CHECK(w<=.000001 || h<=.000001);}
    }
    CHECK(descriptors==t->nodes[node].total.descriptors && read==t->nodes[node].total.read_bytes && write==t->nodes[node].total.write_bytes);
    CHECK(fabs(area-(descriptors?1:0))<.000001);xrt_fdtreemap_layout_free(l);
}
static unsigned long rss(void)
{
    unsigned long total,resident;FILE *f=fopen("/proc/self/statm","r");CHECK(f && fscanf(f,"%lu %lu",&total,&resident)==2);CHECK(!fclose(f));return resident*(unsigned long)sysconf(_SC_PAGESIZE);
}
static void large(void)
{
    unsigned long before=rss();const uint32_t pc=1000,fc=100000;
    struct xrt_fd_process *p=calloc(pc,sizeof *p);struct xrt_fd *fds=calloc(fc,sizeof *fds);char *text=malloc(fc*40);CHECK(p && fds && text);uint32_t length=0;
    for (uint32_t i=0;i<pc;++i) p[i]=(struct xrt_fd_process){.pid=(int32_t)(100+i),.start=i+1,.first=i*100,.count=100};
    for (uint32_t i=0;i<fc;++i) {int n=snprintf(text+length,40,"/fixture/%u/file%u",i/100,i%100);CHECK(n>0 && n<40);fds[i]=(struct xrt_fd){.fd=(int32_t)(i%100),.kind=XRT_FD_REGULAR,.link=length,.link_length=(uint16_t)n};length+=(uint32_t)n+1;}
    struct xrt_fd_snapshot s={.processes=p,.process_count=pc,.fds=fds,.fd_count=fc,.strings=text,.strings_length=length};
    struct xrt_fdtreemap_options o={4096,1024*1024,32};struct timespec start,end;CHECK(!clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&start));size_t bytes=0;unsigned long with_fixture=rss(),peak=with_fixture;uint32_t overflow=0;
    for (unsigned i=0;i<5;++i) {
        struct xrt_fdtreemap *t=NULL;CHECK(xrt_fdtreemap_build(&s,NULL,&o,&t)==XRT_OK && t->nodes[0].total.descriptors==fc);
        CHECK(t->count==4096 && t->allocated_bytes<3*1024*1024);geometry(t,0,64,1.6);bytes=t->allocated_bytes;
        unsigned long current=rss();if (current>peak) peak=current;overflow=0;
        for (uint32_t n=0;n<t->count;++n) overflow+=t->nodes[n].overflow.descriptors;
        CHECK(overflow>0 && overflow<fc && overflow==t->nodes[0].total.unexpanded);xrt_fdtreemap_free(t);
    }
    CHECK(!clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&end));double load[3];CHECK(getloadavg(load,3)==3);
    printf("{\"cpu_ns_5_builds\":%llu,\"rss_before\":%lu,\"rss_fixture\":%lu,\"rss_peak\":%lu,\"tree_bytes\":%zu,\"overflow_fds\":%u,\"load\":[%.2f,%.2f,%.2f]}\n",(unsigned long long)((end.tv_sec-start.tv_sec)*1000000000LL+end.tv_nsec-start.tv_nsec),before,with_fixture,peak,bytes,overflow,load[0],load[1],load[2]);
    free(p);free(fds);free(text);
}
int fdtreemap_test_main(int argc,char **argv)
{
    struct fixture f;fixture(&f);struct xrt_fdtreemap *t=build(&f,&options);uint32_t shared=find(t,"/alpha/shared");
    CHECK(t->nodes[shared].own.descriptors==(argc>1 && !strcmp(argv[1],"--wrong-oracle")?3u:2u));
    CHECK(t->nodes[shared].own.read_bytes==24 && t->nodes[shared].own.write_bytes==44 && t->nodes[shared].own.flow_measured==2);
    CHECK(find(t,"/beta/alias")!=shared && t->nodes[find(t,"/beta/alias")].own.read_bytes==11);
    CHECK(find(t,"/[pipes]")!=find(t,"[pipes]"));CHECK(t->nodes[find(t,"/slash/leaf")].own.descriptors==1);
    uint32_t resolved;
    for (uint32_t i=0;i<t->count;++i) {
        char path[4098];size_t needed;
        CHECK(xrt_fdtreemap_path(t,i,path,sizeof path,&needed)==XRT_OK);
        CHECK(xrt_fdtreemap_relocate(t,i,t,&resolved)==XRT_OK && resolved==i);
    }
    CHECK(xrt_fdtreemap_relocate(t,t->count,t,&resolved)==XRT_INVALID_ARGUMENT && resolved==UINT32_MAX);
    /* Empty components are dropped: "//lpha/shared" is "/lpha/shared", so no
     * literal node is empty and no spelling of a non-root node is "/". */
    struct fixture slashes;fixture(&slashes);slashes.names[1]='/'; /* "//lpha/shared" */
    struct xrt_fdtreemap *other=build(&slashes,&options);
    CHECK(other->fd_nodes[0]==find(other,"/lpha/shared") && other->nodes[other->nodes[other->fd_nodes[0]].parent].parent==0);
    for (uint32_t i=1;i<other->count;++i) CHECK(other->nodes[i].name_length);
    CHECK(xrt_fdtreemap_relocate(other,find(other,"/lpha"),t,&resolved)==XRT_STALE_SNAPSHOT && resolved==UINT32_MAX);
    CHECK(xrt_fdtreemap_relocate(t,shared,other,&resolved)==XRT_OK && resolved==find(other,"/alpha/shared") && resolved!=shared);
    xrt_fdtreemap_free(other);
    /* The holder is captured at build: no snapshot copy is kept for it. */
    struct xrt_fdtreemap_holder holder;
    CHECK(xrt_fdtreemap_holder(t,find(t,"/alpha"),&holder)==XRT_OK && holder.pid==100 && holder.start==10 && holder.fd==3);
    CHECK(xrt_fdtreemap_holder(t,0,&holder)==XRT_OK && holder.pid==100);
    CHECK(xrt_fdtreemap_holder(t,find(t,"/beta/alias"),&holder)==XRT_OK && holder.pid==100 && holder.fd==4);
    CHECK(xrt_fdtreemap_holder(t,find(t,"[memfd]"),&holder)==XRT_STALE_SNAPSHOT && !holder.pid);
    uint32_t zero=find(t,"/alpha/zero"),stale=find(t,"/alpha/stale");
    CHECK(t->nodes[zero].own.flow_measured==1 && t->nodes[zero].own.offset_measured==1 && !t->nodes[zero].own.read_bytes && !t->nodes[zero].own.offset_rate);
    CHECK(t->nodes[stale].own.stale_paths==1 && !t->nodes[stale].own.flow_measured && !t->nodes[stale].own.offset_measured);
    CHECK(t->matched_rows==11 && t->unmatched_rows==1 && t->nodes[0].total.descriptors==12 && t->nodes[0].total.unknown_paths==1 && t->denied==3 && t->dropped_fds==2);
    size_t needed;char buf[32];CHECK(xrt_fdtreemap_path(t,shared,NULL,0,&needed)==XRT_BUFFER_TOO_SMALL && needed==strlen("/alpha/shared")+1);CHECK(xrt_fdtreemap_path(t,shared,buf,needed-1,&needed)==XRT_BUFFER_TOO_SMALL);
    for (unsigned i=0;i<t->count;++i) for (unsigned cap=1;cap<=8;++cap) geometry(t,i,cap,cap==1?.01:cap==2?100:1.6);
    xrt_fdtreemap_free(t);
    struct xrt_fdtreemap_options limited=options;limited.max_nodes=16;limited.max_depth=1;t=build(&f,&limited);
    uint32_t overflow=0;for (uint32_t i=0;i<t->count;++i) overflow+=t->nodes[i].overflow.descriptors;
    CHECK(overflow>0 && overflow==t->nodes[0].total.unexpanded && t->nodes[0].total.descriptors==12 && t->nodes[0].total.flow_measured==11);geometry(t,0,2,1);xrt_fdtreemap_free(t);
    limited=options;limited.max_text=256;t=build(&f,&limited);CHECK(t->text_length<=256 && t->nodes[0].total.descriptors==12);geometry(t,0,3,1);xrt_fdtreemap_free(t);
    f.processes[2].flags=XRT_FDP_STALE;t=build(&f,&options);CHECK(t->matched_rows==7 && t->unmatched_rows==5 && t->nodes[0].total.stale==5);xrt_fdtreemap_free(t);f.processes[2].flags=0;
    f.flow.stream.running=0;t=build(&f,&options);CHECK(!t->nodes[0].total.read_rate && t->nodes[0].total.read_bytes>0);xrt_fdtreemap_free(t);f.flow.stream.running=1;
    f.rows[0].read_bytes=f.rows[4].read_bytes=UINT64_MAX;f.rates[0].read=f.rates[4].read=DBL_MAX;t=build(&f,&options);CHECK(t->nodes[0].total.read_bytes==UINT64_MAX && t->nodes[0].total.read_rate==DBL_MAX && t->nodes[0].total.flags&XRT_FDT_SATURATED);xrt_fdtreemap_free(t);
    fixture(&f);f.rates[0].read=NAN;CHECK(xrt_fdtreemap_build(&f.snapshot,&f.flow,&options,&t)==XRT_INVALID_ARGUMENT && !t);
    fixture(&f);f.rows[1]=f.rows[0];CHECK(xrt_fdtreemap_build(&f.snapshot,&f.flow,&options,&t)==XRT_INVALID_ARGUMENT && !t);
    fixture(&f);f.fds[0].rate=INFINITY;CHECK(xrt_fdtreemap_build(&f.snapshot,NULL,&options,&t)==XRT_INVALID_ARGUMENT && !t);
    fixture(&f);f.processes[1].first=0;CHECK(xrt_fdtreemap_build(&f.snapshot,NULL,&options,&t)==XRT_INVALID_ARGUMENT && !t);
    fixture(&f);f.snapshot.fd_count=262145;CHECK(xrt_fdtreemap_build(&f.snapshot,NULL,&options,&t)==XRT_INVALID_ARGUMENT && !t);
    struct xrt_fd_snapshot empty={0};CHECK(xrt_fdtreemap_build(&empty,NULL,&options,&t)==XRT_OK && t->count==10 && t->allocated_bytes<8192);geometry(t,0,1,1);xrt_fdtreemap_free(t);
    large();puts("descriptor path treemap: exact metrics, sampled identities, caps and geometry PASS");return 0;
}
#ifndef FD_TREEMAP_NO_MAIN
int main(int argc,char **argv) {return fdtreemap_test_main(argc,argv);}
#endif
