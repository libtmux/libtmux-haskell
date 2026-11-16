#define _GNU_SOURCE
#include "process.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>
#include <sys/file.h>
#include <sys/inotify.h>
#include <time.h>
#include <sys/syscall.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

/* Linux 6.5 added SO_PEERPIDFD; headers predating the name keep the ABI value. */
#ifndef SO_PEERPIDFD
#define SO_PEERPIDFD 77
#endif

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
int libtmux_process_spawn(const char *file, char *const argv[],
                          char *const env[], const char *cwd, int *result) {
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
    if ((rc = posix_spawn_file_actions_adddup2(&actions, pipes[3], 1))) goto destroy_both;
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

/* Feature bits: 1=SO_PEERPIDFD, 2=pidfd_send_signal, 4=fdinfo.
 * Probe without creating a daemon. */
int libtmux_process_daemon_features(void) {
    int bits = 0;
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair) == 0) {
        int pidfd = -1;
        socklen_t size = sizeof pidfd;
        if (getsockopt(pair[0], SOL_SOCKET, SO_PEERPIDFD, &pidfd, &size) == 0 && pidfd >= 0) {
            bits |= 1;
            close(pidfd);
        }
        close(pair[0]);
        close(pair[1]);
    }
    errno = 0;
    syscall(SYS_pidfd_send_signal, -1, 0, NULL, 0);
    if (errno == EBADF) bits |= 2;
    if (access("/proc/self/fdinfo", R_OK | X_OK) == 0) bits |= 4;
    return bits;
}

/* The listener's kernel identity avoids numeric PID signaling.
 * Nonblocking connect returns -EAGAIN for a full backlog. */
int libtmux_process_peer_pidfd(const char *path) {
    struct sockaddr_un address;
    size_t length = strlen(path);
    if (length >= sizeof address.sun_path) return -ENAMETOOLONG;
    memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, path, length + 1);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) return -errno;
    int pidfd = -1;
    socklen_t size = sizeof pidfd;
    int saved = 0;
    int rc;
    do { rc = connect(fd, (const struct sockaddr *)&address, sizeof address); }
    while (rc < 0 && errno == EINTR);
    if (rc < 0 || getsockopt(fd, SOL_SOCKET, SO_PEERPIDFD, &pidfd, &size) < 0)
        saved = errno;
    close(fd);
    if (saved) return -saved;
    if (fcntl(pidfd, F_SETFD, FD_CLOEXEC) < 0) {
        saved = errno;
        close(pidfd);
        return -saved;
    }
    return pidfd;
}

/* /proc/self/fd/N retains the socket inode after its names disappear. */
int libtmux_process_anchor(const char *path) {
    int fd = open(path, O_PATH | O_NOFOLLOW | O_CLOEXEC);
    return fd < 0 ? -errno : fd;
}

/* Atomically mark the duplicate close-on-exec. */
int libtmux_process_dup(int fd) {
    int copy = fcntl(fd, F_DUPFD_CLOEXEC, 3);
    return copy < 0 ? -errno : copy;
}

/* Arm before probing the startup lock so listen's lock-file unlink is not lost. */
int libtmux_process_watch_removals(const char *directory) {
    int fd = inotify_init1(IN_CLOEXEC | IN_NONBLOCK);
    if (fd < 0) return -errno;
    if (inotify_add_watch(fd, directory, IN_DELETE | IN_MOVED_FROM) < 0) {
        int saved = errno;
        close(fd);
        return -saved;
    }
    return fd;
}

/* Discard queued watch events. Zero once drained, negative errno otherwise. */
int libtmux_process_watch_drain(int fd) {
    char buffer[4096] __attribute__((aligned(8)));
    for (;;) {
        ssize_t count = read(fd, buffer, sizeof buffer);
        if (count > 0) continue;
        if (count < 0 && errno == EINTR) continue;
        return (count < 0 && errno != EAGAIN) ? -errno : 0;
    }
}

/* One when another open file description holds the lock, zero when it is free or
 * the file is gone, negative errno otherwise. A shared try-lock taken and dropped
 * here conflicts only with a holder of the exclusive lock. */
int libtmux_process_lock_held(const char *path) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return errno == ENOENT ? 0 : -errno;
    int rc = flock(fd, LOCK_SH | LOCK_NB);
    int saved = errno;
    close(fd);
    if (rc == 0) return 0;
    return saved == EWOULDBLOCK ? 1 : -saved;
}

static long elapsed_ms(const struct timespec *from) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (now.tv_sec - from->tv_sec) * 1000L + (now.tv_nsec - from->tv_nsec) / 1000000L;
}

/* Only POLLIN/POLLHUP prove pidfd exit; invalid/error events return negative errno.
 * EINTR resumes against the original monotonic deadline. */
int libtmux_process_poll(int fd, int milliseconds) {
    struct pollfd entry = {.fd = fd, .events = POLLIN, .revents = 0};
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    int wait = milliseconds;
    for (;;) {
        int rc = poll(&entry, 1, wait);
        if (rc < 0) {
            if (errno != EINTR) return -errno;
            if (milliseconds >= 0) {
                long left = milliseconds - elapsed_ms(&start);
                if (left <= 0) return 0;
                wait = (int)left;
            }
            continue;
        }
        if (rc == 0) return 0;
        if (entry.revents & POLLNVAL) return -EBADF;
        if (entry.revents & POLLERR) return -EIO;
        return (entry.revents & (POLLIN | POLLHUP)) != 0;
    }
}
