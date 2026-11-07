#define _GNU_SOURCE
#include <errno.h>
#include <stddef.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/syscall.h>
#include <unistd.h>

int libtmux_fixture_pidfd(int pid)
{
    return syscall(SYS_pidfd_open, pid, 0);
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
