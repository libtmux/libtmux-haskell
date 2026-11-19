#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/file.h>
#include <sys/inotify.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#ifndef SO_PEERPIDFD
#define SO_PEERPIDFD 77
#endif

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

/* tmux -D chmods its socket after listen. Arm before submitting the child. */
int libtmux_process_watch_start(const char *directory) {
    int fd = inotify_init1(IN_CLOEXEC | IN_NONBLOCK);
    if (fd < 0) return -errno;
    if (inotify_add_watch(fd, directory, IN_ATTRIB | IN_CREATE | IN_MOVED_TO | IN_DELETE_SELF) < 0) {
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
