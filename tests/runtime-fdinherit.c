#define _GNU_SOURCE 1
#include "xrt_fdinherit.h"
#include "check.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Fast lane: pure coverage and a handshake-driven owned fork/exec fixture.
 * The wrong oracle changes a result, and CHECK remains active under NDEBUG. */
static void synthetic(int wrong)
{
    struct xrt_fd_process p[3]={
        {.pid=10,.start=100,.count=6},
        {.pid=20,.ppid=10,.start=101,.first=6,.count=6},
        {.pid=30,.ppid=10,.start=102,.first=12,.count=2,.flags=XRT_FDP_STALE}};
    struct xrt_fd f[14]={0};
    for (unsigned i=0;i<6;++i) {
        f[i]=(struct xrt_fd){.fd=(int)i+3,.kind=XRT_FD_REGULAR,.flags=XRT_FD_STAT|XRT_FD_INFO,.device=1,.inode=30+i*10};
        f[i+6]=f[i];
    }
    f[0].kind=f[6].kind=XRT_FD_PIPE;
    f[1].open_flags=f[7].open_flags=O_CLOEXEC;
    f[2].kind=f[8].kind=XRT_FD_ANON;
    f[9].inode=99;f[10].flags=0;f[11].fd=9;
    f[12]=f[0];f[13]=f[1];
    struct xrt_fd_snapshot s={.processes=p,.process_count=3,.fds=f,.fd_count=14,.sequence=9,.taken_ns=100};
    struct xrt_fdinherit *v=NULL;
    CHECK(xrt_fdinherit_build(&s,2,&v)==XRT_OK);
    CHECK(v->matched==(unsigned)(wrong ? 5 : 4));
    CHECK(v->count==2 && v->capacity==2 && v->dropped==2 && v->stale==2);
    CHECK(v->cloexec==1 && v->no_cloexec==1 && v->flags_unknown==2);
    CHECK(v->parent_pairs==2 && v->parent_unavailable==1 && v->parent_unavailable_fds==6);
    CHECK(v->no_parent_fd==1 && v->different_object==1 && v->identity_unknown==2);
    CHECK(v->matched+v->parent_unavailable_fds+v->no_parent_fd+v->different_object+v->identity_unknown==s.fd_count);
    CHECK(v->rows[0].parent==0 && v->rows[0].child==1 && v->rows[0].parent_fd==0 && v->rows[0].child_fd==6);
    CHECK(v->rows[1].flags==(XRT_FDINH_PARENT_FLAGS_KNOWN|XRT_FDINH_CHILD_FLAGS_KNOWN|XRT_FDINH_PARENT_CLOEXEC|XRT_FDINH_CHILD_CLOEXEC));
    xrt_fdinherit_free(v);
    CHECK(xrt_fdinherit_build(&s,262144,&v)==XRT_OK && v->capacity==64 && v->count==4);
    CHECK((v->rows[2].flags&(XRT_FDINH_CHILD_STALE|XRT_FDINH_IDENTITY_STALE))==(XRT_FDINH_CHILD_STALE|XRT_FDINH_IDENTITY_STALE));
    CHECK(!(v->rows[2].flags&XRT_FDINH_CHILD_FLAGS_KNOWN));xrt_fdinherit_free(v);
    p[0].start=103;
    CHECK(xrt_fdinherit_build(&s,10,&v)==XRT_OK && !v->matched && v->parent_unavailable_fds==14);xrt_fdinherit_free(v);p[0].start=100;
    p[2].first=UINT32_MAX;CHECK(xrt_fdinherit_build(&s,10,&v)==XRT_INVALID_ARGUMENT && !v);p[2].first=12;
    p[1].pid=9;CHECK(xrt_fdinherit_build(&s,10,&v)==XRT_INVALID_ARGUMENT && !v);p[1].pid=20;
    CHECK(xrt_fdinherit_build(&s,0,&v)==XRT_INVALID_ARGUMENT && !v);
    s=(struct xrt_fd_snapshot){0};CHECK(xrt_fdinherit_build(&s,1,&v)==XRT_OK && !v->count && !v->rows && !v->capacity);xrt_fdinherit_free(v);
}
/* Unavailable parents carry a reason; shared std fds fill a full table last. */
static void reasons(void)
{
    struct xrt_fd_process p[6]={
        {.pid=10,.start=100,.count=4},          /* ppid 0: no parent */
        {.pid=20,.ppid=10,.start=101,.first=4,.count=4},
        {.pid=40,.ppid=1,.start=102,.first=8},   /* parent not listed: exited or hidepid */
        {.pid=50,.ppid=5,.start=103,.first=8},   /* parent fd table denied */
        {.pid=60,.ppid=2,.start=104,.first=8},   /* kernel parent */
        {.pid=70,.ppid=10,.start=99,.first=8}};  /* pid 10 was reused after it */
    struct xrt_fd f[8];
    for (unsigned i=0;i<4;++i) {
        f[i]=(struct xrt_fd){.fd=i<3?(int)i:7,.kind=XRT_FD_PIPE,.flags=XRT_FD_STAT,.device=1,.inode=50+i};
        f[i+4]=f[i];
    }
    struct xrt_fd_unseen u[2]={{.pid=2,.kernel=1},{.pid=5,.uid=0,.start=1}};
    struct xrt_fd_snapshot s={.processes=p,.process_count=6,.fds=f,.fd_count=8,.unseen=u,.unseen_count=2};
    struct xrt_fdinherit *v=NULL;
    CHECK(xrt_fdinherit_build(&s,1,&v)==XRT_OK);
    CHECK(v->parent_unavailable==5 && v->parent_denied==1 && v->parent_absent==1 && v->parent_reused==1);
    CHECK(v->matched==4 && v->count==1 && v->dropped==3 && s.fds[v->rows[0].child_fd].fd==7);
    xrt_fdinherit_free(v);
    CHECK(xrt_fdinherit_build(&s,8,&v)==XRT_OK && v->count==4 && s.fds[v->rows[0].child_fd].fd==7 && s.fds[v->rows[1].child_fd].fd==0);
    xrt_fdinherit_free(v);
}
static char byte(int fd)
{
    struct pollfd p={.fd=fd,.events=POLLIN};int n;
    do {n=poll(&p,1,10000);} while(n<0 && errno==EINTR);
    CHECK(n==1 && (p.revents&POLLIN));char ch;CHECK(read(fd,&ch,1)==1);return ch;
}
static const struct xrt_fdinherit_row *find(const struct xrt_fd_snapshot *s,const struct xrt_fdinherit *v,pid_t child,int fd)
{
    for (uint32_t i=0;i<v->count;++i) {
        const struct xrt_fdinherit_row *r=&v->rows[i];
        if (s->processes[r->child].pid==child && s->fds[r->child_fd].fd==fd) return r;
    }
    return NULL;
}
static int after_exec(int argc,char **argv)
{
    CHECK(argc==7);int command=atoi(argv[2]),reply=atoi(argv[3]),keep=atoi(argv[4]),clo=atoi(argv[5]),file=atoi(argv[6]);
    CHECK(fcntl(clo,F_GETFD)==-1 && errno==EBADF);
    CHECK(fcntl(keep,F_GETFD)>=0 && fcntl(file,F_GETFD)>=0);
    CHECK(write(reply,"x",1)==1);CHECK(byte(command)=='q');return 0;
}
static void live(const char *program)
{
    CHECK(!mkdir(".work",0755) || errno==EEXIST);
    char path[]=".work/inherit-file-XXXXXX";int file=mkstemp(path);CHECK(file>=0);
    int data[2],command[2],reply[2];CHECK(!pipe(data) && !pipe(command) && !pipe(reply));
    int clo=fcntl(data[0],F_DUPFD_CLOEXEC,50);CHECK(clo>=50);
    pid_t parent=getpid(),child=fork();CHECK(child>=0);
    if (!child) {
        CHECK(!prctl(PR_SET_PDEATHSIG,SIGKILL) && getppid()==parent);
        close(command[1]);close(reply[0]);
        /* Same inode and fd number, but a new open file description. Its
         * independent offset proves why a polling match is not provenance. */
        close(file);int reopened=open(path,O_RDWR);CHECK(reopened>=0);
        if (reopened!=file) {CHECK(dup2(reopened,file)==file);close(reopened);}
        CHECK(lseek(file,123,SEEK_SET)==123);CHECK(write(reply[1],"r",1)==1);
        CHECK(byte(command[0])=='t');CHECK(!fcntl(clo,F_SETFD,0));CHECK(write(reply[1],"t",1)==1);
        CHECK(byte(command[0])=='e');CHECK(!fcntl(clo,F_SETFD,FD_CLOEXEC));
        char a[24],b[24],c[24],d[24],e[24];
        snprintf(a,sizeof a,"%d",command[0]);snprintf(b,sizeof b,"%d",reply[1]);snprintf(c,sizeof c,"%d",data[0]);snprintf(d,sizeof d,"%d",clo);snprintf(e,sizeof e,"%d",file);
        execl(program,program,"--after-exec",a,b,c,d,e,(char *)NULL);_exit(99);
    }
    close(command[0]);close(reply[1]);CHECK(byte(reply[0])=='r');CHECK(lseek(file,0,SEEK_CUR)==0);
    int32_t pids[2]={parent,child};
    struct xrt_fdscan_options opts={.pids=pids,.pid_count=2,.include_self=1,.adaptive=1,.max_processes=8,.max_fds=256,.max_strings=32768};
    struct xrt_fdscan *scan=NULL;CHECK(xrt_fdscan_create(&opts,&scan)==XRT_OK);
    CHECK(xrt_fdscan_interest(scan,NULL,0,1)==XRT_OK);xrt_fdscan_fdinfo(scan,1);
    struct xrt_fd_snapshot snapshot;struct xrt_fdinherit *v=NULL;
    CHECK(xrt_fdscan_poll(scan,&snapshot)==XRT_OK && snapshot.process_count==2);
    CHECK(xrt_fdinherit_build(&snapshot,256,&v)==XRT_OK);
    const struct xrt_fdinherit_row *r=find(&snapshot,v,child,clo);CHECK(r && (r->flags&XRT_FDINH_CHILD_CLOEXEC));
    r=find(&snapshot,v,child,data[0]);CHECK(r && (r->flags&XRT_FDINH_CHILD_FLAGS_KNOWN) && !(r->flags&XRT_FDINH_CHILD_CLOEXEC));
    r=find(&snapshot,v,child,file);CHECK(r && snapshot.fds[r->child_fd].pos==123 && snapshot.fds[r->parent_fd].pos==0);
    xrt_fdinherit_free(v);CHECK(write(command[1],"t",1)==1);CHECK(byte(reply[0])=='t');
    CHECK(xrt_fdscan_poll(scan,&snapshot)==XRT_OK);
    CHECK(xrt_fdinherit_build(&snapshot,256,&v)==XRT_OK);
    r=find(&snapshot,v,child,clo);CHECK(r && (r->flags&XRT_FDINH_CHILD_FLAGS_KNOWN) && !(r->flags&XRT_FDINH_CHILD_CLOEXEC));
    CHECK(r->flags&XRT_FDINH_PARENT_CLOEXEC);xrt_fdinherit_free(v);
    CHECK(write(command[1],"e",1)==1);CHECK(byte(reply[0])=='x');
    CHECK(xrt_fdscan_poll(scan,&snapshot)==XRT_OK && snapshot.process_count==2);
    CHECK(xrt_fdinherit_build(&snapshot,256,&v)==XRT_OK);
    CHECK(!find(&snapshot,v,child,clo) && find(&snapshot,v,child,data[0]) && find(&snapshot,v,child,file));
    xrt_fdinherit_free(v);xrt_fdscan_destroy(scan);
    CHECK(write(command[1],"q",1)==1);close(command[1]);close(reply[0]);
    int status;CHECK(waitpid(child,&status,0)==child && WIFEXITED(status) && !WEXITSTATUS(status));
    close(clo);close(data[0]);close(data[1]);close(file);CHECK(!unlink(path));
    puts("owned fork/exec: CLOEXEC closes, ordinary fd survives, independent reopen stays a sampled match PASS");
}
int main(int argc,char **argv)
{
    if (argc>1 && !strcmp(argv[1],"--after-exec")) return after_exec(argc,argv);
    synthetic(argc>1 && !strcmp(argv[1],"--wrong-oracle"));
    reasons();
    if (argc>1 && !strcmp(argv[1],"--live")) live(argv[0]);
    puts("parent/child descriptor comparison: bounded, stale, flags and exhaustive accounting PASS");return 0;
}
