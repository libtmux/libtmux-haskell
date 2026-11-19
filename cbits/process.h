#ifndef LIBTMUX_PROCESS_H
#define LIBTMUX_PROCESS_H

#include <stddef.h>

int libtmux_process_features(void);
/* Spawn returns errno; success transfers a pidfd and three parent endpoints. */
int libtmux_process_spawn(const char *file, char *const argv[],
                          char *const env[], const char *cwd, int *result);
int libtmux_process_spawn_discard_stdout(const char *file, char *const argv[],
                                        char *const env[], const char *cwd, int *result);
/* Stream calls return a byte count or negative errno. */
int libtmux_process_read(int fd, void *buffer, size_t size);
int libtmux_process_write(int fd, const void *buffer, size_t size);
/* Wait returns zero while live, one with status, or negative errno. */
int libtmux_process_wait(int pidfd, int *result);
/* Signal returns errno, with zero for success. */
int libtmux_process_signal(int pidfd, int signal);
/* Group operations use a retained kernel identity, never a numeric killpg. */
int libtmux_process_group_probe(void);
int libtmux_process_group_open(int pid);
int libtmux_process_group_signal(int pidfd, int signal);
int libtmux_process_pidfd_open(int pid);
int libtmux_process_pidfd_ready(int pidfd);
int libtmux_program_watch(const char *directory);
int libtmux_program_watch_read(int fd);
int libtmux_program_daemon_watch(const char *socket, int expected_pid);

#endif
