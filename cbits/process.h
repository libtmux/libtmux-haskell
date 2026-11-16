#ifndef LIBTMUX_PROCESS_H
#define LIBTMUX_PROCESS_H

#include <stddef.h>

int libtmux_process_features(void);
/* Spawn returns errno; success transfers a pidfd and three parent endpoints. */
int libtmux_process_spawn(const char *file, char *const argv[],
                          char *const env[], const char *cwd, int *result);
/* Stream calls return a byte count or negative errno. */
int libtmux_process_read(int fd, void *buffer, size_t size);
int libtmux_process_write(int fd, const void *buffer, size_t size);
/* Wait returns zero while live, one with status, or negative errno. */
int libtmux_process_wait(int pidfd, int *result);
/* Signal returns errno, with zero for success. */
int libtmux_process_signal(int pidfd, int signal);
/* Daemon ownership uses nonblocking listener acquisition and pidfd exit evidence. */
int libtmux_process_daemon_features(void);
int libtmux_process_peer_pidfd(const char *path);
int libtmux_process_anchor(const char *path);
int libtmux_process_dup(int fd);
int libtmux_process_watch_removals(const char *directory);
int libtmux_process_watch_drain(int fd);
int libtmux_process_lock_held(const char *path);
int libtmux_process_poll(int fd, int milliseconds);

#endif
