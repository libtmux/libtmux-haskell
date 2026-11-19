#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>

static int readable(int fd) {
    struct pollfd event = {fd, POLLIN, 0};
    return poll(&event, 1, 0) == 1 && (event.revents&POLLIN);
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

int libtmux_test_guardian_fixture_subreaper(void) {return prctl(PR_SET_CHILD_SUBREAPER,1)?-errno:0;}
int libtmux_test_guardian_witness_exited(int witness) {return readable(witness);}
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

int libtmux_test_guardian_witness_pending(int fd) {return readable(fd);}
