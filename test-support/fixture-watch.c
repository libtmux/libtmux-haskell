#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

int libtmux_fixture_pidfd(int pid)
{
    return syscall(SYS_pidfd_open, pid, 0);
}

typedef int (*pidfd_spawn_call)(int *, const char *, const posix_spawn_file_actions_t *,
                                const posix_spawnattr_t *, char *const[], char *const[]);

/* How a child's standard stream is connected: /dev/null opened read-write, as typed-process's
 * null stream was; the parent's own descriptor; or a pipe whose other end the parent keeps. */
enum { FIXTURE_NULL = 0, FIXTURE_INHERIT = 1, FIXTURE_PIPE = 2 };

/* A close-on-exec pipe whose ends are both above stderr, so a child's dup2 onto a standard
 * descriptor never names the descriptor it copies. Zero, or errno with nothing left open. */
static int pipe_pair(int pair[2])
{
    if (pipe2(pair, O_CLOEXEC) == -1)
        return errno;
    for (int i = 0; i < 2; ++i) {
        if (pair[i] > 2)
            continue;
        int moved = fcntl(pair[i], F_DUPFD_CLOEXEC, 3);
        if (moved == -1) {
            int saved = errno;
            close(pair[0]);
            close(pair[1]);
            return saved;
        }
        close(pair[i]);
        pair[i] = moved;
    }
    return 0;
}

static int nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL);
    return flags == -1 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) == -1 ? errno : 0;
}

static void close_all(const int *fds, int count)
{
    for (int i = 0; i < count; ++i)
        if (fds[i] >= 0)
            close(fds[i]);
}

static int launch(pidfd_spawn_call spawn, const char *file, char *const argv[], char *const envp[],
                  const int modes[3], const int child[3], int *fd)
{
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
    for (int i = 0; i < 3 && !rc; ++i) {
        if (modes[i] == FIXTURE_NULL)
            rc = posix_spawn_file_actions_addopen(&actions, i, "/dev/null", O_RDWR, 0);
        else if (modes[i] == FIXTURE_PIPE)
            rc = posix_spawn_file_actions_adddup2(&actions, child[i], i);
    }
    if (!rc && !(rc = posix_spawnattr_setsigmask(&attributes, &mask)) &&
        !(rc = posix_spawnattr_setsigdefault(&attributes, &defaults)) &&
        !(rc = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        rc = spawn(fd, file, &actions, &attributes, argv, envp);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    return rc;
}

/* Start `file` (searched on PATH) with the standard streams connected as `modes` (stdin, stdout,
 * stderr) says. result[0] is the pidfd; result[1..3] are the parent's ends of the streams that are
 * pipes (stdin's writable, the others readable; non-blocking and close-on-exec), otherwise -1. The
 * kernel creates the pidfd together with the child, so it can never name another process, whatever
 * the child does next. Zero on success, otherwise an errno value, with no child and no descriptor
 * left.
 *
 * Resolves glibc 2.39's pidfd_spawnp at run time, as the library's own launcher does,
 * and refuses a SIGCHLD policy that reaps children without a status. */
int libtmux_fixture_spawn(const char *file, char *const argv[], char *const envp[],
                          const int modes[3], int result[4])
{
    for (int i = 0; i < 4; ++i)
        result[i] = -1;
    for (int i = 0; i < 3; ++i)
        if (modes[i] != FIXTURE_NULL && modes[i] != FIXTURE_INHERIT && modes[i] != FIXTURE_PIPE)
            return EINVAL;
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
    int child[3] = {-1, -1, -1}, parent[3] = {-1, -1, -1}, rc = 0;
    for (int i = 0; i < 3 && !rc; ++i) {
        int pair[2];
        if (modes[i] != FIXTURE_PIPE || (rc = pipe_pair(pair)))
            continue;
        child[i] = pair[i == 0 ? 0 : 1];
        parent[i] = pair[i == 0 ? 1 : 0];
        rc = nonblocking(parent[i]);
    }
    int fd = -1;
    if (!rc)
        rc = launch(spawn, file, argv, envp, modes, child, &fd);
    close_all(child, 3);
    if (rc) {
        close_all(parent, 3);
        return rc;
    }
    result[0] = fd;
    for (int i = 0; i < 3; ++i)
        result[i + 1] = parent[i];
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

/* Bytes read from a non-blocking descriptor, zero at end of stream, otherwise -errno; EAGAIN means
 * nothing is ready. */
int libtmux_fixture_read(int fd, void *buffer, size_t size)
{
    ssize_t count;
    do
        count = read(fd, buffer, size);
    while (count == -1 && errno == EINTR);
    return count == -1 ? -errno : (int)count;
}

/* Bytes written to a non-blocking descriptor, otherwise -errno; EAGAIN means the pipe is full. */
int libtmux_fixture_write(int fd, const void *buffer, size_t size)
{
    ssize_t count;
    do
        count = write(fd, buffer, size);
    while (count == -1 && errno == EINTR);
    return count == -1 ? -errno : (int)count;
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
