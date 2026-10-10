#define _GNU_SOURCE 1
#include "xrt_fdgraph.h"
#include <errno.h>
#include <fcntl.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/sock_diag.h>
#include <linux/unix_diag.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static int peer_error(struct xrt_unix_peers *out,int error,const char *reason)
{
    out->error=error;out->reason=reason;out->count=0;return 0;
}
int xrt_unix_peers_decode(const void *data,size_t size,uint32_t sequence,struct xrt_unix_peers *out)
{
    if (!out || (!data && size) || !out->rows || out->count>out->capacity || out->error || out->complete) return 0;
    const unsigned char *bytes=data;size_t at=0;
    while (at<size) {
        struct nlmsghdr h;
        if (size-at<sizeof h) return peer_error(out,EPROTO,"UNIX_DIAG short header");
        memcpy(&h,bytes+at,sizeof h);
        if (h.nlmsg_len<sizeof h || h.nlmsg_len>size-at || h.nlmsg_seq!=sequence ||
            (h.nlmsg_flags&NLM_F_DUMP_INTR)) return peer_error(out,EPROTO,"UNIX_DIAG malformed or interrupted dump");
        const unsigned char *payload=bytes+at+sizeof h;size_t n=h.nlmsg_len-sizeof h;
        if (h.nlmsg_type==NLMSG_DONE) {
            int error=0;
            if (n && n<sizeof error) return peer_error(out,EPROTO,"UNIX_DIAG short completion");
            if (n) memcpy(&error,payload,sizeof error);
            if (error) return peer_error(out,error<0 && error!=INT32_MIN ? -error : EPROTO,"UNIX_DIAG completion error");
            if (at+NLMSG_ALIGN(h.nlmsg_len)!=size) return peer_error(out,EPROTO,"UNIX_DIAG data after completion");
            out->complete=1;return 1;
        }
        if (h.nlmsg_type==NLMSG_ERROR) {
            struct nlmsgerr e;
            if (n<sizeof e) return peer_error(out,EPROTO,"UNIX_DIAG short error");
            memcpy(&e,payload,sizeof e);
            return peer_error(out,e.error<0 && e.error!=INT32_MIN ? -e.error : EPROTO,"UNIX_DIAG request refused");
        }
        if (h.nlmsg_type!=SOCK_DIAG_BY_FAMILY || n<sizeof(struct unix_diag_msg))
            return peer_error(out,EPROTO,"UNIX_DIAG unexpected message");
        struct unix_diag_msg m;memcpy(&m,payload,sizeof m);
        if (m.udiag_family!=AF_UNIX || !m.udiag_ino) return peer_error(out,EPROTO,"UNIX_DIAG invalid socket identity");
        uint32_t peer=0;int have_peer=0;
        size_t attr=NLMSG_ALIGN(sizeof m);
        while (attr<n) {
            struct rtattr a;
            if (n-attr<sizeof a) return peer_error(out,EPROTO,"UNIX_DIAG short attribute");
            memcpy(&a,payload+attr,sizeof a);
            if (a.rta_len<sizeof a || a.rta_len>n-attr || RTA_ALIGN(a.rta_len)>n-attr)
                return peer_error(out,EPROTO,"UNIX_DIAG malformed attribute");
            if ((a.rta_type&NLA_TYPE_MASK)==UNIX_DIAG_PEER) {
                if (have_peer || a.rta_type!=UNIX_DIAG_PEER || a.rta_len!=sizeof a+sizeof peer) return peer_error(out,EPROTO,"UNIX_DIAG ambiguous peer");
                memcpy(&peer,payload+attr+sizeof a,sizeof peer);have_peer=1;
            }
            attr+=RTA_ALIGN(a.rta_len);
        }
        if (out->count==out->capacity) return peer_error(out,ENOSPC,"UNIX_DIAG row limit");
        out->rows[out->count++]=(struct xrt_unix_peer){.inode=m.udiag_ino,.peer=peer,.cookie={m.udiag_cookie[0],m.udiag_cookie[1]}};
        size_t next=NLMSG_ALIGN(h.nlmsg_len);
        if (next>size-at) return peer_error(out,EPROTO,"UNIX_DIAG missing alignment");
        at+=next;
    }
    return 1;
}
static uint64_t peer_now(void)
{
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC,&t)) return 0;
    return (uint64_t)t.tv_sec*1000000000u+(uint64_t)t.tv_nsec;
}
static int peer_compare(const void *left,const void *right)
{
    const struct xrt_unix_peer *a=left,*b=right;
    return a->inode<b->inode ? -1 : a->inode!=b->inode;
}
void xrt_unix_peers_free(struct xrt_unix_peers *out)
{
    if (!out) return;
    free(out->rows);memset(out,0,sizeof *out);
}
enum xrt_status xrt_unix_peers_read(uint32_t inode,uint32_t capacity,struct xrt_unix_peers *out)
{
    return xrt_unix_peers_read_until(inode,capacity,0,out);
}
enum xrt_status xrt_unix_peers_read_until(uint32_t inode,uint32_t capacity,uint64_t deadline,struct xrt_unix_peers *out)
{
    if (!out || !capacity || capacity>262144) return XRT_INVALID_ARGUMENT;
    memset(out,0,sizeof *out);out->capacity=capacity<256 ? capacity : 256;out->started_ns=peer_now();
    uint64_t limit=out->started_ns+250000000u;
    if (!deadline || deadline>limit) deadline=limit;
    if (!out->started_ns || out->started_ns>=deadline) {
        peer_error(out,ETIMEDOUT,"UNIX_DIAG deadline");out->taken_ns=out->started_ns;
        return XRT_FILE_UNAVAILABLE;
    }
    out->rows=calloc(out->capacity,sizeof *out->rows);
    if (!out->rows) return XRT_OUT_OF_MEMORY;
    int fd=socket(AF_NETLINK,SOCK_RAW|SOCK_CLOEXEC|SOCK_NONBLOCK,NETLINK_SOCK_DIAG);
    if (fd<0) {peer_error(out,errno,"UNIX_DIAG socket unavailable");return XRT_FILE_UNAVAILABLE;}
    struct {struct nlmsghdr h;struct unix_diag_req r;} request={0};
    request.h.nlmsg_len=NLMSG_LENGTH(sizeof request.r);
    request.h.nlmsg_type=SOCK_DIAG_BY_FAMILY;
    request.h.nlmsg_flags=NLM_F_REQUEST|(inode ? 0 : NLM_F_DUMP);
    request.h.nlmsg_seq=1;
    request.r.sdiag_family=AF_UNIX;request.r.udiag_states=~0u;
    request.r.udiag_ino=inode;request.r.udiag_show=UDIAG_SHOW_PEER;
    request.r.udiag_cookie[0]=request.r.udiag_cookie[1]=UINT32_MAX;
    struct sockaddr_nl kernel={.nl_family=AF_NETLINK};
    if (sendto(fd,&request,request.h.nlmsg_len,0,(struct sockaddr *)&kernel,sizeof kernel)!=(ssize_t)request.h.nlmsg_len)
        peer_error(out,errno ? errno : EIO,"UNIX_DIAG send failed");
    unsigned datagrams=0;
    while (!out->error && !out->complete) {
        uint64_t now=peer_now();
        if (!now || now>=deadline) {peer_error(out,ETIMEDOUT,"UNIX_DIAG deadline");break;}
        struct pollfd wait={.fd=fd,.events=POLLIN};
        int ready=poll(&wait,1,(int)((deadline-now+999999)/1000000));
        if (ready<0 && errno==EINTR) continue;
        if (ready<=0 || !(wait.revents&POLLIN)) {peer_error(out,ready<0 ? errno : ETIMEDOUT,"UNIX_DIAG wait failed");break;}
        unsigned char buffer[32768];struct sockaddr_nl sender={0};
        struct iovec iov={.iov_base=buffer,.iov_len=sizeof buffer};
        struct msghdr msg={.msg_name=&sender,.msg_namelen=sizeof sender,.msg_iov=&iov,.msg_iovlen=1};
        ssize_t n=recvmsg(fd,&msg,0);
        if (n<0 && (errno==EINTR || errno==EAGAIN)) continue;
        if (n<=0 || (msg.msg_flags&MSG_TRUNC) || msg.msg_namelen<sizeof sender || sender.nl_family!=AF_NETLINK || sender.nl_pid) {
            peer_error(out,n<0 ? errno : EPROTO,"UNIX_DIAG receive failed or truncated");break;
        }
        if (++datagrams>4096 || out->bytes>16u*1024*1024-(size_t)n) {peer_error(out,ENOSPC,"UNIX_DIAG byte limit");break;}
        out->bytes+=(size_t)n;
        uint32_t need=out->count+(uint32_t)((size_t)n/(sizeof(struct nlmsghdr)+sizeof(struct unix_diag_msg)));
        if (need>out->capacity && out->capacity<capacity) {
            uint32_t next=out->capacity*2;
            if (next<need) next=need;
            if (next>capacity) next=capacity;
            struct xrt_unix_peer *rows=realloc(out->rows,(size_t)next*sizeof *rows);
            if (!rows) {peer_error(out,ENOMEM,"UNIX_DIAG allocation");break;}
            out->rows=rows;out->capacity=next;
        }
        if (!xrt_unix_peers_decode(buffer,(size_t)n,1,out)) break;
        /* An exact-inode query is a single response, not a dump. */
        if (inode) {
            if (out->count!=1 || out->rows[0].inode!=inode) peer_error(out,EPROTO,"UNIX_DIAG exact identity mismatch");
            else out->complete=1;
        }
    }
    close(fd);out->taken_ns=peer_now();
    if (out->complete && !out->error) {
        qsort(out->rows,out->count,sizeof *out->rows,peer_compare);
        for (uint32_t i=1;i<out->count;++i) if (out->rows[i-1].inode==out->rows[i].inode) {
            peer_error(out,EPROTO,"UNIX_DIAG duplicate socket identity");break;
        }
    }
    if (out->error) return out->error==EPERM || out->error==EACCES ? XRT_PERMISSION_DENIED : XRT_FILE_UNAVAILABLE;
    return XRT_OK;
}
