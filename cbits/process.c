#define _GNU_SOURCE
#include "process.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <poll.h>
#include <spawn.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <sys/inotify.h>
#include <unistd.h>

typedef int (*spawn_call)(int *, const char *, const posix_spawn_file_actions_t *,
                          const posix_spawnattr_t *, char *const[], char *const[]);
typedef int (*chdir_call)(posix_spawn_file_actions_t *, const char *);
typedef int (*closefrom_call)(posix_spawn_file_actions_t *, int);

struct operations {
    spawn_call spawn;
    chdir_call chdir;
    closefrom_call closefrom;
};

/* Resolve optional libc operations without introducing versioned references. */
static struct operations operations(void) {
    struct operations value = {0};
    void *symbol = dlsym(RTLD_DEFAULT, "pidfd_spawn");
    _Static_assert(sizeof(value.spawn) == sizeof(symbol), "function pointer ABI");
    memcpy(&value.spawn, &symbol, sizeof(symbol));
    symbol = dlsym(RTLD_DEFAULT, "posix_spawn_file_actions_addchdir_np");
    memcpy(&value.chdir, &symbol, sizeof(symbol));
    symbol = dlsym(RTLD_DEFAULT, "posix_spawn_file_actions_addclosefrom_np");
    memcpy(&value.closefrom, &symbol, sizeof(symbol));
    return value;
}

int libtmux_process_features(void) {
    struct operations value = operations();
    return (value.spawn ? 1 : 0) | (value.chdir ? 2 : 0) | (value.closefrom ? 4 : 0);
}

static void close_pipes(int *fds) {
    for (int i = 0; i < 6; ++i) if (fds[i] >= 0) close(fds[i]);
}

static int private_pipe(int *fds) {
    if (pipe2(fds, O_CLOEXEC) < 0) return errno;
    for (int i = 0; i < 2; ++i) {
        if (fds[i] >= 3) continue;
        int moved = fcntl(fds[i], F_DUPFD_CLOEXEC, 3);
        if (moved < 0) return errno;
        close(fds[i]);
        fds[i] = moved;
    }
    return 0;
}

static int private_input(int *fds) {
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, fds) < 0) return errno;
    for (int i = 0; i < 2; ++i) {
        if (fds[i] >= 3) continue;
        int moved = fcntl(fds[i], F_DUPFD_CLOEXEC, 3);
        if (moved < 0) return errno;
        close(fds[i]);
        fds[i] = moved;
    }
    if (shutdown(fds[0], SHUT_WR) < 0 || shutdown(fds[1], SHUT_RD) < 0) return errno;
    return 0;
}

/* result: pidfd, stdin writer, stdout reader, stderr reader, failure stage. */
static int process_spawn(const char *file, char *const argv[],
                         char *const env[], const char *cwd, int *result,
                         int discard_stdout) {
    for (int i = 0; i < 4; ++i) result[i] = -1;
    result[4] = 1;
    struct operations calls = operations();
    if (!calls.spawn || !calls.chdir || !calls.closefrom) return ENOSYS;
    struct sigaction child_policy;
    result[4] = 2;
    if (sigaction(SIGCHLD, NULL, &child_policy) < 0) return errno;
    if (child_policy.sa_handler == SIG_IGN || (child_policy.sa_flags & SA_NOCLDWAIT))
        return ENOTSUP;
    int pipes[6] = {-1, -1, -1, -1, -1, -1};
    int rc = 0;
    result[4] = 3;
    rc = private_input(pipes);
    if (rc) goto no_child;
    for (int i = 2; i < 6; i += 2) {
        rc = private_pipe(pipes + i);
        if (rc) goto no_child;
    }
    const int parent_ends[] = {1, 2, 4};
    for (int i = 0; i < 3; ++i) {
        int fd = pipes[parent_ends[i]];
        int flags = fcntl(fd, F_GETFL);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            rc = errno;
            goto no_child;
        }
    }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    result[4] = 4;
    if ((rc = posix_spawn_file_actions_init(&actions))) goto no_child;
    if ((rc = posix_spawnattr_init(&attributes))) goto destroy_actions;
    if ((rc = calls.chdir(&actions, cwd))) goto destroy_both;
    if ((rc = posix_spawn_file_actions_adddup2(&actions, pipes[0], 0))) goto destroy_both;
    if (discard_stdout)
        rc = posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    else
        rc = posix_spawn_file_actions_adddup2(&actions, pipes[3], 1);
    if (rc) goto destroy_both;
    if ((rc = posix_spawn_file_actions_adddup2(&actions, pipes[5], 2))) goto destroy_both;
    if ((rc = calls.closefrom(&actions, 3))) goto destroy_both;
    result[4] = 5;
    sigset_t mask, defaults;
    sigemptyset(&mask);
    sigemptyset(&defaults);
    const int reset[] = {SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD};
    for (size_t i = 0; i < sizeof(reset) / sizeof(reset[0]); ++i)
        sigaddset(&defaults, reset[i]);
    if ((rc = posix_spawnattr_setsigmask(&attributes, &mask))) goto destroy_both;
    if ((rc = posix_spawnattr_setsigdefault(&attributes, &defaults))) goto destroy_both;
    if ((rc = posix_spawnattr_setflags(&attributes,
            POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))) goto destroy_both;
    int pidfd = -1;
    result[4] = 6;
    rc = calls.spawn(&pidfd, file, &actions, &attributes, argv, env);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    if (rc) goto no_child;
    result[0] = pidfd;
    result[1] = pipes[1];
    result[2] = pipes[2];
    result[3] = pipes[4];
    result[4] = 0;
    close(pipes[0]); close(pipes[3]); close(pipes[5]);
    return 0;
destroy_both:
    posix_spawnattr_destroy(&attributes);
destroy_actions:
    posix_spawn_file_actions_destroy(&actions);
no_child:
    close_pipes(pipes);
    return rc;
}

int libtmux_process_spawn(const char *file, char *const argv[],
                          char *const env[], const char *cwd, int *result) {
    return process_spawn(file, argv, env, cwd, result, 0);
}

int libtmux_process_spawn_discard_stdout(const char *file, char *const argv[],
                                        char *const env[], const char *cwd, int *result) {
    return process_spawn(file, argv, env, cwd, result, 1);
}

int libtmux_process_read(int fd, void *buffer, size_t size) {
    ssize_t count = read(fd, buffer, size);
    return count < 0 ? -errno : (int)count;
}

int libtmux_process_write(int fd, const void *buffer, size_t size) {
    ssize_t count = send(fd, buffer, size, MSG_NOSIGNAL);
    return count < 0 ? -errno : (int)count;
}

int libtmux_process_wait(int fd, int *result) {
    siginfo_t info = {0};
    int waited;
    /* Linux's P_PIDFD selector is 3, including libc headers predating the name. */
    do { waited = waitid((idtype_t)3, fd, &info, WEXITED | WNOHANG); }
    while (waited < 0 && errno == EINTR);
    if (waited < 0) return -errno;
    if (!info.si_pid) return 0;
    result[0] = info.si_code == CLD_EXITED ? 1 : info.si_code == CLD_KILLED ? 2 : 3;
    result[1] = info.si_status;
    return 1;
}

int libtmux_process_signal(int fd, int value) {
    return syscall(SYS_pidfd_send_signal, fd, value, NULL, 0) < 0 ? errno : 0;
}

int libtmux_process_group_probe(void) {
    int fd = syscall(SYS_pidfd_open, getpid(), 0);
    if (fd < 0) return errno;
    /* Linux 6.9 flag 4; signal zero has no effect. A nonleader has no PGID. */
    int rc = syscall(SYS_pidfd_send_signal, fd, 0, NULL, 4) < 0 ? errno : 0;
    close(fd);
    return rc == ESRCH ? 0 : rc;
}

int libtmux_process_group_open(int pid) {
    int fd = syscall(SYS_pidfd_open, pid, 0);
    if (fd < 0) return -errno;
    if (getpgid(pid) != pid || getsid(pid) != pid) {
        close(fd);
        return -EINVAL;
    }
    return fd;
}

int libtmux_process_group_signal(int fd, int value) {
    return syscall(SYS_pidfd_send_signal, fd, value, NULL, 4) < 0 ? errno : 0;
}

int libtmux_process_pidfd_open(int pid) {
    int fd = syscall(SYS_pidfd_open, pid, 0);
    return fd < 0 ? -errno : fd;
}

int libtmux_process_pidfd_ready(int fd) {
    struct pollfd value = {.fd = fd, .events = POLLIN};
    int rc = poll(&value, 1, 0);
    if (rc < 0) return -errno;
    if (value.revents & (POLLERR | POLLNVAL)) return -EBADF;
    return !!(value.revents & POLLIN);
}

int libtmux_program_watch(const char *directory) {
    int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (fd < 0) return -errno;
    if (inotify_add_watch(fd, directory, IN_CLOSE_WRITE | IN_DELETE_SELF) < 0) {
        int error = errno;
        close(fd);
        return -error;
    }
    return fd;
}

int libtmux_program_watch_read(int fd) {
    char bytes[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
    ssize_t size = read(fd, bytes, sizeof bytes);
    if (size < 0) return errno == EAGAIN ? 0 : -errno;
    for (char *next = bytes; next < bytes + size;) {
        struct inotify_event *event = (struct inotify_event *)next;
        if (event->mask & (IN_Q_OVERFLOW | IN_DELETE_SELF | IN_IGNORED)) return -EIO;
        if (event->mask & IN_CLOSE_WRITE) return 1;
        next += sizeof *event + event->len;
    }
    return 0;
}

static int program_peer(const char *path, int expected_pid) {
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    struct ucred peer;
    socklen_t size = sizeof peer;
    if (strlen(path) >= sizeof address.sun_path) return -ENAMETOOLONG;
    strcpy(address.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) return -errno;
    int rc = connect(fd, (struct sockaddr *)&address, sizeof address);
    if (rc == 0) rc = getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &size);
    int error = rc < 0 ? errno : peer.pid != expected_pid || peer.uid != geteuid() ? EPERM : 0;
    close(fd);
    return -error;
}

int libtmux_program_daemon_watch(const char *path, int expected_pid) {
    int rc = program_peer(path, expected_pid);
    if (rc < 0) return rc;
    int fd = syscall(SYS_pidfd_open, expected_pid, 0);
    if (fd < 0) return -errno;
    /* A new connection authenticates the still-live endpoint after acquisition. */
    rc = program_peer(path, expected_pid);
    if (rc == 0 && syscall(SYS_pidfd_send_signal, fd, 0, NULL, 0) < 0) rc = -errno;
    if (rc < 0) { close(fd); return rc; }
    return fd;
}
