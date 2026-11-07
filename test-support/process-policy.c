#define _GNU_SOURCE
#include "process.h"
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

/* Each invocation is isolated from the Haskell runner's signal policies. */
static const char *missing;
static int kernel_refusal, spawn_calls;
static volatile sig_atomic_t delivered;
static int diagnostic_fd = 2;

static void fail(const char *message) {
    dprintf(diagnostic_fd, "%s (errno=%d)\n", message, errno);
    _exit(1);
}

static void require(int condition, const char *message) {
    if (!condition) fail(message);
}

static int refused_spawn(int *fd, const char *file,
    const posix_spawn_file_actions_t *actions, const posix_spawnattr_t *attributes,
    char *const argv[], char *const env[]) {
    (void)fd; (void)file; (void)actions; (void)attributes; (void)argv; (void)env;
    ++spawn_calls;
    return ENOSYS;
}

void *__real_dlsym(void *, const char *);
void *__wrap_dlsym(void *handle, const char *name) {
    if (missing && strcmp(name, missing) == 0) return NULL;
    if (kernel_refusal && strcmp(name, "pidfd_spawn") == 0) {
        int (*function)(int *, const char *, const posix_spawn_file_actions_t *,
            const posix_spawnattr_t *, char *const[], char *const[]) = refused_spawn;
        void *symbol;
        _Static_assert(sizeof(symbol) == sizeof(function), "function pointer ABI");
        memcpy(&symbol, &function, sizeof(symbol));
        return symbol;
    }
    return __real_dlsym(handle, name);
}

static int descriptor_count(void) {
    DIR *directory = opendir("/proc/self/fd");
    require(directory != NULL, "open descriptors");
    int count = 0;
    struct dirent *entry;
    while ((entry = readdir(directory)))
        if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..")) ++count;
    require(closedir(directory) == 0, "close descriptor listing");
    return count;
}

static int same_mask(const sigset_t *left, const sigset_t *right) {
    for (int signal = 1; signal < NSIG; ++signal)
        if (sigismember(left, signal) != sigismember(right, signal)) return 0;
    return 1;
}

static void refused(const char *mode) {
    int phase = 1, error = ENOSYS;
    if (!strcmp(mode, "no-spawn")) missing = "pidfd_spawn";
    else if (!strcmp(mode, "no-chdir")) missing = "posix_spawn_file_actions_addchdir_np";
    else if (!strcmp(mode, "no-closefrom")) missing = "posix_spawn_file_actions_addclosefrom_np";
    else if (!strcmp(mode, "kernel-refusal")) { kernel_refusal = 1; phase = 6; }
    else {
        struct sigaction policy = {0};
        sigemptyset(&policy.sa_mask);
        policy.sa_handler = !strcmp(mode, "ignored-child") ? SIG_IGN : SIG_DFL;
        policy.sa_flags = !strcmp(mode, "no-child-status") ? SA_NOCLDWAIT : 0;
        require(sigaction(SIGCHLD, &policy, NULL) == 0, "set child policy");
        phase = 2; error = ENOTSUP;
    }
    struct sigaction before, after;
    require(sigaction(SIGCHLD, NULL, &before) == 0, "read child policy");
    int count = descriptor_count(), result[5];
    char *argv[] = {"/bin/true", NULL}, *env[] = {"LANG=C.UTF-8", NULL};
    int rc = libtmux_process_spawn(argv[0], argv, env, "/", result);
    require(rc == error && result[4] == phase, "wrong launch refusal");
    for (int i = 0; i < 4; ++i) require(result[i] == -1, "refused launch owns descriptor");
    require(spawn_calls == kernel_refusal, "unexpected spawn dispatch");
    require(descriptor_count() == count, "refused launch leaked descriptor");
    int status;
    require(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD, "refused launch created child");
    require(sigaction(SIGCHLD, NULL, &after) == 0, "read final child policy");
    require(before.sa_handler == after.sa_handler && before.sa_flags == after.sa_flags
        && same_mask(&before.sa_mask, &after.sa_mask), "child policy changed");
}

static void handler(int signal) { (void)signal; ++delivered; }

static void broken_input(const char *mode) {
    struct sigaction policy = {0}, before, after;
    sigemptyset(&policy.sa_mask);
    policy.sa_handler = !strcmp(mode, "pipe-default") ? SIG_DFL :
        !strcmp(mode, "pipe-ignored") ? SIG_IGN : handler;
    require(sigaction(SIGPIPE, &policy, NULL) == 0, "set pipe policy");
    sigset_t selected, original, mask_before, mask_after, pending;
    sigemptyset(&selected); sigaddset(&selected, SIGPIPE);
    int thread_pending = !strcmp(mode, "pipe-thread-pending") || !strcmp(mode, "pipe-both-pending");
    int process_pending = !strcmp(mode, "pipe-process-pending") || !strcmp(mode, "pipe-both-pending");
    int blocked = thread_pending || process_pending || !strcmp(mode, "pipe-blocked");
    require(pthread_sigmask(blocked ? SIG_BLOCK : SIG_UNBLOCK, &selected, &original) == 0, "set pipe mask");
    if (thread_pending) require(pthread_kill(pthread_self(), SIGPIPE) == 0, "queue thread signal");
    if (process_pending) require(kill(getpid(), SIGPIPE) == 0, "queue process signal");
    require(sigaction(SIGPIPE, NULL, &before) == 0, "read pipe policy");
    require(pthread_sigmask(SIG_SETMASK, NULL, &mask_before) == 0, "read pipe mask");
    int pair[2];
    require(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair) == 0, "create test socket");
    require(close(pair[1]) == 0, "close socket peer");
    require(libtmux_process_write(pair[0], "x", 1) == -EPIPE, "broken socket must report EPIPE");
    require(close(pair[0]) == 0, "close socket writer");
    require(delivered == 0, "write delivered SIGPIPE");
    require(sigaction(SIGPIPE, NULL, &after) == 0, "read final pipe policy");
    require(pthread_sigmask(SIG_SETMASK, NULL, &mask_after) == 0, "read final pipe mask");
    require(before.sa_handler == after.sa_handler && before.sa_flags == after.sa_flags
        && same_mask(&before.sa_mask, &after.sa_mask) && same_mask(&mask_before, &mask_after),
        "pipe signal state changed");
    require(sigpending(&pending) == 0, "read pending signals");
    require(sigismember(&pending, SIGPIPE) == (thread_pending || process_pending), "pending signal changed");
    if (blocked) {
        struct timespec immediate = {0};
        for (int i = 0; i < thread_pending + process_pending; ++i)
            require(sigtimedwait(&selected, NULL, &immediate) == SIGPIPE, "lost pending signal");
        require(sigtimedwait(&selected, NULL, &immediate) == -1 && errno == EAGAIN, "added pending signal");
    }
    require(pthread_sigmask(SIG_SETMASK, &original, NULL) == 0, "restore pipe mask");
}

static void closed_stdio(void) {
    int diagnostic = fcntl(2, F_DUPFD_CLOEXEC, 1024);
    require(diagnostic >= 1024, "preserve diagnostic stream");
    diagnostic_fd = diagnostic;
    close(0); close(1); close(2);
    int before = descriptor_count(), result[5];
    char *argv[] = {"/bin/true", NULL}, *env[] = {"LANG=C.UTF-8", NULL};
    require(libtmux_process_spawn(argv[0], argv, env, "/", result) == 0, "closed stdio launch failed");
    for (int i = 0; i < 4; ++i) {
        /* A new pidfd may occupy a vacant stdio slot in the parent.
         * Only the pipe/socket ends participate in child dup2 actions. */
        require(result[i] >= (i == 0 ? 0 : 3), "stream descriptor overlaps stdio");
        for (int j = 0; j < i; ++j) require(result[i] != result[j], "duplicated owned descriptor");
    }
    struct pollfd child = {.fd = result[0], .events = POLLIN};
    require(poll(&child, 1, 250) == 1, "child exit readiness");
    int status[2];
    require(libtmux_process_wait(result[0], status) == 1 && status[0] == 1 && status[1] == 0,
        "closed stdio child status");
    for (int i = 0; i < 4; ++i) require(close(result[i]) == 0, "close owned descriptor");
    require(descriptor_count() == before, "closed stdio leaked descriptor");
}

int main(int argc, char **argv) {
    require(argc == 2, "expected policy mode");
    if (!strcmp(argv[1], "closed-stdio")) closed_stdio();
    else if (!strncmp(argv[1], "pipe-", 5)) broken_input(argv[1]);
    else refused(argv[1]);
    return 0;
}
