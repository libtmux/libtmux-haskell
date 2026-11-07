#ifndef LIBTMUX_PROCESS_H
#define LIBTMUX_PROCESS_H

#include <stddef.h>

int libtmux_process_features(void);
int libtmux_process_spawn(const char *file, char *const argv[],
                          char *const env[], const char *cwd, int *result);
int libtmux_process_read(int fd, void *buffer, size_t size);
int libtmux_process_write(int fd, const void *buffer, size_t size);
int libtmux_process_wait(int pidfd, int *result);
int libtmux_process_signal(int pidfd, int signal);

#endif
