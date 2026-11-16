#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>
#include <string.h>
#include <sys/file.h>
#include <sys/inotify.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

int libtmux_fixture_pidfd(int pid)
{
    return syscall(SYS_pidfd_open, pid, 0);
}

typedef int (*pidfd_spawn_call)(int *, const char *, const posix_spawn_file_actions_t *,
                                const posix_spawnattr_t *, char *const[], char *const[]);

/* Start `file` (searched on PATH) with stdin and stdout on /dev/null, each opened read-write
 * as typed-process's null stream was, and store its pidfd. The kernel creates the pidfd
 * together with the child, so it can never name another process, whatever the child does
 * next. Zero on success, otherwise an errno value, with no child and no descriptor left.
 *
 * Resolves glibc 2.39's pidfd_spawnp at run time, as the library's own launcher does,
 * and refuses a SIGCHLD policy that reaps children without a status. */
int libtmux_fixture_spawn(const char *file, char *const argv[], char *const envp[], int *pidfd)
{
    *pidfd = -1;
    void *symbol = dlsym(RTLD_DEFAULT, "pidfd_spawnp");
    pidfd_spawn_call spawn;
    memcpy(&spawn, &symbol, sizeof spawn);
    if (!spawn)
        return ENOSYS;
    struct sigaction policy;
    if (sigaction(SIGCHLD, NULL, &policy) == -1)
        return errno;
    if (policy.sa_handler == SIG_IGN || (policy.sa_flags & SA_NOCLDWAIT))
        return ENOTSUP;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int rc = posix_spawn_file_actions_init(&actions);
    if (rc)
        return rc;
    if ((rc = posix_spawnattr_init(&attributes))) {
        posix_spawn_file_actions_destroy(&actions);
        return rc;
    }
    sigset_t mask, defaults;
    sigemptyset(&mask);
    sigemptyset(&defaults);
    const int reset[] = {SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD};
    for (size_t i = 0; i < sizeof reset / sizeof reset[0]; ++i)
        sigaddset(&defaults, reset[i]);
    int fd = -1;
    if (!(rc = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDWR, 0)) &&
        !(rc = posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_RDWR, 0)) &&
        !(rc = posix_spawnattr_setsigmask(&attributes, &mask)) &&
        !(rc = posix_spawnattr_setsigdefault(&attributes, &defaults)) &&
        !(rc = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        rc = spawn(&fd, file, &actions, &attributes, argv, envp);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    if (rc)
        return rc;
    *pidfd = fd;
    return 0;
}

/* Zero when delivered, otherwise an errno value; ESRCH means the process is gone. */
int libtmux_fixture_pidfd_signal(int pidfd, int signal_number)
{
    return syscall(SYS_pidfd_send_signal, pidfd, signal_number, NULL, 0) == 0 ? 0 : errno;
}

/* Collect the child's status through its pidfd without blocking, and only that
 * child's. One with out = {1 exited | 2 killed | 3 dumped, status or signal}, zero
 * while it still runs, otherwise -errno. Linux's P_PIDFD selector is 3, including
 * libc headers predating the name. */
int libtmux_fixture_reap(int pidfd, int *out)
{
    siginfo_t info;
    memset(&info, 0, sizeof info);
    int rc;
    do
        rc = waitid((idtype_t)3, pidfd, &info, WEXITED | WNOHANG);
    while (rc == -1 && errno == EINTR);
    if (rc == -1)
        return -errno;
    if (info.si_pid == 0)
        return 0;
    out[0] = info.si_code == CLD_EXITED ? 1 : info.si_code == CLD_KILLED ? 2 : 3;
    out[1] = info.si_status;
    return 1;
}

static long long monotonic_ms(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

/* A private close-on-exec duplicate of `fd`, or -1. It shares the open file description, so it
 * stays valid and means the same process however the original is closed afterwards. */
int libtmux_fixture_dup(int fd)
{
    return fcntl(fd, F_DUPFD_CLOEXEC, 0);
}

/* One when the pidfd is readable (its process ended), zero when `milliseconds`
 * pass first, otherwise -errno; a descriptor that is not open is -EBADF, not readable.
 * A signal restarts the wait against the same deadline. */
int libtmux_fixture_pidfd_wait(int pidfd, int milliseconds)
{
    long long deadline = monotonic_ms() + milliseconds;
    for (;;) {
        struct pollfd entry = {.fd = pidfd, .events = POLLIN, .revents = 0};
        long long left = deadline - monotonic_ms();
        int rc = poll(&entry, 1, left > 0 ? (int)left : 0);
        if (rc > 0 && (entry.revents & POLLNVAL))
            return -EBADF;
        if (rc >= 0)
            return rc > 0;
        if (errno != EINTR)
            return -errno;
    }
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
