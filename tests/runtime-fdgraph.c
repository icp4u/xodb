#define _GNU_SOURCE 1
#include "xrt_fdgraph.h"
#include "check.h"
#include <errno.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/sock_diag.h>
#include <linux/unix_diag.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static uint32_t resource(const struct xrt_fdgraph *g,uint64_t inode,uint32_t kind)
{
    for (uint32_t i=0;i<g->node_count;++i)
        if (g->nodes[i].type==XRT_FDG_RESOURCE && g->nodes[i].inode==inode && g->nodes[i].kind==kind) return i;
    return UINT32_MAX;
}
static void synthetic(int wrong)
{
    struct xrt_fd f[6]={
        {.fd=3,.kind=XRT_FD_PIPE,.flags=XRT_FD_STAT,.device=1,.inode=10},
        {.fd=4,.kind=XRT_FD_SOCKET,.flags=XRT_FD_STAT,.device=2,.inode=20},
        {.fd=5,.kind=XRT_FD_ANON,.flags=XRT_FD_STAT,.device=3,.inode=1},
        {.fd=3,.kind=XRT_FD_PIPE,.flags=XRT_FD_STAT,.device=1,.inode=10},
        {.fd=4,.kind=XRT_FD_SOCKET,.flags=XRT_FD_STAT,.device=2,.inode=21},
        {.fd=5,.kind=XRT_FD_ANON,.flags=XRT_FD_STAT,.device=3,.inode=1}};
    struct xrt_fd_process p[2]={{.pid=10,.start=100,.count=3},{.pid=11,.start=101,.first=3,.count=3}};
    struct xrt_fd_unseen denied={.pid=12,.start=102};
    struct xrt_fd_snapshot s={.sequence=1,.taken_ns=99,.processes=p,.process_count=2,.fds=f,.fd_count=6,.unseen=&denied,.unseen_count=1};
    struct xrt_unix_peer peers[2]={{.inode=20,.peer=21},{.inode=21,.peer=20}};
    struct xrt_fdgraph *g=NULL;
    CHECK(xrt_fdgraph_build(&s,peers,2,&g)==XRT_OK);
    CHECK(g->processes==3 && g->resources==(unsigned)(wrong ? 4 : 5) && g->node_count==8);
    CHECK(g->edge_count==7 && g->peer_edges==1 && g->denied_processes==1 && g->unknown_descriptors==2);
    uint32_t pipe=resource(g,10,XRT_FD_PIPE);CHECK(pipe!=UINT32_MAX && g->nodes[pipe].holders==2 && g->nodes[pipe].descriptors==2);
    struct xrt_fdgraph_project_options project={.max_stars=1,.max_particles=8,.focus_process=UINT32_MAX};
    struct xrt_fdgraph_projection *v=NULL;
    CHECK(xrt_fdgraph_project(g,&project,&v)==XRT_OK);
    CHECK(v->star_count==1 && v->stars[0].processes==3 && v->stars[0].descriptors==6 && v->stars[0].denied==1 && v->stars[0].mixed_groups);
    CHECK(v->represented_descriptors==6 && v->particle_count==3 && v->grouped_stars==1);
    struct xrt_fdgraph_layout *layout=NULL;
    CHECK(xrt_fdgraph_layout(g,v,32,64,&layout)==XRT_OK);
    CHECK(layout->star_count==1 && layout->resource_count==3 && layout->link_count==4);
    CHECK(layout->links[0].descriptors+layout->links[1].descriptors+layout->links[2].descriptors==4);
    xrt_fdgraph_layout_free(layout);
    CHECK(xrt_fdgraph_layout(g,v,1,1,&layout)==XRT_OK && layout->omitted_resources==2 && layout->link_count==1 && layout->omitted_links==3);
    xrt_fdgraph_layout_free(layout);
    xrt_fdgraph_projection_free(v);project.max_particles=16;project.focus_process=0;
    CHECK(xrt_fdgraph_project(g,&project,&v)==XRT_OK && v->star_count==1 && v->particle_count==3 && !v->grouped_particles);
    CHECK(v->represented_descriptors==3 && v->process_to_star[0]==0 && v->process_to_star[1]==UINT32_MAX);
    xrt_fdgraph_projection_free(v);project.focus_process=UINT32_MAX;project.max_stars=3;project.max_particles=24;
    uint64_t groups[3]={42,42,99};project.groups=groups;
    CHECK(xrt_fdgraph_project(g,&project,&v)==XRT_OK && v->star_count==2 && v->stars[0].processes==2 && !v->stars[0].mixed_groups);
    xrt_fdgraph_projection_free(v);
    xrt_fdgraph_free(g);
    f[4].flags|=XRT_FD_STAT_STALE;
    CHECK(xrt_fdgraph_build(&s,peers,2,&g)==XRT_OK && g->peer_edges==0 && g->stale_descriptors==1);
    xrt_fdgraph_free(g);
    const char link[]="socket:[21]";s.strings=link;s.strings_length=sizeof link;f[4].link_length=sizeof link-1;
    CHECK(xrt_fd_identity_current(&s,&p[1],&f[4]));
    CHECK(xrt_fdgraph_build(&s,peers,2,&g)==XRT_OK && g->peer_edges==1 && g->stale_descriptors==1);xrt_fdgraph_free(g);
    f[4].flags|=XRT_FD_INFO_STALE;
    CHECK(xrt_fdgraph_build(&s,peers,2,&g)==XRT_OK && g->peer_edges==1);xrt_fdgraph_free(g);
    f[4].flags|=XRT_FD_LINK_STALE;
    CHECK(!xrt_fd_identity_current(&s,&p[1],&f[4]));
    CHECK(xrt_fdgraph_build(&s,peers,2,&g)==XRT_OK && !g->peer_edges);xrt_fdgraph_free(g);
    f[4].flags&=(uint8_t)~XRT_FD_LINK_STALE;f[4].inode=22;CHECK(!xrt_fd_identity_current(&s,&p[1],&f[4]));f[4].inode=21;
    s.strings=NULL;s.strings_length=0;f[4].link_length=0;f[4].flags=XRT_FD_STAT;
    f[3].flags=0;CHECK(xrt_fdgraph_build(&s,peers,2,&g)==XRT_OK && g->resources==6 && g->unknown_descriptors==3);xrt_fdgraph_free(g);f[3].flags=XRT_FD_STAT;
    f[3].device=9;CHECK(xrt_fdgraph_build(&s,peers,2,&g)==XRT_OK && g->resources==6);xrt_fdgraph_free(g);f[3].device=1;
    p[1].first=2;CHECK(xrt_fdgraph_build(&s,peers,2,&g)==XRT_INVALID_ARGUMENT && !g);p[1].first=3;
    denied.pid=10;CHECK(xrt_fdgraph_build(&s,peers,2,&g)==XRT_INVALID_ARGUMENT && !g);denied.pid=12;
    peers[1].inode=20;CHECK(xrt_fdgraph_build(&s,peers,2,&g)==XRT_INVALID_ARGUMENT && !g);
    s=(struct xrt_fd_snapshot){0};CHECK(xrt_fdgraph_build(&s,NULL,0,&g)==XRT_OK && !g->node_count);xrt_fdgraph_free(g);
}
static void cgroup_projection(int wrong)
{
    const char names[]="\0/demo.service\0/other.service\0";
    struct xrt_fd_process process[3]={
        {.pid=11,.start=1,.cgroup=1,.cgroup_length=13,.cgroup_status=XRT_FD_CGROUP_CURRENT},
        {.pid=12,.start=2,.cgroup=1,.cgroup_length=13,.cgroup_status=XRT_FD_CGROUP_CURRENT},
        {.pid=13,.start=3,.cgroup=15,.cgroup_length=14,.cgroup_status=XRT_FD_CGROUP_CURRENT}};
    struct xrt_fd_snapshot snapshot={.processes=process,.process_count=3,.strings=names,.strings_length=sizeof names};
    struct xrt_fdgraph *g=NULL;CHECK(xrt_fdgraph_build(&snapshot,NULL,0,&g)==XRT_OK);
    CHECK(g->cgroup_processes==3 && g->cgroup_count==2 && g->groups[0]==g->groups[1] && g->groups[0]!=g->groups[2]);
    struct xrt_fdgraph_project_options options={.max_stars=4,.max_particles=32,.focus_process=UINT32_MAX,.collapse_cgroups=1};
    struct xrt_fdgraph_projection *v=NULL;CHECK(xrt_fdgraph_project(g,&options,&v)==XRT_OK);
    CHECK(v->star_count==2 && v->stars[0].processes==2 && v->stars[0].sample_node<2 && !v->stars[0].mixed_groups);
    xrt_fdgraph_projection_free(v);options.focus_group=g->groups[0];options.collapse_cgroups=0;
    CHECK(xrt_fdgraph_project(g,&options,&v)==XRT_OK && v->star_count==2 && v->represented_processes==2 && v->process_to_star[2]==UINT32_MAX);
    xrt_fdgraph_projection_free(v);xrt_fdgraph_free(g);
    process[1].cgroup_status=XRT_FD_CGROUP_STALE;process[1].flags=XRT_FDP_STALE;
    process[2].cgroup_length=sizeof names;
    CHECK(xrt_fdgraph_build(&snapshot,NULL,0,&g)==XRT_OK && g->cgroup_processes==1);
    CHECK(g->groups[0]==g->groups[1] && g->groups[1]!=g->groups[2]);
    CHECK(g->cgroup_stale_processes==(unsigned)(wrong ? 2 : 1) && g->cgroup_count==1);
    CHECK(!(g->nodes[0].flags&XRT_FDG_CGROUP_STALE) && (g->nodes[1].flags&XRT_FDG_CGROUP_STALE));
    options.focus_group=0;options.collapse_cgroups=1;
    CHECK(xrt_fdgraph_project(g,&options,&v)==XRT_OK);
    CHECK(v->star_count==2 && v->stars[0].processes==2 && v->stars[0].cgroup_stale==1 && v->stars[0].stale==1);
    xrt_fdgraph_projection_free(v);
    options.focus_group=g->groups[0];options.collapse_cgroups=0;
    CHECK(xrt_fdgraph_project(g,&options,&v)==XRT_OK && v->represented_processes==2);
    xrt_fdgraph_projection_free(v);xrt_fdgraph_free(g);
    process[0].flags=XRT_FDP_STALE; /* Conservative even for an inconsistent caller. */
    CHECK(xrt_fdgraph_build(&snapshot,NULL,0,&g)==XRT_OK && !g->cgroup_processes && g->cgroup_stale_processes==2);
    CHECK(g->groups[0]==g->groups[1]);xrt_fdgraph_free(g);
    process[1].cgroup_status=XRT_FD_CGROUP_UNAVAILABLE;
    CHECK(xrt_fdgraph_build(&snapshot,NULL,0,&g)==XRT_OK && g->cgroup_stale_processes==1);
    CHECK(g->groups[0]!=g->groups[1]);xrt_fdgraph_free(g);
}
static size_t message(unsigned char *data,uint32_t inode,uint32_t peer,int duplicate)
{
    struct nlmsghdr h={.nlmsg_type=SOCK_DIAG_BY_FAMILY,.nlmsg_seq=7,.nlmsg_flags=NLM_F_MULTI};
    struct unix_diag_msg m={.udiag_family=AF_UNIX,.udiag_ino=inode,.udiag_cookie={11,12}};
    struct rtattr a={.rta_type=UNIX_DIAG_PEER,.rta_len=8};
    h.nlmsg_len=sizeof h+sizeof m+8u*(duplicate ? 2u : 1u);
    memcpy(data,&h,sizeof h);memcpy(data+sizeof h,&m,sizeof m);
    size_t at=sizeof h+sizeof m;
    memcpy(data+at,&a,sizeof a);memcpy(data+at+sizeof a,&peer,4);
    if (duplicate) memcpy(data+at+8,data+at,8);
    return h.nlmsg_len;
}
static void parser(void)
{
    unsigned char data[128];struct xrt_unix_peer rows[4];
    size_t n=message(data,20,21,0);
    struct xrt_unix_peers out={.rows=rows,.capacity=4};
    CHECK(xrt_unix_peers_decode(data,n,7,&out) && out.count==1 && rows[0].peer==21 && !out.complete);
    struct nlmsghdr done={.nlmsg_len=sizeof done,.nlmsg_type=NLMSG_DONE,.nlmsg_seq=7};
    CHECK(xrt_unix_peers_decode(&done,sizeof done,7,&out) && out.complete);
    for (size_t i=1;i<n;++i) {
        out=(struct xrt_unix_peers){.rows=rows,.capacity=4};
        CHECK(!xrt_unix_peers_decode(data,i,7,&out) && out.error && !out.count);
    }
    out=(struct xrt_unix_peers){.rows=rows,.capacity=4};
    CHECK(!xrt_unix_peers_decode(data,n,8,&out) && out.error);
    n=message(data,20,21,1);out=(struct xrt_unix_peers){.rows=rows,.capacity=4};
    CHECK(!xrt_unix_peers_decode(data,n,7,&out) && out.error && !out.count);
    n=message(data,20,21,0);out=(struct xrt_unix_peers){.rows=rows,.capacity=0};
    CHECK(!xrt_unix_peers_decode(data,n,7,&out) && out.error==ENOSPC);
    struct nlmsghdr *h=(void *)data;h->nlmsg_flags|=NLM_F_DUMP_INTR;
    out=(struct xrt_unix_peers){.rows=rows,.capacity=4};CHECK(!xrt_unix_peers_decode(data,n,7,&out));
}
static void live(void)
{
    int sock[2],pipefds[2],control[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0,sock));
    CHECK(!pipe(pipefds) && !pipe(control));
    pid_t child=fork();CHECK(child>=0);
    if (!child) {close(control[1]);char ch;ssize_t n=read(control[0],&ch,1);_exit(n==1 ? 0 : 1);}
    close(control[0]);
    struct stat sa,sb,sp;CHECK(!fstat(sock[0],&sa) && !fstat(sock[1],&sb) && !fstat(pipefds[0],&sp));
    CHECK(sa.st_ino<=UINT32_MAX && sb.st_ino<=UINT32_MAX);
    struct xrt_unix_peers a,b;
    /* An expired shared budget sends nothing, even for a valid owned socket. */
    struct xrt_unix_peers expired={0};
    CHECK(xrt_unix_peers_read_until((uint32_t)sa.st_ino,4,1,&expired)==XRT_FILE_UNAVAILABLE);
    CHECK(expired.error==ETIMEDOUT && !expired.complete && !expired.count && !expired.rows && !expired.bytes);
    xrt_unix_peers_free(&expired);
    enum xrt_status ar=xrt_unix_peers_read((uint32_t)sa.st_ino,4,&a);
    enum xrt_status br=xrt_unix_peers_read((uint32_t)sb.st_ino,4,&b);
    int32_t pids[2]={getpid(),child};if (pids[0]>pids[1]) {int32_t swap=pids[0];pids[0]=pids[1];pids[1]=swap;}
    struct xrt_fdscan_options options={.pids=pids,.pid_count=2,.include_self=1};struct xrt_fdscan *scan=NULL;struct xrt_fd_snapshot s;
    CHECK(xrt_fdscan_create(&options,&scan)==XRT_OK);CHECK(xrt_fdscan_poll(scan,&s)==XRT_OK);
    /* Release the owned child before any assertion that can abort this test. */
    CHECK(write(control[1],"q",1)==1);close(control[1]);int status;CHECK(waitpid(child,&status,0)==child && WIFEXITED(status) && !WEXITSTATUS(status));
    if (ar!=XRT_OK || br!=XRT_OK) fprintf(stderr,"UNIX_DIAG: %s / %s\n",a.reason ? a.reason : "ok",b.reason ? b.reason : "ok");
    CHECK(ar==XRT_OK && br==XRT_OK && a.complete && b.complete && a.count==1 && b.count==1);
    CHECK(a.rows[0].peer==sb.st_ino && b.rows[0].peer==sa.st_ino);
    struct xrt_unix_peer peers[2]={a.rows[0],b.rows[0]};
    if (peers[0].inode>peers[1].inode) {struct xrt_unix_peer swap=peers[0];peers[0]=peers[1];peers[1]=swap;}
    struct xrt_fdgraph *g=NULL;CHECK(xrt_fdgraph_build(&s,peers,2,&g)==XRT_OK);
    uint32_t pi=resource(g,sp.st_ino,XRT_FD_PIPE),si=resource(g,sa.st_ino,XRT_FD_SOCKET);
    CHECK(pi!=UINT32_MAX && si!=UINT32_MAX && g->nodes[pi].holders==2 && g->nodes[pi].descriptors==4);
    CHECK(g->nodes[si].holders==2 && g->peer_edges==1);
    xrt_fdgraph_free(g);xrt_fdscan_destroy(scan);xrt_unix_peers_free(&a);xrt_unix_peers_free(&b);
    close(sock[0]);close(sock[1]);close(pipefds[0]);close(pipefds[1]);
}
static uint64_t ns(clockid_t clock)
{
    struct timespec t;CHECK(!clock_gettime(clock,&t));return (uint64_t)t.tv_sec*1000000000u+t.tv_nsec;
}
static uint64_t rss(void)
{
    FILE *f=fopen("/proc/self/statm","r");CHECK(f);unsigned long total,resident;
    CHECK(fscanf(f,"%lu %lu",&total,&resident)==2);CHECK(!fclose(f));return (uint64_t)resident*(uint64_t)sysconf(_SC_PAGESIZE);
}
static void stress(void)
{
    const uint32_t processes=1000,each=100,descriptors=processes*each;
    struct xrt_fd_process *p=calloc(processes,sizeof *p);struct xrt_fd *f=calloc(descriptors,sizeof *f);CHECK(p && f);
    for (uint32_t i=0;i<processes;++i) {
        p[i]=(struct xrt_fd_process){.pid=(int32_t)i+10,.start=i+100,.first=i*each,.count=each};
        for (uint32_t j=0;j<each;++j) f[i*each+j]=(struct xrt_fd){.fd=(int32_t)j,.kind=j ? XRT_FD_REGULAR : XRT_FD_PIPE,
            .flags=XRT_FD_STAT,.device=1,.inode=j ? i*each+j+1000 : 10};
    }
    struct xrt_fd_snapshot s={.sequence=2,.processes=p,.process_count=processes,.fds=f,.fd_count=descriptors};
    struct xrt_fdgraph *g=NULL;struct xrt_fdgraph_projection *v=NULL;
    struct xrt_fdgraph_project_options o={.max_stars=128,.max_particles=1024,.focus_process=UINT32_MAX};
    uint64_t before=rss(),cpu=ns(CLOCK_PROCESS_CPUTIME_ID),wall=ns(CLOCK_MONOTONIC);
    CHECK(xrt_fdgraph_build(&s,NULL,0,&g)==XRT_OK);
    CHECK(g->member_count==descriptors && g->edge_count==descriptors && g->resources==99001);
    CHECK(xrt_fdgraph_project(g,&o,&v)==XRT_OK && v->represented_descriptors==descriptors && v->represented_processes==processes);
    CHECK(v->star_count<=128 && v->particle_count<=1024);
    struct xrt_fdgraph_layout *layout=NULL;CHECK(xrt_fdgraph_layout(g,v,128,256,&layout)==XRT_OK);
    CHECK(layout->resource_count==1 && layout->star_count==128 && layout->link_count==128 && !layout->omitted_links);
    uint32_t shared=0;for(uint32_t i=0;i<layout->link_count;++i) shared+=layout->links[i].descriptors;
    CHECK(shared==processes);xrt_fdgraph_layout_free(layout);
    uint64_t d=0,n=0;for (uint32_t i=0;i<v->star_count;++i) n+=v->stars[i].processes;
    for (uint32_t i=0;i<v->particle_count;++i) d+=v->particles[i].descriptors;
    CHECK(n==processes && d==descriptors);
    printf("{\"processes\":1000,\"descriptors\":100000,\"cpu_ns\":%llu,\"wall_ns\":%llu,\"rss_before\":%llu,\"rss_after\":%llu,\"stars\":%u,\"particles\":%u}\n",
        (unsigned long long)(ns(CLOCK_PROCESS_CPUTIME_ID)-cpu),(unsigned long long)(ns(CLOCK_MONOTONIC)-wall),
        (unsigned long long)before,(unsigned long long)rss(),v->star_count,v->particle_count);
    xrt_fdgraph_projection_free(v);xrt_fdgraph_free(g);free(p);free(f);
}
int main(int argc,char **argv)
{
    /* Fast: pure cases plus owned-socket live checks stay below five seconds. */
    cgroup_projection(argc>1 && !strcmp(argv[1],"--wrong-cgroup"));
    synthetic(argc>1 && !strcmp(argv[1],"--wrong-oracle"));parser();
    if (argc>1 && !strcmp(argv[1],"--live")) live();
    if (argc>1 && !strcmp(argv[1],"--stress")) stress();
    puts("descriptor graph: shared inode, anonymous isolation, stale/denied rows and UNIX peer parser PASS");return 0;
}
