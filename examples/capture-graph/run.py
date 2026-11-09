"""Run the public capture example against one owned tmux endpoint."""

import argparse
from contextlib import ExitStack, contextmanager
import ctypes
import os
from pathlib import Path
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import time


def exited(descriptors):
    """Observe every owned process through pidfd readiness, without polling."""
    pending = set(descriptors)
    watch = select.poll()
    for descriptor in pending:
        watch.register(descriptor, select.POLLIN)
    deadline = time.monotonic() + 1
    while pending:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("owned tmux server or pane did not exit")
        for descriptor, _ in watch.poll(max(1, int(remaining * 1000))):
            pending.discard(descriptor)
            watch.unregister(descriptor)


def watch_socket(directory, owners):
    """Watch tmux's post-listen chmod before dispatching a client."""
    libc = ctypes.CDLL(None, use_errno=True)
    libc.inotify_init1.argtypes = [ctypes.c_int]
    libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    descriptor = libc.inotify_init1(os.O_CLOEXEC | os.O_NONBLOCK)
    if descriptor < 0:
        raise OSError(ctypes.get_errno(), "inotify_init1")
    owners.callback(os.close, descriptor)
    if libc.inotify_add_watch(descriptor, os.fsencode(directory), 0x4 | 0x400) < 0:
        raise OSError(ctypes.get_errno(), "inotify_add_watch")
    return descriptor


def await_socket(watch, daemon):
    ready = select.poll()
    ready.register(watch, select.POLLIN)
    ready.register(daemon, select.POLLIN)
    deadline = time.monotonic() + 1
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("owned tmux socket did not become ready")
        events = ready.poll(max(1, int(remaining * 1000)))
        if any(descriptor == daemon for descriptor, _ in events):
            raise RuntimeError("owned tmux daemon exited before socket readiness")
        if not events:
            continue
        data = os.read(watch, 4096)
        offset = 0
        while offset < len(data):
            _, mask, _, length = struct.unpack_from("iIII", data, offset)
            name = data[offset + 16:offset + 16 + length].rstrip(b"\0")
            if mask & (0x400 | 0x4000 | 0x8000):
                raise RuntimeError("owned socket readiness watch was lost")
            if mask & 0x4 and name == b"s":
                return
            offset += 16 + length


@contextmanager
def fixture(binary, checkpoint=lambda _stage, _descriptors, _socket: None):
    environment = {key: value for key, value in os.environ.items()
                   if key not in {"TMUX", "TMUX_PANE"}}
    environment["LC_ALL"] = "C.UTF-8"
    with tempfile.TemporaryDirectory(prefix="libtmux-haskell-example-") as directory, ExitStack() as owners:
        socket = str(Path(directory) / "s")
        descriptors = []
        watch = watch_socket(directory, owners)
        errors = owners.enter_context(tempfile.TemporaryFile())
        daemon = subprocess.Popen([binary, "-u", "-D", "-S", socket, "-f", "/dev/null"],
                                  env=environment, stdin=subprocess.DEVNULL,
                                  stdout=subprocess.DEVNULL, stderr=errors)
        session_dispatched = False
        pane_tracked = False
        creation = None
        primary = None
        try:
            descriptor = os.pidfd_open(daemon.pid)
            owners.callback(os.close, descriptor)
            descriptors.append(descriptor)
            await_socket(watch, descriptor)
            checkpoint("daemon-ready", tuple(descriptors), socket)
            session_dispatched = True
            arguments = [binary, "-u", "-N", "-S", socket, "new-session", "-d",
                         "-P", "-F", "#{pane_pid}", "-s", "demo", "-n", "editor",
                         "-x", "120", "-y", "40", "/bin/cat", "-"]
            creation = subprocess.Popen(arguments, env=environment, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE)
            owners.callback(creation.stdout.close)
            owners.callback(creation.stderr.close)
            try:
                output, command_errors = creation.communicate(timeout=1)
            except BaseException as problem:
                try:
                    creation.kill()
                    creation.wait(timeout=1)
                except BaseException as cleanup:
                    problem.add_note(f"session command cleanup: {cleanup}")
                raise
            if creation.returncode:
                raise subprocess.CalledProcessError(creation.returncode, arguments,
                                                    output=output, stderr=command_errors)
            receipt = output.decode("ascii").strip().split()
            if len(receipt) != 1 or not all(value.isdecimal() and int(value) > 0 for value in receipt):
                raise RuntimeError("tmux returned an invalid ownership receipt")
            for value in receipt:
                descriptor = os.pidfd_open(int(value))
                owners.callback(os.close, descriptor)
                descriptors.append(descriptor)
            pane_tracked = True
            checkpoint("pane-ready", tuple(descriptors), socket)
            linked = subprocess.run(
                [binary, "-u", "-N", "-S", socket, "link-window", "-d", "-s", "demo:0", "-t", "demo:4"],
                env=environment, capture_output=True, timeout=1)
            linked.check_returncode()
            yield socket, environment
        except BaseException as problem:
            primary = problem
            raise
        finally:
            try:
                if daemon.poll() is None:
                    daemon.terminate()
                try:
                    daemon.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait(timeout=1)
                if creation is not None:
                    creation.wait(timeout=1)
                exited(descriptors)
                if session_dispatched and not pane_tracked:
                    raise RuntimeError("session creation failed before pane exit ownership was established")
            except BaseException as cleanup:
                if primary is None:
                    raise
                primary.add_note(f"owned fixture cleanup: {cleanup}")


def run(program, binary):
    with fixture(binary) as (socket, environment):
        result = subprocess.run([program, socket, binary], env=environment,
                                capture_output=True, check=True, timeout=3)
        expected = Path(__file__).with_name("expected.stdout").read_bytes()
        if result.stdout != expected or result.stderr:
            raise RuntimeError(f"unexpected example output: {result.stdout!r}; {result.stderr!r}")
        sys.stdout.buffer.write(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--program", help="already-built public consumer executable")
    args = parser.parse_args()
    binary = shutil.which(os.environ.get("LIBTMUX_TEST_TMUX", "tmux"))
    if binary is None:
        raise RuntimeError("tmux is required; set LIBTMUX_TEST_TMUX to select a release")
    program = args.program
    if program is None:
        directory = Path(__file__).resolve().parents[2]
        subprocess.run(["cabal", "build", "exe:capture-graph", "--offline", "-v0"],
                       cwd=directory, capture_output=True, check=True)
        program = subprocess.check_output(
            ["cabal", "list-bin", "exe:capture-graph", "--offline", "-v0"],
            cwd=directory, text=True).strip()
    run(program, binary)


if __name__ == "__main__":
    main()
