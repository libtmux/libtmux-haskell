#define _GNU_SOURCE
/* SPIKE: bounded test adapter for the qualified raw guardian. Not production
   transport. It admits argv[0]==file and cwd=/ only and retains lost owners. */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

int guardian_new(int *result);
struct header { int op, key, arg, code; };
enum { READY=1, SPAWNED, STATUS, ADOPTED, COMPLETE, BORN, FAILED, REFUSED,
       SPAWN=10, STOP, ADOPT, RELEASE };
struct request {
    int key, argc, used, sent, hold, returned;
    _Atomic int born, refusal, status, collected;
    int parent[4], child[3], witness;
    size_t size;
    char payload[65520];
};
struct driver {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    int reader;
    int channel, helper, pid;
    int notice[2];
    int force_peer_exit;
    int stop_sent, release_sent;
    _Atomic int ready, full, lost, stopping, reaped, count;
    struct request requests[16];
};

static int readable(int fd) {
    struct pollfd event = {fd, POLLIN, 0};
    return poll(&event, 1, 0) == 1 && (event.revents&POLLIN);
}

static void close_array(int *fds, int n) {
    for (int i=0;i<n;++i) if (fds[i]>=0) { close(fds[i]); fds[i]=-1; }
}

static int pair(int *fds, int kind) {
    int rc=kind ? socketpair(AF_UNIX, SOCK_STREAM|SOCK_CLOEXEC, 0, fds) : pipe2(fds,O_CLOEXEC);
    if (rc) return errno;
    if (kind && (shutdown(fds[0],SHUT_WR) || shutdown(fds[1],SHUT_RD))) return errno;
    for(int i=0;i<2;++i) {
        if(fds[i]>=3) continue;
        int moved=fcntl(fds[i],F_DUPFD_CLOEXEC,3);
        if(moved<0) return errno;
        close(fds[i]);fds[i]=moved;
    }
    return 0;
}

static int send_packet(struct driver *d,struct header h,const void *payload,size_t size,int *fds,int nfds) {
    struct iovec io[2]={{&h,sizeof h},{(void*)payload,size}};
    char ancillary[CMSG_SPACE(3*sizeof(int))]={0};
    struct msghdr message={.msg_iov=io,.msg_iovlen=size?2:1};
    if(nfds) {
        message.msg_control=ancillary;message.msg_controllen=CMSG_SPACE((size_t)nfds*sizeof(int));
        struct cmsghdr *c=CMSG_FIRSTHDR(&message);
        c->cmsg_level=SOL_SOCKET;c->cmsg_type=SCM_RIGHTS;c->cmsg_len=CMSG_LEN((size_t)nfds*sizeof(int));
        memcpy(CMSG_DATA(c),fds,(size_t)nfds*sizeof(int));
    }
    ssize_t rc;
    do {rc=sendmsg(d->channel,&message,MSG_DONTWAIT|MSG_NOSIGNAL);}while(rc<0 && errno==EINTR);
    return rc==(ssize_t)(sizeof h+size)?0:-(rc<0?errno:EIO);
}

/* Only the selected reader dispatches packets; every waiter checks its own
   predicate under the same lock before subscribing to the condition. */
static int receive_locked(struct driver *d) {
    struct header h;
    struct iovec io={&h,sizeof h};
    char ancillary[CMSG_SPACE(sizeof(int))]={0};
    struct msghdr message={.msg_iov=&io,.msg_iovlen=1,.msg_control=ancillary,.msg_controllen=sizeof ancillary};
    ssize_t n;
    do {n=recvmsg(d->channel,&message,MSG_DONTWAIT|MSG_CMSG_CLOEXEC);}while(n<0 && errno==EINTR);
    if(n<0 && errno==EAGAIN) {
        return 0;
    }
    if(n!=(ssize_t)sizeof h || message.msg_flags&(MSG_TRUNC|MSG_CTRUNC)) {
        d->lost=!d->full;return d->full?0:-EPROTO;
    }
    int fd=-1;
    struct cmsghdr *rights=CMSG_FIRSTHDR(&message);
    if(rights && rights->cmsg_level==SOL_SOCKET && rights->cmsg_type==SCM_RIGHTS)
        memcpy(&fd,CMSG_DATA(rights),sizeof fd);
    if(h.op==READY) d->ready=1;
    else if(h.op==COMPLETE && h.code==ECHILD) d->full=1;
    else if(h.key>0 && h.key<=d->count) {
        struct request *r=&d->requests[h.key-1];
        if(h.op==SPAWNED && fd>=0) {
            r->parent[0]=fd;fd=-1;
            r->witness=fcntl(r->parent[0],F_DUPFD_CLOEXEC,3);
            if(r->witness<0)return -errno;
            r->born=1;
        } else if(h.op==BORN) r->born=1;
        else if(h.op==STATUS) {r->status=h.code;++r->collected;}
        else if(h.op==REFUSED) r->refusal=h.code;
        else {if(fd>=0)close(fd);return -EPROTO;}
    } else {if(fd>=0)close(fd);return -EPROTO;}
    if(fd>=0)close(fd);
    return 1;
}

enum condition { WAIT_READY, WAIT_BIRTH, WAIT_STATUS, WAIT_FULL };
static int condition_ready(struct driver *d,struct request *r,enum condition condition) {
    if(condition==WAIT_READY)return d->ready;
    if(condition==WAIT_FULL)return d->full;
    if(condition==WAIT_BIRTH)return r->born || r->refusal;
    return r->collected;
}

static int milliseconds_left(const struct timespec *deadline) {
    struct timespec now;
    if(clock_gettime(CLOCK_MONOTONIC,&now))return 0;
    int64_t left=(deadline->tv_sec-now.tv_sec)*1000000000LL+deadline->tv_nsec-now.tv_nsec;
    return left<=0?0:(int)((left+999999)/1000000);
}

static int wait_readable(int fd) {
    struct timespec deadline;
    if(clock_gettime(CLOCK_MONOTONIC,&deadline))return -errno;
    deadline.tv_nsec+=900000000L;
    if(deadline.tv_nsec>=1000000000L) {++deadline.tv_sec;deadline.tv_nsec-=1000000000L;}
    for(;;) {
        int remaining=milliseconds_left(&deadline);
        if(!remaining)return -ETIMEDOUT;
        struct pollfd event={fd,POLLIN,0};
        int rc=poll(&event,1,remaining);
        if(rc<0 && errno==EINTR)continue;
        if(rc<0)return -errno;
        if(!rc)return -ETIMEDOUT;
        if(event.revents&POLLNVAL)return -EBADF;
        return event.revents&POLLIN?0:-EIO;
    }
}

static int await_condition(struct driver *d,struct request *r,enum condition condition) {
    struct timespec deadline;
    if(clock_gettime(CLOCK_MONOTONIC,&deadline))return -errno;
    deadline.tv_nsec+=900000000L;
    if(deadline.tv_nsec>=1000000000L) {++deadline.tv_sec;deadline.tv_nsec-=1000000000L;}
    pthread_mutex_lock(&d->lock);
    int error=0;
    while(!condition_ready(d,r,condition)) {
        if(d->lost || d->full) {error=-ECHILD;break;}
        if(d->reader) {
            int rc=pthread_cond_timedwait(&d->changed,&d->lock,&deadline);
            if(rc && !condition_ready(d,r,condition)) {error=-rc;break;}
            continue;
        }
        int remaining=milliseconds_left(&deadline);
        if(!remaining) {error=-ETIMEDOUT;break;}
        d->reader=1;
        pthread_mutex_unlock(&d->lock);
        struct pollfd events[2]={{d->channel,POLLIN,0},{d->helper,POLLIN,0}};
        int polled=poll(events,2,remaining);
        int poll_error=polled<0?errno:0;
        pthread_mutex_lock(&d->lock);
        d->reader=0;
        int received;
        do {received=receive_locked(d);}while(received>0);
        if(received<0)d->lost=1;
        if(readable(d->helper) && !d->full)d->lost=1;
        pthread_cond_broadcast(&d->changed);
        if(polled<0 && poll_error==EINTR)continue;
        if(polled<=0 && !condition_ready(d,r,condition)) {error=polled<0?-poll_error:-ETIMEDOUT;break;}
    }
    pthread_mutex_unlock(&d->lock);
    return error;
}

void *libtmux_test_guardian_alloc(void) {
    struct driver *d=calloc(1,sizeof *d);
    if(!d)return NULL;
    d->channel=d->helper=-1;
    if(pthread_mutex_init(&d->lock,NULL)) {free(d);return NULL;}
    pthread_condattr_t attributes;
    if(pthread_condattr_init(&attributes)) {pthread_mutex_destroy(&d->lock);free(d);return NULL;}
    int rc=pthread_condattr_setclock(&attributes,CLOCK_MONOTONIC);
    if(!rc)rc=pthread_cond_init(&d->changed,&attributes);
    pthread_condattr_destroy(&attributes);
    if(rc) {pthread_mutex_destroy(&d->lock);free(d);return NULL;}
    if(pipe2(d->notice,O_CLOEXEC|O_NONBLOCK)) {pthread_cond_destroy(&d->changed);pthread_mutex_destroy(&d->lock);free(d);return NULL;}
    return d;
}

int libtmux_test_guardian_start(struct driver *d) {
    int result[3];
    int rc=guardian_new(result);
    if(rc)return rc;
    d->channel=result[0];d->helper=result[1];d->pid=result[2];
    return await_condition(d,NULL,WAIT_READY);
}

int libtmux_test_guardian_prepare(struct driver *d,const char *file,char *const argv[],char *const env[],const char *cwd,int hold) {
    if(strcmp(file,argv[0]) || strcmp(cwd,"/"))return -ENOTSUP;
    pthread_mutex_lock(&d->lock);
    if(d->stopping || d->count==16) {pthread_mutex_unlock(&d->lock);return -EAGAIN;}
    struct request *r=&d->requests[d->count];
    for(int i=0;i<4;++i)r->parent[i]=-1;
    for(int i=0;i<3;++i)r->child[i]=-1;
    r->witness=-1;r->hold=hold;
    char *const *vectors[2]={argv,env};
    for(int v=0;v<2;++v)for(int i=0;vectors[v][i];++i) {
        size_t n=strlen(vectors[v][i])+1;
        if(r->size+n>sizeof r->payload) {pthread_mutex_unlock(&d->lock);return -E2BIG;}
        memcpy(r->payload+r->size,vectors[v][i],n);r->size+=n;
        if(!v)++r->argc;
    }
    int fds[6]={-1,-1,-1,-1,-1,-1};
    int rc=pair(fds,1);
    if(!rc)rc=pair(fds+2,0);
    if(!rc)rc=pair(fds+4,0);
    int ends[3]={1,2,4};
    for(int i=0;!rc && i<3;++i) {
        int flags=fcntl(fds[ends[i]],F_GETFL);
        if(flags<0 || fcntl(fds[ends[i]],F_SETFL,flags|O_NONBLOCK)<0)rc=errno;
    }
    if(rc) {close_array(fds,6);pthread_mutex_unlock(&d->lock);return -rc;}
    r->parent[1]=fds[1];r->parent[2]=fds[2];r->parent[3]=fds[4];
    r->child[0]=fds[0];r->child[1]=fds[3];r->child[2]=fds[5];
    r->used=1;r->key=++d->count;
    pthread_mutex_unlock(&d->lock);
    return r->key;
}

int libtmux_test_guardian_begin(struct driver *d,int key,int *result) {
    for(int i=0;i<4;++i)result[i]=-1;
    result[4]=6;
    struct request *r=&d->requests[key-1];
    pthread_mutex_lock(&d->lock);
    if(r->sent) {pthread_mutex_unlock(&d->lock);return -EALREADY;}
    r->sent=1;
    int rc=send_packet(d,(struct header){SPAWN,key,r->argc,r->hold},r->payload,r->size,r->child,3);
    /* sendmsg copies a SEQPACKET atomically. No spawn is replayed after this
       call; erase the serialized fields before its ticket can finish. */
    memset(r->payload,0,r->size);r->size=0;
    close_array(r->child,3);
    pthread_mutex_unlock(&d->lock);
    if(rc<0)return rc;
    if(r->hold&2) {
        /* The same ordering probe hands off an already dispatched reply. */
        if((rc=await_condition(d,r,WAIT_BIRTH))<0)return rc;
        char byte=1;
        if(write(d->notice[1],&byte,1)!=1)return -EIO;
    }
    if((rc=await_condition(d,r,WAIT_BIRTH))<0)return rc;
    if(r->refusal) {close_array(r->parent,4);return r->refusal;}
    if(r->hold&1)return -EINPROGRESS;
    for(int i=0;i<4;++i)result[i]=r->parent[i];
    r->returned=1;result[4]=0;
    return 0;
}

int libtmux_test_guardian_wait(struct driver *d,int key,int *result) {
    struct request *r=&d->requests[key-1];
    int rc;
    if((rc=await_condition(d,r,WAIT_STATUS))<0)return rc;
    if(r->collected!=1)return -EPROTO;
    result[0]=WIFEXITED(r->status)?1:(WCOREDUMP(r->status)?3:2);
    result[1]=WIFEXITED(r->status)?WEXITSTATUS(r->status):WTERMSIG(r->status);
    return 1;
}

int libtmux_test_guardian_stop(struct driver *d) {
    int rc=0;
    pthread_mutex_lock(&d->lock);
    d->stopping=1;
    if(!d->stop_sent) {
        rc=send_packet(d,(struct header){STOP,0,0,0},NULL,0,NULL,0);
        if(!rc)d->stop_sent=1;
    }
    int release=d->force_peer_exit;
    for(int i=0;i<d->count;++i)if(d->requests[i].sent && (d->requests[i].hold&1))release=1;
    if(!rc && d->force_peer_exit)rc=wait_readable(d->helper);
    if(!rc && release && !d->release_sent) {
        rc=send_packet(d,(struct header){RELEASE,0,0,0},NULL,0,NULL,0);
        if(!rc)d->release_sent=1;
    }
    pthread_mutex_unlock(&d->lock);
    /* A peer may publish its terminal proof and exit before a follow-up send.
       Drain and classify its verdict; peer closure alone remains no proof. */
    if(rc<0 && rc!=-EPIPE && rc!=-ECONNRESET && rc!=-ENOTCONN)return rc;
    if((rc=await_condition(d,NULL,WAIT_FULL))<0)return rc;
    if(!readable(d->helper)) {
        if((rc=wait_readable(d->helper))<0)return rc;
    }
    for(int i=0;i<d->count;++i)if(d->requests[i].witness>=0 && (rc=wait_readable(d->requests[i].witness))<0)return rc;
    pthread_mutex_lock(&d->lock);
    if(!d->reaped) {
        siginfo_t status={0};
        if(waitid((idtype_t)3,d->helper,&status,WEXITED|WNOHANG)<0) {int error=errno;pthread_mutex_unlock(&d->lock);return -error;}
        if(!status.si_pid) {pthread_mutex_unlock(&d->lock);return -EAGAIN;}
        d->reaped=1;
    }
    pthread_mutex_unlock(&d->lock);
    return 0;
}

int libtmux_test_guardian_retire_pending(struct driver *d,int key) {
    int rc=libtmux_test_guardian_stop(d);
    if(rc)return rc;
    struct request *r=&d->requests[key-1];
    close_array(r->parent,4);
    return 0;
}

int libtmux_test_guardian_kill(struct driver *d) {
    return syscall(SYS_pidfd_send_signal,d->helper,SIGKILL,NULL,0)<0?-errno:0;
}
int libtmux_test_guardian_count(struct driver *d,int key) {return d->requests[key-1].collected;}
int libtmux_test_guardian_full(struct driver *d) {return d->full && d->reaped;}
int libtmux_test_guardian_notice(struct driver *d) {return d->notice[0];}
void libtmux_test_guardian_force_peer_exit(struct driver *d) {d->force_peer_exit=1;}
int libtmux_test_guardian_diagnostic(struct driver *d) {
    siginfo_t status={0};
    if(waitid((idtype_t)3,d->helper,&status,WEXITED|WNOHANG|WNOWAIT)<0)return -errno;
    if(!status.si_pid)return 0;
    return (status.si_code==CLD_EXITED?1000:2000)+status.si_status;
}
int libtmux_test_guardian_prepared_count(struct driver *d) {return d->count;}
int libtmux_test_guardian_collected_count(struct driver *d) {
    int total=0;
    for(int i=0;i<d->count;++i)total+=d->requests[i].collected;
    return total;
}
int libtmux_test_guardian_serialized_bytes(struct driver *d) {
    int total=0;
    pthread_mutex_lock(&d->lock);
    for(int i=0;i<d->count;++i)total+=(int)d->requests[i].size;
    pthread_mutex_unlock(&d->lock);
    return total;
}

int libtmux_test_guardian_release(struct driver *d) {
    int rc=libtmux_test_guardian_stop(d);
    if(rc)return rc; /* A lost context is intentionally retained by the test. */
    for(int i=0;i<d->count;++i) {
        struct request *r=&d->requests[i];
        close_array(r->child,3);
        if(!r->returned)close_array(r->parent,4);
        if(r->witness>=0)close(r->witness);
    }
    close(d->channel);close(d->helper);close_array(d->notice,2);pthread_cond_destroy(&d->changed);pthread_mutex_destroy(&d->lock);free(d);
    return 0;
}

int libtmux_test_guardian_fixture_subreaper(void) {return prctl(PR_SET_CHILD_SUBREAPER,1)?-errno:0;}
int libtmux_test_guardian_witness_exited(int witness) {return readable(witness);}
int libtmux_test_guardian_fixture_collect_helper(struct driver *d) {
    int rc=wait_readable(d->helper);
    if(rc<0)return rc;
    if(!d->reaped) {
        siginfo_t status={0};
        if(waitid((idtype_t)3,d->helper,&status,WEXITED|WNOHANG)<0)return -errno;
        if(!status.si_pid)return -EAGAIN;
        d->reaped=1;
    }
    return 0;
}

int libtmux_test_guardian_witness_server(const char *path) {
    int fd=socket(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC,0);
    if(fd<0)return -errno;
    struct sockaddr_un address={.sun_family=AF_UNIX};
    if(strlen(path)>=sizeof address.sun_path) {close(fd);return -ENAMETOOLONG;}
    strcpy(address.sun_path,path);
    if(bind(fd,(struct sockaddr*)&address,sizeof address) || listen(fd,32)) {int e=errno;close(fd);return -e;}
    return fd;
}
int libtmux_test_guardian_witness_take(int server,int *out) {
    int rc=wait_readable(server);
    if(rc<0)return rc;
    int peer;
    do {peer=accept4(server,NULL,NULL,SOCK_CLOEXEC);}while(peer<0 && errno==EINTR);
    if(peer<0)return -errno;
    if((rc=wait_readable(peer))<0) {close(peer);return rc;}
    int pid=0,fd=-1;
    struct iovec io={&pid,sizeof pid};
    char ancillary[CMSG_SPACE(sizeof fd)]={0};
    struct msghdr message={.msg_iov=&io,.msg_iovlen=1,.msg_control=ancillary,.msg_controllen=sizeof ancillary};
    ssize_t received;
    do {received=recvmsg(peer,&message,MSG_CMSG_CLOEXEC);}while(received<0 && errno==EINTR);
    if(received!=sizeof pid) {close(peer);return -EPROTO;}
    struct cmsghdr *rights=CMSG_FIRSTHDR(&message);
    if(!rights || rights->cmsg_level!=SOL_SOCKET || rights->cmsg_type!=SCM_RIGHTS) {close(peer);return -EPROTO;}
    memcpy(&fd,CMSG_DATA(rights),sizeof fd);
    struct ucred credentials;
    socklen_t size=sizeof credentials;
    if(getsockopt(peer,SOL_SOCKET,SO_PEERCRED,&credentials,&size) || credentials.pid!=pid) {close(fd);close(peer);return -EPROTO;}
    out[0]=fd;out[1]=peer;return 0;
}

int libtmux_test_guardian_fixture_retire(int witness) {
    if(syscall(SYS_pidfd_send_signal,witness,SIGKILL,NULL,0)<0 && errno!=ESRCH)return -errno;
    int rc=wait_readable(witness);
    if(rc<0)return rc;
    siginfo_t status={0};
    if(waitid((idtype_t)3,witness,&status,WEXITED|WNOHANG)<0 && errno!=ECHILD)return -errno;
    return 0;
}
