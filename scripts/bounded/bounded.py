"""Run external commands under a time limit in Linux process groups."""

import contextlib
import io
import os
import selectors
import signal
import subprocess
import time
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


def stream_output(stream: object, data: bytearray) -> str | bytes | None:
    if isinstance(stream, io.TextIOWrapper):
        text = data.decode(stream.encoding, stream.errors or "strict")
        return text.replace("\r\n", "\n").replace("\r", "\n")
    return bytes(data) if stream is not None else None


def collect(
    process: subprocess.Popen[Any], timeout: float, check: bool
) -> tuple[str | bytes | None, str | bytes | None]:
    out, err = bytearray(), bytearray()
    deadline = time.monotonic() + timeout
    exit_fd = os.pidfd_open(process.pid)
    try:
        with selectors.DefaultSelector() as ready:
            ready.register(exit_fd, selectors.EVENT_READ)
            for stream, data in ((process.stdout, out), (process.stderr, err)):
                if stream is not None:
                    ready.register(stream, selectors.EVENT_READ, data)
            while ready.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(
                        process.args, timeout, bytes(out) or None, bytes(err) or None
                    )
                for key, _ in ready.select(remaining):
                    if key.fd == exit_fd:
                        ready.unregister(exit_fd)
                        # Keep the leader's PID reserved until any group signal has been sent.
                        if check:
                            status = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOWAIT)
                            if status and (status.si_code != os.CLD_EXITED or status.si_status):
                                stop_group(process)
                        continue
                    chunk = os.read(key.fd, 65536)
                    if chunk:
                        key.data.extend(chunk)
                    else:
                        ready.unregister(key.fd)
    finally:
        os.close(exit_fd)
    return stream_output(process.stdout, out), stream_output(process.stderr, err)


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

    A timeout, an interrupt or a nonzero exit with ``check=True`` kills every
    process still in the group.
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
            out, err = collect(process, timeout, check)
        except BaseException:
            stop_group(process)
            raise
        status = process.wait()
    result = subprocess.CompletedProcess(args, status, out, err)
    if check:
        result.check_returncode()
    return result


def output(args: Command, *, timeout: float, cwd: Path | None = None) -> str:
    """Return the text a command printed; it must succeed within ``timeout`` seconds."""
    return run(args, timeout=timeout, check=True, stdout=subprocess.PIPE, text=True, cwd=cwd).stdout
