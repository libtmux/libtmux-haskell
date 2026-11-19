#define _GNU_SOURCE
/* Kernel-model fixture, not the production Haskell FFI helper. */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/signalfd.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

enum { READY = 1, SPAWNED, STATUS, ADOPTED, COMPLETE, BORN, FAILED, REFUSED,
       SPAWN = 10, STOP, ADOPT, RELEASE };
struct header { int op, key, arg, code; };
struct child { int pid, fd, key; };
static struct child children[4096];
static size_t count;
static int control, signal_fd, closing, held;
static unsigned long collected;

static void fail(const char *message) {
    perror(message);
    _exit(90); /* No terminal proof is emitted on helper failure. */
}

static void send_event(int op, int key, int arg, int code, int fd) {
    struct header event = {op, key, arg, code};
    struct iovec io = {&event, sizeof event};
    char ancillary[CMSG_SPACE(sizeof fd)] = {0};
    struct msghdr msg = {.msg_iov = &io, .msg_iovlen = 1};
    if (fd >= 0) {
        msg.msg_control = ancillary;
        msg.msg_controllen = sizeof ancillary;
        struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof fd);
        memcpy(CMSG_DATA(c), &fd, sizeof fd);
    }
    if (sendmsg(control, &msg, MSG_NOSIGNAL) != sizeof event) fail("send event");
}

static struct child *find_child(int pid) {
    for (size_t i = 0; i < count; ++i)
        if (children[i].pid == pid) return &children[i];
    return NULL;
}

static void add_child(int pid, int fd, int key) {
    if (count == sizeof children / sizeof children[0]) {
        close(fd);
        errno = ENOSPC;
        fail("child model bound");
    }
    children[count++] = (struct child){pid, fd, key};
}

static void note_child(int pid) {
    if (find_child(pid)) return;
    /* Only our unreaped kernel children are supplied here. No other process
       can reap them, so this PID cannot recycle before pidfd_open. */
    int fd = syscall(SYS_pidfd_open, pid, 0);
    if (fd < 0) fail("own child pidfd");
    add_child(pid, fd, 0);
}

static void refresh_children(void) {
    char path[80];
    snprintf(path, sizeof path, "/proc/self/task/%ld/children", syscall(SYS_gettid));
    int file = open(path, O_RDONLY | O_CLOEXEC);
    if (file < 0) fail("own children");
    char buffer[4096];
    long value = 0;
    int digits = 0;
    for (;;) {
        ssize_t size = read(file, buffer, sizeof buffer);
        if (size < 0 && errno == EINTR) continue;
        if (size < 0) fail("read own children");
        if (!size) break;
        for (ssize_t i = 0; i < size; ++i) {
            unsigned char byte = (unsigned char)buffer[i];
            if (byte >= '0' && byte <= '9') {
                value = value * 10 + byte - '0';
                digits = 1;
                if (value > INT_MAX) fail("own child number");
            } else {
                if (digits) note_child((int)value);
                value = 0;
                digits = 0;
            }
        }
    }
    if (digits) note_child((int)value);
    close(file);
}

static int pidfd_pid(int fd) {
    char path[80], buffer[1024];
    snprintf(path, sizeof path, "/proc/self/fdinfo/%d", fd);
    int file = open(path, O_RDONLY | O_CLOEXEC);
    if (file < 0) return -1;
    ssize_t size = read(file, buffer, sizeof buffer - 1);
    close(file);
    if (size <= 0) return -1;
    buffer[size] = 0;
    char *field = strstr(buffer, "\nPid:\t");
    return field ? (int)strtol(field + 6, NULL, 10) : -1;
}

static int collect_children(void) {
    for (;;) {
        int status;
        int pid = waitpid(-1, &status, WNOHANG | __WALL);
        if (!pid) return 0;
        if (pid < 0) {
            if (errno == EINTR) continue;
            if (errno == ECHILD) return 1;
            fail("wait own children");
        }
        ++collected;
        for (size_t i = 0; i < count; ++i) {
            if (children[i].pid != pid) continue;
            if (children[i].key)
                send_event(STATUS, children[i].key, pid, status, -1);
            close(children[i].fd);
            children[i] = children[--count];
            break;
        }
    }
}

static void advance_cleanup(void) {
    refresh_children();
    if (closing) {
        /* Immediate SIGKILL is a model shortcut. Production needs the normal
           TERM/grace/KILL policy and bounded nonblocking transport. */
        for (size_t i = 0; i < count; ++i) {
            if (syscall(SYS_pidfd_send_signal, children[i].fd, SIGKILL, NULL, 0) < 0
                && errno != ESRCH) fail("signal own child");
        }
    }
    int empty = collect_children();
    if (closing && empty) {
        if (count) fail("ECHILD with held child");
        /* Single-threaded guardian, birth admission already closed. It can
           never fork again after publishing this live ECHILD observation. */
        send_event(COMPLETE, 0, (int)collected, ECHILD, -1);
        _exit(0);
    }
    if (closing) {
        /* Reaping can adopt a live child without another SIGCHLD. Refresh and
           signal the new direct children before blocking for the next event. */
        refresh_children();
        for (size_t i = 0; i < count; ++i)
            if (syscall(SYS_pidfd_send_signal, children[i].fd, SIGKILL, NULL, 0) < 0
                && errno != ESRCH) fail("signal adopted child");
    }
}

static void spawn_command(struct header h, char *payload, size_t size, int *fds, int nfds) {
    if (closing) {
        send_event(REFUSED, h.key, 0, ESHUTDOWN, -1);
        return;
    }
    char *argv[1024], *env[2048];
    size_t offset = 0, argc = 0, envc = 0;
    if (h.arg < 1 || h.arg >= 1024 || nfds != 3) fail("spawn packet");
    while (offset < size) {
        char *string = payload + offset;
        size_t length = strnlen(string, size - offset);
        if (length == size - offset) fail("unterminated vector");
        if (argc < (size_t)h.arg) argv[argc++] = string;
        else {
            if (envc >= 2047) fail("environment model bound");
            env[envc++] = string;
        }
        offset += length + 1;
    }
    if (argc != (size_t)h.arg) fail("short argv");
    argv[argc] = NULL;
    env[envc] = NULL;
    int pidfd = -1;
    int pid = syscall(SYS_clone, SIGCHLD | CLONE_PIDFD, NULL, &pidfd, NULL, 0);
    if (pid < 0) {
        send_event(REFUSED, h.key, 0, errno, -1);
        return;
    }
    if (!pid) {
        sigset_t empty;
        sigemptyset(&empty);
        if (sigprocmask(SIG_SETMASK, &empty, NULL)) _exit(91);
        for (int i = 0; i < 3; ++i)
            if (dup2(fds[i], i) < 0) _exit(92);
        if (syscall(SYS_close_range, 3, UINT_MAX, 0)) _exit(93);
        execve(argv[0], argv, env);
        _exit(127);
    }
    add_child(pid, pidfd, h.key);
    if (h.code & 1) {
        held = 1;
        send_event(BORN, h.key, 0, 0, -1);
    } else send_event(SPAWNED, h.key, pid, 0, pidfd);
}

static void receive_command(void) {
    union { struct header alignment; char bytes[65536]; } packet;
    char ancillary[CMSG_SPACE(8 * sizeof(int))] = {0};
    struct iovec io = {packet.bytes, sizeof packet.bytes};
    struct msghdr msg = {.msg_iov = &io, .msg_iovlen = 1,
        .msg_control = ancillary, .msg_controllen = sizeof ancillary};
    ssize_t size = recvmsg(control, &msg, MSG_CMSG_CLOEXEC);
    if (size < 0 && errno == EINTR) return;
    if (size <= 0) fail("control lost");
    if (size < (ssize_t)sizeof(struct header) || msg.msg_flags & (MSG_TRUNC | MSG_CTRUNC))
        fail("control packet");
    int fds[8], nfds = 0;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS) continue;
        int n = (int)((c->cmsg_len - CMSG_LEN(0)) / sizeof(int));
        if (nfds + n > 8) fail("control descriptors");
        memcpy(fds + nfds, CMSG_DATA(c), n * sizeof(int));
        nfds += n;
    }
    struct header h;
    memcpy(&h, packet.bytes, sizeof h);
    if (h.op == SPAWN) spawn_command(h, packet.bytes + sizeof h, size - sizeof h, fds, nfds);
    else if (h.op == STOP) closing = 1;
    else if (h.op == RELEASE) held = 0;
    else if (h.op == ADOPT && nfds == 1) {
        refresh_children();
        int pid = pidfd_pid(fds[0]);
        struct child *child = find_child(pid);
        if (child && pidfd_pid(child->fd) == pid)
            send_event(ADOPTED, h.key, pid, 0, child->fd);
        else send_event(REFUSED, h.key, pid, EXDEV, -1);
    } else fail("unknown command");
    for (int i = 0; i < nfds; ++i) close(fds[i]);
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    control = atoi(argv[1]);
    if (fcntl(control, F_SETFD, FD_CLOEXEC)) fail("control cloexec");
    char self[80];
    ssize_t size = readlink("/proc/self", self, sizeof self - 1);
    if (size < 1) fail("proc self");
    self[size] = 0;
    if (strtol(self, NULL, 10) != getpid()) fail("proc namespace mismatch");
    struct sigaction action = {.sa_handler = SIG_DFL};
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGCHLD, &action, NULL)) fail("SIGCHLD policy");
    if (prctl(PR_SET_CHILD_SUBREAPER, 1)) fail("subreaper");
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGCHLD);
    if (sigprocmask(SIG_BLOCK, &mask, NULL)) fail("SIGCHLD block");
    signal_fd = signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
    if (signal_fd < 0) fail("signalfd");
    send_event(READY, 0, getpid(), 0, -1);
    for (;;) {
        struct pollfd events[2] = {{control, POLLIN, 0}, {signal_fd, held ? 0 : POLLIN, 0}};
        if (poll(events, 2, -1) < 0) {
            if (errno == EINTR) continue;
            fail("poll");
        }
        if (events[0].revents) receive_command();
        if (!held && events[1].revents) {
            struct signalfd_siginfo info;
            while (read(signal_fd, &info, sizeof info) == sizeof info) {}
            if (errno != EAGAIN) fail("SIGCHLD read");
        }
        if (!held) advance_cleanup();
    }
}
