#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stddef.h>
#include <string.h>
#include <sys/file.h>
#include <sys/inotify.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <unistd.h>

int libtmux_fixture_pidfd(int pid)
{
    return syscall(SYS_pidfd_open, pid, 0);
}

/* Hold an exclusive flock on a file as a starting tmux daemon does before it
 * listens; closing the returned descriptor releases it. */
int libtmux_fixture_lock(const char *path)
{
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd == -1)
        return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) == -1) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

int libtmux_fixture_watch(const char *directory)
{
    int fd = inotify_init1(IN_CLOEXEC | IN_NONBLOCK);
    if (fd == -1)
        return -1;
    if (inotify_add_watch(fd, directory, IN_ATTRIB | IN_DELETE_SELF) == -1) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

int libtmux_fixture_socket_ready(int fd)
{
    _Alignas(struct inotify_event) char buffer[4096];
    ssize_t count = read(fd, buffer, sizeof buffer);
    if (count == -1)
        return -1;
    for (size_t offset = 0; offset < (size_t)count;) {
        if ((size_t)count - offset < sizeof(struct inotify_event)) {
            errno = EPROTO;
            return -1;
        }
        const struct inotify_event *event =
            (const struct inotify_event *)(buffer + offset);
        if (event->len > (size_t)count - offset - sizeof *event) {
            errno = EPROTO;
            return -1;
        }
        if (event->mask & (IN_IGNORED | IN_DELETE_SELF)) {
            errno = EPIPE;
            return -1;
        }
        if ((event->mask & IN_ATTRIB) && event->len >= sizeof "socket" &&
            memcmp(event->name, "socket", sizeof "socket") == 0)
            return 1;
        offset += sizeof *event + event->len;
    }
    return 0;
}

/* Watch a directory for new names. */
int libtmux_fixture_watch_create(const char *directory)
{
    int fd = inotify_init1(IN_CLOEXEC | IN_NONBLOCK);
    if (fd == -1)
        return -1;
    if (inotify_add_watch(fd, directory, IN_CREATE) == -1) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

/* One when a drained event created `name`, zero when none did, -1 on failure. */
int libtmux_fixture_created(int fd, const char *name)
{
    _Alignas(struct inotify_event) char buffer[4096];
    ssize_t count = read(fd, buffer, sizeof buffer);
    if (count == -1)
        return errno == EAGAIN ? 0 : -1;
    for (size_t offset = 0; offset < (size_t)count;) {
        if ((size_t)count - offset < sizeof(struct inotify_event)) {
            errno = EPROTO;
            return -1;
        }
        const struct inotify_event *event =
            (const struct inotify_event *)(buffer + offset);
        if (event->len > (size_t)count - offset - sizeof *event) {
            errno = EPROTO;
            return -1;
        }
        if ((event->mask & IN_CREATE) && event->len > 0 &&
            strncmp(event->name, name, event->len) == 0)
            return 1;
        offset += sizeof *event + event->len;
    }
    return 0;
}

static int unix_address(struct sockaddr_un *address, const char *path)
{
    size_t length = strlen(path);
    if (length >= sizeof address->sun_path) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memset(address, 0, sizeof *address);
    address->sun_family = AF_UNIX;
    memcpy(address->sun_path, path, length + 1);
    return 0;
}

/* A listening stream socket that never accepts, or -1. */
int libtmux_fixture_listen(const char *path, int backlog)
{
    struct sockaddr_un address;
    if (unix_address(&address, path) == -1)
        return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd == -1)
        return -1;
    if (bind(fd, (const struct sockaddr *)&address, sizeof address) == -1 ||
        listen(fd, backlog) == -1) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

/* Queue unaccepted nonblocking connections on a listener until its backlog
 * is full (the next connect is EAGAIN). Returns how many descriptors were stored,
 * or -1. The caller closes them; a listener that closes resets every one. */
int libtmux_fixture_saturate(const char *path, int *fds, int capacity)
{
    struct sockaddr_un address;
    if (unix_address(&address, path) == -1)
        return -1;
    int held = 0;
    while (held < capacity) {
        int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        if (fd == -1)
            return -1;
        if (connect(fd, (const struct sockaddr *)&address, sizeof address) == -1) {
            int saved = errno;
            close(fd);
            if (saved == EAGAIN)
                return held;
            errno = saved;
            return -1;
        }
        fds[held++] = fd;
    }
    errno = ENOBUFS;
    return -1;
}

/* One when the descriptor reports hangup or error, zero otherwise: the listener
 * that held this connection unaccepted has closed. */
int libtmux_fixture_hung(int fd)
{
    struct pollfd entry = {.fd = fd, .events = POLLIN, .revents = 0};
    int rc = poll(&entry, 1, 0);
    if (rc == -1)
        return -1;
    return rc > 0 && (entry.revents & (POLLHUP | POLLERR)) != 0;
}
