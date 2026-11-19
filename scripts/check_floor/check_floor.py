# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Qualify refusal on a released daemon, including releases without foreground mode."""

from __future__ import annotations

import argparse
import ctypes
import os
import selectors
import signal
import subprocess
import sys
import tempfile
import time
from collections.abc import Generator
from contextlib import contextmanager, suppress
from pathlib import Path
from types import FrameType
from typing import Never

sys.path.append(str(Path(__file__).resolve().parents[1] / "bounded"))

from bounded import QUICK, output
from bounded import run as bounded_run

OUTPUT_LIMIT = 65536


def environment(directory: Path) -> dict[str, str]:
    """Clear inherited endpoint selectors and mark the private run directory."""
    blocked = {"TMUX", "TMUX_PANE", "LIBTMUX_SOCKET", "LIBTMUX_SOCKET_PATH"}
    result = {key: value for key, value in os.environ.items() if key not in blocked}
    result.update(TMUX_TMPDIR=str(directory), LIBTMUX_TEST_SANDBOX=str(directory))
    return result


def run(arguments: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[bytes]:
    """Use files: old daemons retain a command client's stdout pipe."""
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        result = bounded_run(
            arguments, env=env, stdout=output.fileno(), stderr=errors.fileno(), timeout=1
        )
        output.seek(0)
        errors.seek(0)
        written = output.read(OUTPUT_LIMIT + 1)
        complained = errors.read(OUTPUT_LIMIT + 1)
        if len(written) > OUTPUT_LIMIT or len(complained) > OUTPUT_LIMIT:
            raise RuntimeError("floor fixture command exceeded its output limit")
        return subprocess.CompletedProcess(arguments, result.returncode, written, complained)


class Children:
    """Hold only this dedicated subreaper's children through kernel pidfds."""

    def __init__(self) -> None:
        self.owned: dict[int, int] = {}

    def collect(self) -> None:
        children = Path(f"/proc/self/task/{os.getpid()}/children").read_text().split()
        for raw in children:
            pid = int(raw)
            if pid not in self.owned:
                # Unreaped children retain their PID even when they exit here.
                self.owned[pid] = os.pidfd_open(pid)
        for pid, fd in list(self.owned.items()):
            if os.waitid(os.P_PIDFD, fd, os.WEXITED | os.WNOHANG) is not None:
                os.close(fd)
                del self.owned[pid]

    def retire(self) -> None:
        deadline = time.monotonic() + 1
        while True:
            self.collect()
            if not self.owned:
                # Child snapshots can miss an exit or the descendants it reparents.
                try:
                    os.waitid(os.P_ALL, 0, os.WEXITED | os.WNOHANG)
                except ChildProcessError:
                    return
                if time.monotonic() >= deadline:
                    raise RuntimeError(
                        "floor fixture retained an owned child at its retirement deadline"
                    )
                continue
            for fd in self.owned.values():
                with suppress(ProcessLookupError):
                    signal.pidfd_send_signal(fd, signal.SIGKILL)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("floor fixture retained an owned child after SIGKILL")
            with selectors.DefaultSelector() as ready:
                for fd in self.owned.values():
                    ready.register(fd, selectors.EVENT_READ)
                ready.select(remaining)


@contextmanager
def daemon(binary: Path, directory: Path) -> Generator[tuple[list[str], dict[str, str]]]:
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER, confined to this runner.
        raise OSError(ctypes.get_errno(), "cannot own the legacy daemon's descendants")
    owned = Children()
    env = environment(directory)
    socket = directory / "socket"
    if len(os.fsencode(socket)) >= 100:
        raise ValueError("floor fixture socket must be shorter than 100 bytes")
    command = [str(binary), "-S", str(socket)]
    try:
        result = run(
            [*command, "-f", "/dev/null", "new-session", "-d", "-s", "fixture", "/bin/cat", "-"],
            env,
        )
        if result.returncode:
            raise RuntimeError(f"floor fixture startup failed: {result.stderr!r}")
        owned.collect()
        if len(owned.owned) != 1:
            raise RuntimeError("floor fixture did not acquire exactly one live daemon")
        yield command, env
    finally:
        owned.retire()


def checked(command: list[str], env: dict[str, str]) -> bytes:
    result = run(command, env)
    if result.returncode or result.stderr:
        raise RuntimeError(f"floor fixture command failed: {result.stderr!r}")
    return result.stdout


def observation(command: list[str], env: dict[str, str]) -> tuple[bytes, ...]:
    return tuple(
        checked([*command, *args], env)
        for args in [
            ["list-sessions", "-F", "#{session_id}:#{session_name}"],
            ["list-windows", "-a", "-F", "#{window_id}:#{window_name}:#{window_layout}"],
            ["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}:#{pane_current_command}"],
            ["list-buffers", "-F", "#{buffer_name}:#{buffer_size}"],
            ["capture-pane", "-p", "-t", "fixture:0.0"],
        ]
    )


def hook_marker(command: list[str], env: dict[str, str]) -> bytes:
    result = run([*command, "show-options", "-g", "libtmux-floor-#{@libtmux-floor-hook}"], env)
    if (
        result.returncode != 1
        or result.stdout
        or result.stderr != b"invalid option: libtmux-floor-0\n"
    ):
        raise RuntimeError(f"version admission ran a configured hook: {result.stderr!r}")
    return result.stderr


def check(binary: Path, client: Path, consumer: Path, expected: str, directory: Path) -> None:
    with daemon(binary, directory) as (command, env):
        identity = run([*command, "show-options", "-g", "libtmux-floor-version-#{version}"], env)
        if (
            identity.returncode != 1
            or identity.stdout
            or identity.stderr != f"invalid option: libtmux-floor-version-{expected}\n".encode()
        ):
            raise RuntimeError(
                f"fixture daemon did not report the expected release: {identity.stderr!r}"
            )
        for hook in [
            "after-display-message",
            "after-run-shell",
            "after-show-options",
            "command-error",
        ]:
            result = run(
                [*command, "set-hook", "-g", hook, "set-option -g @libtmux-floor-hook 1"], env
            )
            if result.returncode and result.stderr != f"invalid option: {hook}\n".encode():
                raise RuntimeError(f"cannot install adversarial hook: {result.stderr!r}")
        checked([*command, "set-option", "-g", "@libtmux-floor-hook", "0"], env)
        before = observation(command, env), hook_marker(command, env)
        env.update(
            LIBTMUX_TEST_SOCKET=str(directory / "socket"),
            LIBTMUX_TEST_TMUX=str(client),
            LIBTMUX_TEST_DAEMON_VERSION=expected,
        )
        result = run([str(consumer)], env)
        if (
            result.returncode
            or result.stderr
            or result.stdout != f"refused tmux {expected}\n".encode()
        ):
            raise RuntimeError(f"public floor refusal failed: {result.stdout!r} {result.stderr!r}")
        if before != (observation(command, env), hook_marker(command, env)):
            raise RuntimeError("floor refusal changed sessions, windows, panes, buffers or text")
    print(f"refused actual tmux {expected} without effects; owned descendants retired")


def terminate(number: int, _frame: FrameType | None) -> Never:
    raise SystemExit(128 + number)


def main() -> None:
    signal.signal(signal.SIGTERM, terminate)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--daemon", type=Path, required=True)
    parser.add_argument("--client", type=Path, required=True)
    parser.add_argument("--consumer", type=Path, help="override the built test:floor executable")
    parser.add_argument("--expect", required=True)
    args = parser.parse_args()
    consumer = args.consumer
    if consumer is None:
        checkout = Path(__file__).resolve().parents[2]
        executable = output(
            ["cabal", "list-bin", "test:floor", "--offline"], cwd=checkout, timeout=QUICK
        )
        consumer = Path(executable.strip())
    with tempfile.TemporaryDirectory(prefix="libtmux-haskell-floor-") as name:
        check(
            args.daemon.resolve(),
            args.client.resolve(),
            consumer.resolve(),
            args.expect,
            Path(name),
        )


if __name__ == "__main__":
    main()
