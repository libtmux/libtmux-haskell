#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* One request is retained before transport. Its token never repeats within a
   guardian lifetime; storage is released independently after collection. */
struct request {
    int sent, argc, parent[4], child[3];
    size_t size;
    char payload[65520];
};
struct header { int op, key, arg, code; };

static void close_fds(int *fds, int n) {
    for (int i=0; i<n; ++i) if (fds[i]>=0) { close(fds[i]); fds[i]=-1; }
}
static int move_high(int *fd) {
    if (*fd>=3) return 0;
    int moved=fcntl(*fd,F_DUPFD_CLOEXEC,3);
    if (moved<0) return errno;
    close(*fd); *fd=moved;
    return 0;
}
static int pair(int *fds, int stream) {
    int rc=stream ? socketpair(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0,fds) : pipe2(fds,O_CLOEXEC);
    if (rc) return errno;
    if (stream && (shutdown(fds[0],SHUT_WR) || shutdown(fds[1],SHUT_RD))) return errno;
    int e=move_high(fds);
    return e ? e : move_high(fds+1);
}

void *libtmux_guardian_prepare(const char *file,char *const argv[],char *const env[],const char *cwd,int discard,int *error) {
    *error=0;
    struct request *r=calloc(1,sizeof *r);
    if (!r) { *error=ENOMEM; return NULL; }
    for (int i=0; i<4; ++i) r->parent[i]=-1;
    for (int i=0; i<3; ++i) r->child[i]=-1;
    const char *fixed[3]={file,cwd,NULL};
    const char *const *vectors[3]={fixed,(const char *const *)argv,(const char *const *)env};
    for (int v=0; v<3; ++v) for (int i=0; vectors[v][i]; ++i) {
        size_t n=strlen(vectors[v][i])+1;
        if (n>sizeof r->payload-r->size) { *error=E2BIG; goto refused; }
        memcpy(r->payload+r->size,vectors[v][i],n); r->size+=n;
        if (v==1) ++r->argc;
    }
    int fds[6]={-1,-1,-1,-1,-1,-1};
    *error=pair(fds,1);
    if (!*error) *error=pair(fds+2,0);
    if (!*error) *error=pair(fds+4,0);
    if (!*error && discard) {
        int null=open("/dev/null",O_WRONLY|O_CLOEXEC);
        if (null<0) *error=errno;
        else { *error=move_high(&null); if (!*error) {close(fds[3]);fds[3]=null;} else close(null); }
    }
    int ends[3]={1,2,4};
    for (int i=0; !*error && i<3; ++i) {
        int flags=fcntl(fds[ends[i]],F_GETFL);
        if (flags<0 || fcntl(fds[ends[i]],F_SETFL,flags|O_NONBLOCK)<0) *error=errno;
    }
    if (*error) {close_fds(fds,6);goto refused;}
    r->parent[1]=fds[1];r->parent[2]=fds[2];r->parent[3]=fds[4];
    r->child[0]=fds[0];r->child[1]=fds[3];r->child[2]=fds[5];
    return r;
refused:
    free(r);
    return NULL;
}

/* Nonblocking SEQPACKET sends are atomic. EAGAIN creates no birth and is the
   only retryable result; a successful request is never sent twice. */
int libtmux_guardian_send(int channel,int op,int key,int arg,struct request *r,int fd) {
    if (r && r->sent) return EALREADY;
    struct header h={op,key,r?r->argc:arg,0};
    struct iovec io[2]={{&h,sizeof h},{r?r->payload:NULL,r?r->size:0}};
    char ancillary[CMSG_SPACE(3*sizeof(int))]={0};
    struct msghdr message={.msg_iov=io,.msg_iovlen=r?2:1};
    int nfds=r?3:(fd>=0?1:0);
    if (nfds) {
        message.msg_control=ancillary;message.msg_controllen=CMSG_SPACE((size_t)nfds*sizeof(int));
        struct cmsghdr *c=CMSG_FIRSTHDR(&message);
        c->cmsg_level=SOL_SOCKET;c->cmsg_type=SCM_RIGHTS;c->cmsg_len=CMSG_LEN((size_t)nfds*sizeof(int));
        memcpy(CMSG_DATA(c),r?r->child:&fd,(size_t)nfds*sizeof(int));
    }
    ssize_t n;
    do {n=sendmsg(channel,&message,MSG_DONTWAIT|MSG_NOSIGNAL);}while(n<0 && errno==EINTR);
    if (n<0) return errno;
    if (n!=(ssize_t)(sizeof h+(r?r->size:0))) return EIO;
    if (r) {
        r->sent=1;
        memset(r->payload,0,r->size);r->size=0;
        close_fds(r->child,3);
    }
    return 0;
}

int libtmux_guardian_receive(int channel,int *out) {
    for (int i=0;i<5;++i) out[i]=-1;
    struct header h;
    struct iovec io={&h,sizeof h};
    char ancillary[CMSG_SPACE(8*sizeof(int))]={0};
    struct msghdr message={.msg_iov=&io,.msg_iovlen=1,.msg_control=ancillary,.msg_controllen=sizeof ancillary};
    ssize_t n;
    do {n=recvmsg(channel,&message,MSG_DONTWAIT|MSG_CMSG_CLOEXEC);}while(n<0 && errno==EINTR);
    if (n<0) return errno==EAGAIN?0:-errno;
    int fds[8],nfds=0;
    for(struct cmsghdr *c=CMSG_FIRSTHDR(&message);c;c=CMSG_NXTHDR(&message,c)) {
        if(c->cmsg_level!=SOL_SOCKET || c->cmsg_type!=SCM_RIGHTS || c->cmsg_len<CMSG_LEN(0))continue;
        size_t count=(c->cmsg_len-CMSG_LEN(0))/sizeof(int);
        if(count>8-(size_t)nfds) {close_fds(fds,nfds);return -EPROTO;}
        memcpy(fds+nfds,CMSG_DATA(c),count*sizeof(int));nfds+=(int)count;
    }
    if (n!=sizeof h || message.msg_flags&(MSG_TRUNC|MSG_CTRUNC) || nfds>1) {
        close_fds(fds,nfds);return -EPROTO;
    }
    out[0]=h.op;out[1]=h.key;out[2]=h.arg;out[3]=h.code;
    if(nfds)out[4]=fds[0];
    return 1;
}

int libtmux_guardian_accept(struct request *r,int fd) {
    if(r->parent[0]>=0)return EALREADY;
    r->parent[0]=fd;return 0;
}
void libtmux_guardian_take(struct request *r,int *result) {
    for(int i=0;i<4;++i)result[i]=r->parent[i];
    result[4]=0;
}
/* The pool commits only after its own child/descriptor journal is installed. */
void libtmux_guardian_commit(struct request *r) {
    for(int i=0;i<4;++i)r->parent[i]=-1;
    close_fds(r->child,3);free(r);
}
void libtmux_guardian_retire(struct request *r) {
    close_fds(r->parent,4);close_fds(r->child,3);free(r);
}
