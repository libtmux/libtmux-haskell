"""Run external commands under a time limit that also stops the processes they start."""

import contextlib
import os
import signal
import subprocess
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

# Seconds. Every external command is bounded so a hang fails with the command's
# name before the job's time limit stops it without one. README.md records what
# each limit sits above.
QUICK = 120
BUILD = 600

type Command = Sequence[str | os.PathLike[str]]


def stop_group(process: subprocess.Popen[Any]) -> None:
    """Kill the command and every process still in its group."""
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGKILL)


def run(
    args: Command,
    *,
    timeout: float,
    check: bool = False,
    capture_output: bool = False,
    text: bool = False,
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
    stdout: int | None = None,
    stderr: int | None = None,
    pass_fds: Sequence[int] = (),
) -> subprocess.CompletedProcess[Any]:
    """Run ``args`` like ``subprocess.run``, in its own process group.

    A timeout, an interrupt or any other error kills the whole group, so a
    ``ghc`` below a ``cabal`` or a daemon below a runner cannot outlive the limit.
    ``subprocess.run`` kills only the direct child.
    """
    if capture_output:
        stdout = stderr = subprocess.PIPE
    with subprocess.Popen(
        args,
        start_new_session=True,
        text=text,
        cwd=cwd,
        env=env,
        stdout=stdout,
        stderr=stderr,
        pass_fds=pass_fds,
    ) as process:
        try:
            out, err = process.communicate(timeout=timeout)
        except BaseException:
            stop_group(process)
            raise
    result = subprocess.CompletedProcess(args, process.returncode, out, err)
    if check:
        result.check_returncode()
    return result


def output(args: Command, *, timeout: float, cwd: Path | None = None) -> str:
    """Return the text a command printed; it must succeed within ``timeout`` seconds."""
    return run(args, timeout=timeout, check=True, stdout=subprocess.PIPE, text=True, cwd=cwd).stdout
