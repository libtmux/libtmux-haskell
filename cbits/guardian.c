#define _GNU_SOURCE
/* Private, lifetime subreaper. Only the host side may call libc. */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <sys/signalfd.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

enum { READY = 1, SPAWNED, STATUS, ADOPTED, COMPLETE, BORN, FAILED, REFUSED,
       SPAWN = 10, STOP, ADOPT, RELEASE, CANCEL };
struct header { int op, key, arg, code; };
struct child { int pid, fd, key, execfd, failure, published; };
struct context {
    int control, signal_fd, closing, held;
    unsigned count, collected;
    struct child children[4096];
    union { struct header alignment; char bytes[65536]; } packet;
};

/* Raw x86_64 syscall convention reused from frozen R3's audited helper layer.
   The ownership proof is the new lifetime subreaper model, not R3 journaling. */
#if !defined(__x86_64__)
#define GUARDIAN_UNSUPPORTED 1
#else
#pragma GCC push_options
#pragma GCC optimize("no-tree-loop-distribute-patterns")
#define HF __attribute__((no_stack_protector))
#define HENTRY __attribute__((noinline, no_stack_protector, noreturn))
static inline long h_raw(long n, long a, long b, long c, long d, long e, long f) {
    long result;
    register long r10 __asm__("r10") = d;
    register long r8 __asm__("r8") = e;
    register long r9 __asm__("r9") = f;
    __asm__ volatile("syscall" : "=a"(result)
        : "0"(n), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8), "r"(r9)
        : "rcx", "r11", "memory");
    return result;
}
#define R0(n) h_raw((n), 0, 0, 0, 0, 0, 0)
#define R1(n,a) h_raw((n), (long)(a), 0, 0, 0, 0, 0)
#define R2(n,a,b) h_raw((n), (long)(a), (long)(b), 0, 0, 0, 0)
#define R3(n,a,b,c) h_raw((n), (long)(a), (long)(b), (long)(c), 0, 0, 0)
#define R4(n,a,b,c,d) h_raw((n), (long)(a), (long)(b), (long)(c), (long)(d), 0, 0)
#define R5(n,a,b,c,d,e) h_raw((n), (long)(a), (long)(b), (long)(c), (long)(d), (long)(e), 0)

static HENTRY void h_exit(int status) {
    R1(SYS_exit_group, status);
    __builtin_unreachable();
}

static HF void h_copy(void *target, const void *source, unsigned size) {
    unsigned char *to = target;
    const unsigned char *from = source;
    for (unsigned i = 0; i < size; ++i) to[i] = from[i];
}

static HF unsigned h_append(char *to, unsigned at, const char *text) {
    for (unsigned i = 0; text[i]; ++i) to[at++] = text[i];
    return at;
}

static HF unsigned h_number(char *to, unsigned at, unsigned value) {
    char digits[16];
    unsigned size = 0;
    do { digits[size++] = (char)('0' + value % 10); value /= 10; } while (value);
    while (size) to[at++] = digits[--size];
    return at;
}

static HF int h_parse(const char *text, unsigned size) {
    unsigned value = 0;
    if (!size || text[0] < '0' || text[0] > '9') return -1;
    for (unsigned i = 0; i < size && text[i] >= '0' && text[i] <= '9'; ++i) {
        if (value > (INT_MAX - 9U) / 10U) return -1;
        value = value * 10 + text[i] - '0';
    }
    return (int)value;
}

static HF void h_send(struct context *c, int op, int key, int arg, int code, int fd) {
    struct header event = {op, key, arg, code};
    struct iovec io = {&event, sizeof event};
    char ancillary[CMSG_SPACE(sizeof fd)] = {0};
    struct msghdr msg = {.msg_iov = &io, .msg_iovlen = 1};
    if (fd >= 0) {
        msg.msg_control = ancillary;
        msg.msg_controllen = sizeof ancillary;
        struct cmsghdr *header = CMSG_FIRSTHDR(&msg);
        header->cmsg_level = SOL_SOCKET;
        header->cmsg_type = SCM_RIGHTS;
        header->cmsg_len = CMSG_LEN(sizeof fd);
        h_copy(CMSG_DATA(header), &fd, sizeof fd);
    }
    if (R3(SYS_sendmsg, c->control, &msg, MSG_NOSIGNAL) != sizeof event) h_exit(90);
}

static HF struct child *h_find(struct context *c, int pid) {
    for (unsigned i = 0; i < c->count; ++i)
        if (c->children[i].pid == pid) return &c->children[i];
    return NULL;
}

static HF void h_add(struct context *c, int pid, int fd, int key) {
    if (c->count == sizeof c->children / sizeof c->children[0]) h_exit(91);
    c->children[c->count++] = (struct child){.pid=pid, .fd=fd, .key=key, .execfd=-1};
}

static HF void h_note(struct context *c, int pid) {
    if (h_find(c, pid)) return;
    /* Exclusive reaper; no wait while listing/authenticating own children. */
    long fd = R2(SYS_pidfd_open, pid, 0);
    if (fd < 0) h_exit(92);
    h_add(c, pid, (int)fd, 0);
}

static HF void h_refresh(struct context *c) {
    char path[80];
    unsigned at = h_append(path, 0, "/proc/self/task/");
    at = h_number(path, at, (unsigned)R0(SYS_gettid));
    at = h_append(path, at, "/children");
    path[at] = 0;
    long file = R4(SYS_openat, AT_FDCWD, path, O_RDONLY | O_CLOEXEC, 0);
    if (file < 0) h_exit(93);
    char buffer[4096];
    long value = 0;
    int digits = 0;
    for (;;) {
        long size = R3(SYS_read, file, buffer, sizeof buffer);
        if (size == -EINTR) continue;
        if (size < 0) h_exit(94);
        if (!size) break;
        for (long i = 0; i < size; ++i) {
            unsigned char byte = (unsigned char)buffer[i];
            if (byte >= '0' && byte <= '9') {
                if (value > (INT_MAX - 9L) / 10L) h_exit(95);
                value = value * 10 + byte - '0';
                digits = 1;
            } else {
                if (digits) h_note(c, (int)value);
                value = 0;
                digits = 0;
            }
        }
    }
    if (digits) h_note(c, (int)value);
    R1(SYS_close, file);
}

static HF int h_pidfd_pid(int fd) {
    char path[80], buffer[1024];
    unsigned at = h_append(path, 0, "/proc/self/fdinfo/");
    at = h_number(path, at, (unsigned)fd);
    path[at] = 0;
    long file = R4(SYS_openat, AT_FDCWD, path, O_RDONLY | O_CLOEXEC, 0);
    if (file < 0) return -1;
    long size = R3(SYS_read, file, buffer, sizeof buffer);
    R1(SYS_close, file);
    if (size < 1) return -1;
    for (long i = 0; i + 6 < size; ++i) {
        const char field[] = "\nPid:\t";
        unsigned j = 0;
        for (; j < sizeof field - 1 && buffer[i + j] == field[j]; ++j) {}
        if (j == sizeof field - 1) return h_parse(buffer + i + j, (unsigned)(size - i - j));
    }
    return -1;
}

static HF void h_exec_ready(struct context *c, struct child *child) {
    if (child->execfd < 0) return;
    int failure = 0;
    long n = R3(SYS_read, child->execfd, &failure, sizeof failure);
    if (n == -EINTR || n == -EAGAIN) return;
    if (n != 0 && n != sizeof failure) h_exit(122);
    R1(SYS_close, child->execfd);
    child->execfd = -1;
    if (n) { child->failure = failure; return; }
    child->published = 1;
    h_send(c, SPAWNED, child->key, child->pid, 0, child->fd);
}

static HF int h_collect(struct context *c) {
    for (;;) {
        int status;
        long pid = R4(SYS_wait4, -1, &status, WNOHANG | __WALL, NULL);
        if (!pid) return 0;
        if (pid < 0) {
            if (pid == -EINTR) continue;
            if (pid == -ECHILD) return 1;
            h_exit(96);
        }
        ++c->collected;
        for (unsigned i = 0; i < c->count; ++i) {
            if (c->children[i].pid != pid) continue;
            struct child *child = &c->children[i];
            h_exec_ready(c, child);
            if (child->execfd >= 0) h_exit(123);
            if (child->failure) h_send(c, REFUSED, child->key, 0, child->failure, -1);
            else if (child->key) h_send(c, STATUS, child->key, (int)pid, status, -1);
            R1(SYS_close, c->children[i].fd);
            c->children[i] = c->children[--c->count];
            break;
        }
    }
}

static HF void h_signal_all(struct context *c) {
    h_refresh(c);
    for (unsigned i = 0; i < c->count; ++i) {
        long rc = R4(SYS_pidfd_send_signal, c->children[i].fd, SIGKILL, NULL, 0);
        if (rc < 0 && rc != -ESRCH) h_exit(97);
    }
}

static HF void h_advance(struct context *c) {
    if (c->closing) h_signal_all(c);
    else h_refresh(c);
    for (unsigned i = 0; i < c->count; ++i) h_exec_ready(c, &c->children[i]);
    int empty = h_collect(c);
    if (c->closing && empty) {
        if (c->count) h_exit(98);
        h_send(c, COMPLETE, 0, (int)c->collected, ECHILD, -1);
        h_exit(0); /* Closed admission, never another fork after this proof. */
    }
    if (c->closing) h_signal_all(c); /* Include newly adopted live children. */
}

static HENTRY void h_exec_fail(int error) {
    R3(SYS_write, 3, &error, sizeof error);
    h_exit(127);
}

static HF char *h_string(char *payload, unsigned size, unsigned *offset) {
    if (*offset >= size) h_exit(100);
    char *string = payload + *offset;
    while (*offset < size && payload[*offset]) ++*offset;
    if (*offset == size) h_exit(100);
    ++*offset;
    return string;
}

static HF void h_spawn(struct context *c, struct header h, char *payload, unsigned size, int *fds, int nfds) {
    if (c->closing) {
        h_send(c, REFUSED, h.key, 0, ESHUTDOWN, -1);
        return;
    }
    char *argv[4097], *env[4097];
    unsigned offset = 0, argc = 0, envc = 0;
    if (h.key < 1 || h.arg < 1 || h.arg > 4096 || nfds != 3) h_exit(99);
    for (unsigned i=0; i<c->count; ++i) if (c->children[i].key == h.key) h_exit(124);
    char *file = h_string(payload, size, &offset);
    char *cwd = h_string(payload, size, &offset);
    while (offset < size) {
        char *string = h_string(payload, size, &offset);
        if (argc < (unsigned)h.arg) argv[argc++] = string;
        else {
            if (argc + envc == 4096) h_exit(101);
            env[envc++] = string;
        }
    }
    if (argc != (unsigned)h.arg) h_exit(102);
    argv[argc] = NULL; env[envc] = NULL;
    int execution[2];
    long rc = R2(SYS_pipe2, execution, O_CLOEXEC | O_NONBLOCK);
    if (rc < 0) { h_send(c, REFUSED, h.key, 0, (int)-rc, -1); return; }
    int pidfd = -1;
    long pid = R5(SYS_clone, SIGCHLD | CLONE_PIDFD, NULL, &pidfd, NULL, 0);
    if (pid < 0) {
        R1(SYS_close, execution[0]); R1(SYS_close, execution[1]);
        h_send(c, REFUSED, h.key, 0, (int)-pid, -1);
        return;
    }
    if (!pid) {
        for (int i=0; i<3; ++i) if ((rc=R2(SYS_dup2, fds[i], i)) < 0) {
            int failure=(int)-rc;
            R3(SYS_write, execution[1], &failure, sizeof failure); h_exit(127);
        }
        if (R3(SYS_dup3, execution[1], 3, O_CLOEXEC) < 0) h_exit(104);
        if ((rc=R3(SYS_close_range, 4, UINT_MAX, 0)) < 0) h_exec_fail((int)-rc);
        uint64_t empty = 0;
        if ((rc=R4(SYS_rt_sigprocmask, SIG_SETMASK, &empty, NULL, sizeof empty)) < 0) h_exec_fail((int)-rc);
        if ((rc=R1(SYS_chdir, cwd)) < 0) h_exec_fail((int)-rc);
        rc = R3(SYS_execve, file, argv, env);
        h_exec_fail((int)-rc);
    }
    R1(SYS_close, execution[1]);
    h_add(c, (int)pid, pidfd, h.key);
    c->children[c->count-1].execfd = execution[0];
}

static HF void h_receive(struct context *c) {
    char ancillary[CMSG_SPACE(8 * sizeof(int))];
    struct iovec io = {c->packet.bytes, sizeof c->packet.bytes};
    struct msghdr msg = {.msg_iov = &io, .msg_iovlen = 1,
        .msg_control = ancillary, .msg_controllen = sizeof ancillary};
    long size = R3(SYS_recvmsg, c->control, &msg, MSG_CMSG_CLOEXEC);
    if (size == -EINTR) return;
    if (size < (long)sizeof(struct header) || msg.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) h_exit(106);
    int fds[8], nfds = 0;
    for (struct cmsghdr *header = CMSG_FIRSTHDR(&msg); header; header = CMSG_NXTHDR(&msg, header)) {
        if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS) continue;
        unsigned n = (unsigned)((header->cmsg_len - CMSG_LEN(0)) / sizeof(int));
        if (nfds + n > 8) h_exit(107);
        h_copy(fds + nfds, CMSG_DATA(header), n * sizeof(int));
        nfds += (int)n;
    }
    struct header h;
    h_copy(&h, c->packet.bytes, sizeof h);
    if (h.op == SPAWN) h_spawn(c, h, c->packet.bytes + sizeof h, (unsigned)(size - sizeof h), fds, nfds);
    else if (h.op == STOP) c->closing = 1;
    else if (h.op == RELEASE) c->held = 0;
    else if (h.op == CANCEL && nfds == 0) {
        for (unsigned i=0; i<c->count; ++i) if (c->children[i].key == h.key) {
            long rc=R4(SYS_pidfd_send_signal,c->children[i].fd,SIGKILL,NULL,0);
            if (rc < 0 && rc != -ESRCH) h_exit(125);
        }
    }
    else if (h.op == ADOPT && nfds == 1) {
        h_refresh(c);
        int pid = h_pidfd_pid(fds[0]);
        struct child *child = h_find(c, pid);
        if (child && h_pidfd_pid(child->fd) == pid) h_send(c, ADOPTED, h.key, pid, 0, child->fd);
        else h_send(c, REFUSED, h.key, pid, EXDEV, -1);
    } else h_exit(108);
    for (int i = 0; i < nfds; ++i) R1(SYS_close, fds[i]);
}

struct kernel_sigaction { unsigned long handler, flags, restorer; uint64_t mask; };

static HENTRY void h_start(struct context *c) {
    /* Every signal is blocked across the raw host clone. Isolate this session,
       discard inherited pending catchable signals, then establish defaults. */
    if (R0(SYS_setsid) < 0) h_exit(109);
    struct kernel_sigaction action = {.handler = (unsigned long)SIG_IGN};
    for (int sig = 1; sig <= 64; ++sig)
        if (sig != SIGKILL && sig != SIGSTOP && R4(SYS_rt_sigaction, sig, &action, NULL, 8) < 0) h_exit(110);
    action.handler = (unsigned long)SIG_DFL;
    for (int sig = 1; sig <= 64; ++sig)
        if (sig != SIGKILL && sig != SIGSTOP && R4(SYS_rt_sigaction, sig, &action, NULL, 8) < 0) h_exit(111);
    if (c->control != 3 && R3(SYS_dup3, c->control, 3, O_CLOEXEC) < 0) h_exit(112);
    c->control = 3;
    if (R3(SYS_fcntl, 3, F_SETFD, FD_CLOEXEC) < 0) h_exit(113);
    if (R3(SYS_close_range, 4, UINT_MAX, 0)) h_exit(114);
    for (int fd = 0; fd < 3; ++fd) R1(SYS_close, fd);
    long null = R4(SYS_openat, AT_FDCWD, "/dev/null", O_RDWR | O_CLOEXEC, 0);
    if (null != 0 || R2(SYS_dup2, 0, 1) < 0 || R2(SYS_dup2, 0, 2) < 0) h_exit(115);
    char self[80];
    long size = R3(SYS_readlink, "/proc/self", self, sizeof self);
    if (size < 1 || h_parse(self, (unsigned)size) != R0(SYS_getpid)) h_exit(116);
    if (R5(SYS_prctl, PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0)) h_exit(117);
    uint64_t mask = 1ULL << (SIGCHLD - 1);
    if (R4(SYS_rt_sigprocmask, SIG_SETMASK, &mask, NULL, sizeof mask)) h_exit(118);
    long fd = R4(SYS_signalfd4, -1, &mask, sizeof mask, SFD_CLOEXEC | SFD_NONBLOCK);
    if (fd < 0) h_exit(119);
    c->signal_fd = (int)fd;
    h_send(c, READY, 0, (int)R0(SYS_getpid), 0, -1);
    for (;;) {
        struct pollfd events[4098];
        events[0]=(struct pollfd){c->control,POLLIN,0};
        events[1]=(struct pollfd){c->signal_fd,POLLIN,0};
        unsigned n=2;
        for (unsigned i=0; i<c->count; ++i) if (c->children[i].execfd >= 0)
            events[n++] = (struct pollfd){c->children[i].execfd, POLLIN, 0};
        long rc = R3(SYS_poll, events, n, -1);
        if (rc == -EINTR) continue;
        if (rc < 0) h_exit(120);
        if (events[0].revents) h_receive(c);
        if (!c->held && events[1].revents) {
            struct signalfd_siginfo info;
            do { rc = R3(SYS_read, c->signal_fd, &info, sizeof info); } while (rc == sizeof info);
            if (rc != -EAGAIN) h_exit(121);
        }
        if (!c->held) h_advance(c);
    }
}

static __attribute__((noinline, no_stack_protector)) long h_clone(int *pidfd) {
    return R5(SYS_clone, SIGCHLD | CLONE_PIDFD, NULL, pidfd, NULL, 0);
}
#pragma GCC pop_options

/* Host side: libc is permitted here. No child is returned as a refusal after
   birth. The surrounding host owner journals intent before calling this. */
#endif

__attribute__((no_stack_protector)) int libtmux_guardian_start(int *result) {
#if defined(GUARDIAN_UNSUPPORTED)
    (void)result;
    return ENOTSUP;
#else
    for (int i = 0; i < 3; ++i) result[i] = -1;
    struct sigaction policy;
    if (sigaction(SIGCHLD, NULL, &policy)) return errno;
    if (policy.sa_handler == SIG_IGN || policy.sa_flags & SA_NOCLDWAIT) return ENOTSUP;
    struct context *c = calloc(1, sizeof *c);
    if (!c) return ENOMEM;
    int channels[2] = {-1, -1};
    int error = 0;
    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, channels)) {
        error = errno;
        goto refused;
    }
    for (int i = 0; i < 2; ++i) {
        if (channels[i] >= 3) continue;
        int moved = fcntl(channels[i], F_DUPFD_CLOEXEC, 3);
        if (moved < 0) { error = errno; goto refused; }
        close(channels[i]);
        channels[i] = moved;
    }
    c->control = channels[1];
    uint64_t all = UINT64_MAX, previous;
    long rc = R4(SYS_rt_sigprocmask, SIG_SETMASK, &all, &previous, sizeof all);
    if (rc < 0) { error = (int)-rc; goto refused; }
    int pidfd = -1;
    long pid = h_clone(&pidfd);
    if (!pid) h_start(c);
    /* Restoring a mask cannot fail with the same valid local memory/ABI. */
    rc = R4(SYS_rt_sigprocmask, SIG_SETMASK, &previous, NULL, sizeof previous);
    if (pid < 0) { error = (int)-pid; goto refused; }
    (void)rc;
    result[0] = channels[0];
    result[1] = pidfd;
    result[2] = (int)pid;
    close(channels[1]);
    free(c); /* Child has a private COW address space, including this context. */
    return 0;
refused:
    for (int i = 0; i < 2; ++i) if (channels[i] >= 0) close(channels[i]);
    free(c);
    return error;
#endif
}
