#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int put(int fd, const void *data, size_t size) {
    const unsigned char *bytes = data;
    while (size) {
        ssize_t count = write(fd, bytes, size);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        bytes += count;
        size -= (size_t)count;
    }
    return 0;
}

static int number(uint32_t value) {
    unsigned char bytes[] = {value >> 24, value >> 16, value >> 8, value};
    return put(1, bytes, 4);
}

static int frame(const char *value) {
    size_t size = strlen(value);
    return number((uint32_t)size) || put(1, value, size);
}

int main(int argc, char **argv, char **env) {
    if (argc > 1 && !strcmp(argv[1], "--signal")) { raise(SIGTERM); return 25; }
    if (argc > 2 && (!strcmp(argv[1], "--gate") || !strcmp(argv[1], "--gated-echo"))) {
        int gate = open(argv[2], O_RDONLY);
        if (gate < 0 || put(1, "R", 1)) return 26;
        char byte;
        ssize_t count;
        do { count = read(gate, &byte, 1); } while (count < 0 && errno == EINTR);
        close(gate);
        if (!strcmp(argv[1], "--gate")) return count == 1 ? 0 : 27;
        if (count != 1) return 27;
    }
    if (argc > 1 && (!strcmp(argv[1], "--echo") || !strcmp(argv[1], "--gated-echo"))) {
        unsigned char buffer[4096];
        for (;;) {
            ssize_t count = read(0, buffer, sizeof(buffer));
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) return 28;
            if (!count) return 0;
            if (put(1, buffer, (size_t)count) || put(2, buffer, (size_t)count)) return 29;
        }
    }
    if (argc > 1 && !strcmp(argv[1], "--flood")) {
        char bytes[16384] = {0};
        for (int i = 0; i < 65; ++i) if (put(1, bytes, sizeof(bytes))) return 91;
        return 0;
    }
    if (argc > 1 && !strcmp(argv[1], "--exit")) return 23;
    if (argc > 1 && !strcmp(argv[1], "--wait")) {
        char byte;
        return read(0, &byte, 1) == 1 ? 0 : 24;
    }
    struct sigaction policy;
    sigset_t blocked;
    if (sigaction(SIGPIPE, NULL, &policy) || policy.sa_handler != SIG_DFL) return 88;
    if (sigprocmask(SIG_SETMASK, NULL, &blocked)) return 89;
    for (int value = 1; value < NSIG; ++value) if (sigismember(&blocked, value) == 1) return 89;
    if (fcntl(0, F_GETFL) & O_NONBLOCK) return 90;
    if (number((uint32_t)argc)) return 80;
    for (int i = 0; i < argc; ++i) if (frame(argv[i])) return 81;
    uint32_t count = 0;
    while (env[count]) ++count;
    if (number(count)) return 82;
    for (uint32_t i = 0; i < count; ++i) if (frame(env[i])) return 83;
    char *cwd = getcwd(NULL, 0);
    if (!cwd || frame(cwd)) return 84;
    free(cwd);
    uint32_t inherited = 0;
    for (int fd = 3; fd < 1024; ++fd) {
        if (fcntl(fd, F_GETFD) >= 0) ++inherited;
    }
    if (number(inherited)) return 85;
    unsigned char buffer[4096];
    for (;;) {
        ssize_t size = read(0, buffer, sizeof(buffer));
        if (size < 0 && errno == EINTR) continue;
        if (size < 0) return 86;
        if (!size) return 0;
        if (put(1, buffer, (size_t)size) || put(2, buffer, (size_t)size)) return 87;
    }
}
