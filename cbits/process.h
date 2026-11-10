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

#endif
