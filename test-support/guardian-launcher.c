#define _GNU_SOURCE
#include <fcntl.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <unistd.h>

/* Test-only launcher: the child supplies its own pidfd independently of every
   candidate descriptor, then holds an unrelated control connection open. */
static int self_witness(int gate) {
    int peer=socket(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC,0);
    struct sockaddr_un address={.sun_family=AF_UNIX};
    if(sizeof WITNESS_SOCKET>sizeof address.sun_path)return 82;
    memcpy(address.sun_path,WITNESS_SOCKET,sizeof WITNESS_SOCKET);
    if(connect(peer,(struct sockaddr*)&address,sizeof address))return 83;
    int self=getpid(),fd=syscall(SYS_pidfd_open,self,0);
    struct iovec io={&self,sizeof self};
    char ancillary[CMSG_SPACE(sizeof fd)]={0};
    struct msghdr message={.msg_iov=&io,.msg_iovlen=1,.msg_control=ancillary,.msg_controllen=sizeof ancillary};
    struct cmsghdr *rights=CMSG_FIRSTHDR(&message);
    rights->cmsg_level=SOL_SOCKET;rights->cmsg_type=SCM_RIGHTS;rights->cmsg_len=CMSG_LEN(sizeof fd);
    memcpy(CMSG_DATA(rights),&fd,sizeof fd);
    if(sendmsg(peer,&message,0)!=sizeof self)return 84;
    close(fd);
    char byte=1;
    if(gate>=0) {
        if(write(gate,&byte,1)!=1)return 85;
        close(gate);
    }
    if(read(peer,&byte,1)!=1)return 86;
    return 0;
}

int main(int argc,char **argv) {
    if(argc==2 && !strcmp(argv[1],"--application"))return self_witness(-1);
    int startup=argc>1 && !strcmp(argv[1],"-D");
    if (startup || LAUNCHER_MODE==3) {
        int gate[2];
        if(pipe2(gate,O_CLOEXEC))return 80;
        int pid=fork();
        if(pid<0)return 81;
        if(!pid) {
            close(gate[0]);close(0);close(1);close(2);
            _exit(self_witness(gate[1]));
        }
        close(gate[1]);
        char byte;
        if(read(gate[0],&byte,1)!=1)return 87;
        close(gate[0]);
        if(startup && LAUNCHER_MODE==1)return 0;
    }
    argv[0]=REAL_TMUX;
    execv(REAL_TMUX,argv);
    return 88;
}
