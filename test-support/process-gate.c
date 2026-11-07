#define _GNU_SOURCE
#include "process.h"
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <stdatomic.h>
#include <sys/socket.h>

int libtmux_test_control_pipe(int *fds) {
    if (pipe2(fds, O_CLOEXEC | O_NONBLOCK) < 0) return errno;
    int flags = fcntl(fds[0], F_GETFL);
    if (fcntl(fds[0], F_SETFL, flags & ~O_NONBLOCK) < 0) {
        int rc = errno;
        close(fds[0]); close(fds[1]);
        return rc;
    }
    return 0;
}

static void hold(int fd, int notice) {
    char byte = 1;
    while (write(notice, &byte, 1) < 0 && errno == EINTR) {}
    while (read(fd, &byte, 1) < 0 && errno == EINTR) {}
}

void libtmux_test_constructor_gate(int fd, int notice) { hold(fd, notice); }

int libtmux_test_spawn_gate(int point, int fd, int notice, const char *file,
    char *const argv[], char *const env[], const char *cwd, int *result) {
    if (point == 1) hold(fd, notice);
    int rc = libtmux_process_spawn(file, argv, env, cwd, result);
    if (point == 2) hold(fd, notice);
    return rc;
}

int libtmux_test_wait_gate(int fd, int notice, int pidfd, int *result) {
    int rc = libtmux_process_wait(pidfd, result);
    if (rc > 0) hold(fd, notice);
    return rc;
}

/* Test-only provenance observation; the production writer remains unchanged. */
static _Atomic uintptr_t watched_begin, watched_end;
static _Atomic unsigned shared_writes;
static _Atomic int watched_writer = -1, writer_notice = -1;
static _Atomic unsigned blocked_writes;
int libtmux_test_watch_writer(int fd, int notice) {
    int size = 4096;
    if (fd >= 0 && setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) < 0) return errno;
    atomic_store(&blocked_writes, 0);
    atomic_store(&writer_notice, notice);
    atomic_store(&watched_writer, fd);
    return 0;
}
unsigned libtmux_test_blocked_writes(void) { return atomic_load(&blocked_writes); }
int libtmux_test_high_descriptor(void) {
    int fd = open("/dev/null", O_RDONLY);
    if (fd < 0) return -errno;
    int high = fcntl(fd, F_DUPFD, 512), rc = errno;
    close(fd);
    return high < 0 ? -rc : high;
}
void libtmux_test_watch_input(void *pointer, size_t size) {
    atomic_store(&shared_writes, 0);
    atomic_store(&watched_begin, (uintptr_t)pointer);
    atomic_store(&watched_end, (uintptr_t)pointer + size);
}
unsigned libtmux_test_shared_writes(void) { return atomic_load(&shared_writes); }
int __real_libtmux_process_write(int, const void *, size_t);
int __wrap_libtmux_process_write(int fd, const void *buffer, size_t size) {
    uintptr_t address = (uintptr_t)buffer;
    if (address >= atomic_load(&watched_begin) && address < atomic_load(&watched_end))
        atomic_fetch_add(&shared_writes, 1);
    int rc = __real_libtmux_process_write(fd, buffer, size);
    if (fd == atomic_load(&watched_writer) && rc == -EAGAIN) {
        unsigned previous = atomic_fetch_add(&blocked_writes, 1);
        if (!previous) {
            char byte = 1;
            int notice = atomic_load(&writer_notice);
            while (write(notice, &byte, 1) < 0 && errno == EINTR) {}
        }
    }
    return rc;
}

/* A hostile host has consumed the status; the second wait must report ECHILD. */
int libtmux_test_stolen_wait(int fd, int *result) {
    int first = libtmux_process_wait(fd, result);
    return first > 0 ? libtmux_process_wait(fd, result) : first;
}
