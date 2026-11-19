"""Run the isolated subreaper kernel model; it does not execute a Haskell scope."""

from __future__ import annotations

import argparse
import array
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import select
import selectors
import shlex
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from collections.abc import Callable
from typing import Any

HERE = Path(__file__).resolve().parent
HEADER = struct.Struct("4i")
READY, SPAWNED, STATUS, ADOPTED, COMPLETE, BORN, FAILED, REFUSED = range(1, 9)
SPAWN, STOP, ADOPT, RELEASE = range(10, 14)
WAIT_SECONDS = 0.9
libc = ctypes.CDLL(None, use_errno=True)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def exited(fd: int) -> bool:
    poll = select.poll()
    poll.register(fd, select.POLLIN)
    return bool(poll.poll(0))


def pidfd_pid(fd: int) -> int:
    for line in Path(f"/proc/self/fdinfo/{fd}").read_text().splitlines():
        if line.startswith("Pid:"):
            return int(line.split()[1])
    raise AssertionError("pidfd has no kernel PID field")


def identity(path: Path) -> tuple[int, int]:
    status = path.lstat()
    return status.st_dev, status.st_ino


def audit_helper(library: Path) -> dict[str, Any]:
    disassembly = subprocess.check_output(["objdump", "-d", str(library)], text=True)
    function = ""
    helpers: set[str] = set()
    calls: set[str] = set()
    rejected: list[str] = []
    for line in disassembly.splitlines():
        symbol = re.match(r"^[0-9a-f]+ <([^>]+)>:$", line)
        if symbol:
            function = symbol.group(1)
            if function.startswith("h_"):
                helpers.add(function)
        if not function.startswith("h_"):
            continue
        branch = re.search(r"\b(?:call|jmp)\s+(.+)", line)
        if branch:
            target = re.search(r"<([^>]+)>", branch.group(1))
            if target and target.group(1).startswith("h_"):
                calls.add(target.group(1).split("+")[0])
            else:
                rejected.append(f"{function}: {line.strip()}")
        if "%fs:" in line or "%gs:" in line:
            rejected.append(f"helper TLS access {function}: {line.strip()}")
    bases = {name.split(".")[0] for name in helpers}
    require("h_start" in bases and "h_clone" in bases, "native helper entry symbols missing from audit")
    require(not rejected, f"native helper escaped raw syscall discipline: {rejected}")
    return {"status": "PASS", "helpers": sorted(helpers), "helper_call_targets": sorted(calls),
            "external_or_indirect_calls": [], "tls_access": [],
            "library_sha256": hashlib.sha256(library.read_bytes()).hexdigest(),
            "source_sha256": hashlib.sha256((HERE / "guardian_native.c").read_bytes()).hexdigest()}


class World:
    def __init__(self, helper: Path, tmux: Path) -> None:
        # Isolated fixture containment. Its reaping never discharges candidate
        # debt after guardian loss; the production host is not a subreaper.
        require(libc.prctl(36, 1, 0, 0, 0) == 0, "fixture subreaper unavailable")
        self.root = Path(tempfile.mkdtemp(prefix="hsg-"))
        self.selector = selectors.DefaultSelector()
        self.helper = helper
        self.native = ctypes.CDLL(str(helper))
        self.native.guardian_new.argtypes = [ctypes.POINTER(ctypes.c_int)]
        self.native.guardian_new.restype = ctypes.c_int
        self.workers_done = threading.Event()
        self.workers = [threading.Thread(target=self.workers_done.wait, daemon=True) for _ in range(2)]
        for worker in self.workers:
            worker.start()
        self.tmux = tmux
        self.guardians: list[Guardian] = []
        self.witnesses: dict[str, tuple[int, socket.socket]] = {}
        self.all_fds: set[int] = set()
        self.observer = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        self.observer.bind(str(self.root / "w"))
        self.observer.listen(64)
        self.observer.setblocking(False)
        self.selector.register(self.observer, selectors.EVENT_READ, self.observe)
        self.home = self.root / "home"
        self.home.mkdir()
        (self.home / ".tmux.conf").write_text(
            "set-option -g @fixture-loaded yes\n"
            f"run-shell -b {shlex.quote('touch ' + str(self.root / 'user-config-ran'))}\n"
        )
        self.environment = {key: value for key, value in os.environ.items()
                            if key not in ("TMUX", "TMUX_PANE")}
        self.environment.update(HOME=str(self.home), TERM="xterm-256color", LC_ALL="C")

    def observe(self, _file: Any) -> None:
        peer, _ = self.observer.accept()
        data, control, flags, _ = peer.recvmsg(256, socket.CMSG_SPACE(4), socket.MSG_CMSG_CLOEXEC)
        require(not flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC), "truncated independent witness")
        fds = array.array("i")
        for level, kind, payload in control:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                fds.frombytes(payload)
        require(len(fds) == 1, "missing independent self-pidfd")
        credentials = peer.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
        peer_pid, _, _ = struct.unpack("3i", credentials)
        fd = fds[0]
        self.all_fds.add(fd)
        self.selector.register(fd, selectors.EVENT_READ, self.unwatch_exit)
        require(pidfd_pid(fd) == peer_pid, "independent witness disagrees with peer credentials")
        tag = data.decode()
        require(tag not in self.witnesses, "duplicate independent witness tag")
        self.witnesses[tag] = (fd, peer)

    def unwatch_exit(self, fd: int) -> None:
        self.selector.unregister(fd)

    def until(self, predicate: Callable[[], bool], reason: str) -> None:
        deadline = time.monotonic() + WAIT_SECONDS
        while not predicate():
            remaining = deadline - time.monotonic()
            require(remaining > 0, f"event deadline: {reason}")
            events = self.selector.select(remaining)
            require(bool(events), f"event deadline: {reason}")
            for key, _ in events:
                key.data(key.fileobj)

    def witness(self, tag: str) -> int:
        self.until(lambda: tag in self.witnesses, f"independent witness {tag}")
        return self.witnesses[tag][0]

    def guardian(self) -> Guardian:
        guardian = Guardian(self)
        self.guardians.append(guardian)
        self.until(lambda: guardian.ready, "subreaper guardian ready before any workload")
        require(not exited(guardian.pidfd), "guardian died with its creating OS thread")
        return guardian

    def names(self, label: str, directory: Path | None = None) -> Names:
        return Names(self, label, directory)

    def close(self) -> None:
        # Fixture-only recovery: this isolated process owns every listed kernel
        # child. Do not use this information to change any guardian's verdict.
        deadline = time.monotonic() + WAIT_SECONDS
        while True:
            own = Path(f"/proc/self/task/{os.getpid()}/children").read_text().split()
            watches: list[int] = []
            for token in own:
                fd = os.pidfd_open(int(token))
                watches.append(fd)
                signal.pidfd_send_signal(fd, signal.SIGKILL)
            while True:
                try:
                    pid, status = os.waitpid(-1, os.WNOHANG | 0x40000000)
                except ChildProcessError:
                    pid = -1
                if pid <= 0:
                    break
                for guardian in self.guardians:
                    if guardian.process.pid == pid:
                        guardian.process.returncode = os.waitstatus_to_exitcode(status)
            if pid == -1:
                for fd in watches:
                    os.close(fd)
                break
            remaining = deadline - time.monotonic()
            require(remaining > 0, "isolated fixture could not collect its children")
            poll = select.poll()
            for fd in watches:
                poll.register(fd, select.POLLIN)
            poll.poll(max(1, int(remaining * 1000)))
            for fd in watches:
                os.close(fd)
        for guardian in self.guardians:
            require(guardian.process.returncode is not None, "fixture lost guardian collection status")
            guardian.control.close()
            if guardian.process.stderr:
                guardian.process.stderr.close()
        for _, peer in self.witnesses.values():
            peer.close()
        self.observer.close()
        self.selector.close()
        for fd in self.all_fds:
            try:
                os.close(fd)
            except OSError as problem:
                require(problem.errno == errno.EBADF, "unexpected fixture descriptor close failure")
        self.workers_done.set()
        for worker in self.workers:
            worker.join(WAIT_SECONDS)
            require(not worker.is_alive(), "host background thread did not join")
        shutil.rmtree(self.root)


class Names:
    def __init__(self, world: World, label: str, directory: Path | None) -> None:
        self.world = world
        self.directory = directory or world.root / label
        self.directory.mkdir(exist_ok=True)
        self.directory_id = identity(self.directory)
        self.socket = self.directory / "s"
        self.socket_id: tuple[int, int] | None = None
        self.watch = libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        require(self.watch >= 0, "inotify unavailable")
        world.all_fds.add(self.watch)
        mask = 0x4 | 0x100 | 0x80 | 0x200 | 0x400
        require(libc.inotify_add_watch(self.watch, os.fsencode(self.directory), mask) >= 0,
                "private directory watch unavailable")
        world.selector.register(self.watch, selectors.EVENT_READ, self.drain)

    def drain(self, fd: int) -> None:
        try:
            while os.read(fd, 4096):
                pass
        except BlockingIOError:
            pass

    def peer(self) -> int | None:
        peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        peer.setblocking(False)
        try:
            peer.connect(str(self.socket))
            # SO_PEERPIDFD is 77 on the already-required Linux host family.
            fd = struct.unpack("i", peer.getsockopt(socket.SOL_SOCKET, 77, 4))[0]
        except OSError as problem:
            if problem.errno in (errno.ENOENT, errno.ECONNREFUSED):
                return None
            raise
        finally:
            peer.close()
        self.world.all_fds.add(fd)
        self.socket_id = identity(self.socket)
        return fd

    def listener(self) -> int:
        result: list[int] = []

        def probe() -> bool:
            fd = self.peer()
            if fd is not None:
                result.append(fd)
            return bool(result)

        self.world.until(probe, "private tmux listener (post-listen chmod event)")
        return result[0]

    def cleanup(self, remove_directory: bool = True) -> bool:
        if not self.directory.exists() or identity(self.directory) != self.directory_id:
            return False
        if self.socket.exists():
            if self.socket_id is None or identity(self.socket) != self.socket_id:
                return False
            self.socket.unlink()
        if not remove_directory:
            return True
        try:
            self.directory.rmdir()
        except OSError:
            return False
        return True


class NativeProcess:
    def __init__(self, pid: int) -> None:
        self.pid = pid
        self.returncode: int | None = None
        self.stderr = None

    def wait(self, timeout: int) -> int:
        require(timeout == 0, "native fixture only collects after a physical exit event")
        if self.returncode is None:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            require(pid == self.pid, "native helper exit event was not collectible")
            self.returncode = os.waitstatus_to_exitcode(status)
        return self.returncode


class Guardian:
    def __init__(self, world: World) -> None:
        self.world = world
        self.intent = True  # Registered before helper birth or command publication.
        self.ready = False
        self.proof = False
        self.physical_exit = False
        self.control_eof = False
        self.events: dict[int, tuple[int, int, int, int | None]] = {}
        self.statuses: dict[int, int] = {}
        self.children: dict[int, int] = {}
        self.outputs: dict[int, list[bytearray]] = {}
        self.streams: dict[int, tuple[int, int]] = {}
        self.key = 0
        self.collected = 0
        self.native_result = (ctypes.c_int * 3)(-1, -1, -1)
        self.native_error = -1
        self.creator_tid = -1
        self.birth_host_threads = -1

        def create() -> None:
            self.creator_tid = threading.get_native_id()
            self.birth_host_threads = len(list(Path("/proc/self/task").iterdir()))
            self.native_error = world.native.guardian_new(self.native_result)

        creator = threading.Thread(target=create, daemon=True)
        creator.start()
        creator.join(WAIT_SECONDS)
        require(not creator.is_alive(), "native guardian acquisition exceeded its event bound")
        require(self.native_error == 0, f"native guardian acquisition refused {self.native_error}")
        require(self.creator_tid != os.getpid() and self.birth_host_threads >= 4,
                "native proof lacked a nonleader creator and concurrent host threads")
        channel, self.pidfd, pid = self.native_result
        self.control = socket.socket(fileno=channel)
        self.process = NativeProcess(pid)
        self.creator_exited_before_ready = True
        world.all_fds.add(self.pidfd)
        world.selector.register(self.pidfd, selectors.EVENT_READ, self.observe_exit)
        world.selector.register(self.control, selectors.EVENT_READ, self.receive)

    def observe_exit(self, _fd: int) -> None:
        self.physical_exit = True
        self.world.selector.unregister(self.pidfd)

    def receive(self, _peer: socket.socket) -> None:
        data, control, flags, _ = self.control.recvmsg(16, socket.CMSG_SPACE(4), socket.MSG_CMSG_CLOEXEC)
        require(not flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC), "truncated guardian event")
        if not data:
            self.control_eof = True
            self.world.selector.unregister(self.control)
            return
        require(len(data) == 16, "invalid guardian event")
        fds = array.array("i")
        for level, kind, payload in control:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                fds.frombytes(payload)
        require(len(fds) <= 1, "unexpected guardian descriptor count")
        fd = fds[0] if fds else None
        if fd is not None:
            self.world.all_fds.add(fd)
            self.world.selector.register(fd, selectors.EVENT_READ, self.world.unwatch_exit)
        op, key, arg, code = HEADER.unpack(data)
        if op == READY:
            self.ready = True
        elif op == STATUS:
            require(key not in self.statuses, "a command status was collected twice")
            self.statuses[key] = code
        elif op == COMPLETE:
            require(code == errno.ECHILD, "completion lacks live ECHILD")
            self.proof = True
            self.collected = arg
        else:
            self.events[key] = (op, arg, code, fd)
            if op == SPAWNED:
                require(fd is not None, "native command birth lacks pidfd")
                self.children[key] = fd

    def send(self, op: int, key: int = 0, arg: int = 0, code: int = 0,
             payload: bytes = b"", fds: list[int] | None = None) -> None:
        rights = [] if not fds else [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds))]
        message = HEADER.pack(op, key, arg, code) + payload
        require(self.control.sendmsg([message], rights) == len(message), "short guardian command")

    def request_spawn(self, argv: list[str], hold: bool = False) -> int:
        self.key += 1
        key = self.key
        # The outstanding key and its streams exist before a spawn can occur.
        self.outputs[key] = [bytearray(), bytearray()]
        stdin_read, stdin_write = os.pipe2(os.O_CLOEXEC)
        stdout_read, stdout_write = os.pipe2(os.O_CLOEXEC)
        stderr_read, stderr_write = os.pipe2(os.O_CLOEXEC)
        for index, fd in enumerate((stdout_read, stderr_read)):
            os.set_blocking(fd, False)
            self.world.all_fds.add(fd)
            self.streams[fd] = (key, index)
            self.world.selector.register(fd, selectors.EVENT_READ, self.read_stream)
        payload = b"\0".join(os.fsencode(value) for value in argv + [
            f"{name}={value}" for name, value in self.world.environment.items()]) + b"\0"
        try:
            self.send(SPAWN, key, len(argv), int(hold), payload, [stdin_read, stdout_write, stderr_write])
        finally:
            for fd in (stdin_read, stdin_write, stdout_write, stderr_write):
                os.close(fd)
        return key

    def read_stream(self, fd: int) -> None:
        chunk = os.read(fd, 65536)
        key, index = self.streams[fd]
        self.outputs[key][index].extend(chunk)
        require(len(self.outputs[key][index]) <= 1048576, "model output bound exceeded")
        if not chunk:
            self.world.selector.unregister(fd)
            del self.streams[fd]
            self.world.all_fds.remove(fd)
            os.close(fd)

    def spawn(self, argv: list[str], hold: bool = False) -> int:
        key = self.request_spawn(argv, hold)
        self.world.until(lambda: key in self.events, "guardian command birth or refusal")
        require(self.events[key][0] == (BORN if hold else SPAWNED), "guardian refused command")
        return key

    def launch(self, names: Names, shape: str, tag: str) -> tuple[int, int]:
        key = self.spawn(self.command(shape, tag, ["-D", "-u", "-S", str(names.socket), "-f", "/dev/null"]))
        peer = names.listener()
        owned = self.adopt(peer)
        require(owned is not None, "listener is not a current guardian child")
        return key, owned

    def command(self, shape: str, tag: str, argv: list[str]) -> list[str]:
        return [sys.executable, str(HERE / "workload.py"), "launcher", shape,
                str(self.world.tmux), str(self.world.root / "w"), tag, *argv]

    def adopt(self, peer: int) -> int | None:
        self.key += 1
        key = self.key
        self.send(ADOPT, key, fds=[peer])
        self.world.until(lambda: key in self.events, "listener ownership decision")
        op, _, _, fd = self.events[key]
        return fd if op == ADOPTED else None

    def result(self, key: int, expected: int = 0) -> bytes:
        self.world.until(lambda: key in self.statuses and all(value[0] != key for value in self.streams.values()),
                         "one collected command status and both stream EOFs")
        self.status(key, expected)
        return bytes(self.outputs[key][0])

    def status(self, key: int, expected: int = 0) -> None:
        self.world.until(lambda: key in self.statuses, "one collected command status")
        status = self.statuses[key]
        require(os.waitstatus_to_exitcode(status) == expected,
                f"unexpected command status {status}: {bytes(self.outputs[key][1])!r}")
        require(exited(self.children[key]), "command status preceded physical exit")

    @property
    def complete(self) -> bool:
        # Once a guardian is lost without its proof, later known-child exits do
        # not establish that no unreported descendant was born.
        return (self.intent and self.proof and self.physical_exit
                and all(exited(fd) for fd in self.children.values()))

    def finish(self, release: bool = False) -> None:
        self.send(STOP)
        if release:
            self.send(RELEASE)
        self.world.until(lambda: self.complete and not self.streams,
                         "full subtree proof, guardian/child exits and all client stream EOFs")
        require(self.process.wait(timeout=0) == 0, "guardian failed after its proof")

    def qualify(self, names: Names) -> dict[str, Any]:
        def command(argv: list[str]) -> bytes:
            return self.result(self.spawn(self.command("native", "unused", ["-S", str(names.socket), *argv])))

        pid = int(command(["display-message", "-p", "#{pid}"]).strip())
        require(command(["show-options", "-gv", "exit-empty"]).strip() == b"off", "empty daemon can exit")
        require(command(["show-options", "-gqv", "@fixture-loaded"]).strip() == b"", "user config loaded")
        require(not (self.world.root / "user-config-ran").exists(), "user config job executed")
        require(not command(["list-sessions", "-F", "#{session_id}"]), "empty startup created a session")
        return {"daemon_pid": pid, "empty_daemon": True, "exit_empty": "off", "user_config_skipped": True}


def normal(world: World, shape: str) -> dict[str, Any]:
    guardian = world.guardian()
    names = world.names("owned")
    key, daemon = guardian.launch(names, shape, "extra")
    facts = guardian.qualify(names)
    require(pidfd_pid(daemon) == facts["daemon_pid"], "adopted listener is not admitted tmux daemon")
    extra = world.witness("extra") if shape == "extra-exec" else None
    if extra is not None:
        require(not exited(extra), "extra launcher child was not alive at admission")
    if shape == "fork-exec":
        guardian.status(key)
        require(not exited(daemon), "collecting the launcher killed the adopted daemon")
        require(any(value[0] == key for value in guardian.streams.values()),
                "launcher control lacks the daemon's inherited open streams")
    guardian.finish()
    require(exited(daemon), "admitted daemon survived full proof")
    if extra is not None:
        require(exited(extra), "independent extra launcher child survived full proof")
    require(names.cleanup(), "unchanged private namespace cleanup failed")
    facts.update(shape=shape, guardian_complete=True, collected=guardian.collected,
                 extra_child_exited=extra is not None)
    return facts


def early(world: World) -> dict[str, Any]:
    guardian = world.guardian()
    key = guardian.spawn(guardian.command("early-exit", "early", ["-D"]))
    witness = world.witness("early")
    guardian.result(key, 1)
    require(not exited(witness), "negative control requires surviving early-fork child")
    guardian.finish()
    require(exited(witness), "early launcher child survived guardian closure")
    return {"direct_collected": True, "extra_live_after_direct_collection": True,
            "extra_exited_after_guardian_closure": True, "guardian_complete": True}


def unpublished(world: World, kill: bool) -> dict[str, Any]:
    guardian = world.guardian()
    key = guardian.spawn([sys.executable, str(HERE / "workload.py"), "witness",
                          str(world.root / "w"), "unpublished"], hold=True)
    witness = world.witness("unpublished")
    require(key not in guardian.children, "fault gap unexpectedly published child pidfd")
    if kill:
        signal.pidfd_send_signal(guardian.pidfd, signal.SIGKILL)
        world.until(lambda: guardian.physical_exit, "killed guardian physical exit")
        require(not guardian.complete and not guardian.proof, "helper loss discharged unreported birth debt")
        require(not exited(witness), "helper-loss negative control lost the independent live child")
        signal.pidfd_send_signal(witness, signal.SIGKILL)
        world.until(lambda: exited(witness), "fixture-owned unpublished child physical exit")
        require(not guardian.complete, "known witness exit erased unknown helper-loss debt")
        return {"unpublished_birth": True, "guardian_killed": True, "live_independent_child_after_loss": True,
                "debt_retained_after_known_child_exit": True, "guardian_complete": False}
    guardian.finish(release=True)
    require(exited(witness), "unpublished child survived cancellation closure")
    return {"unpublished_birth": True, "cancel_before_publication": True,
            "independent_child_exited": True, "guardian_complete": True}


def daemon_kill(world: World, kill_guardian: bool) -> dict[str, Any]:
    guardian = world.guardian()
    names = world.names("owned")
    key, daemon = guardian.launch(names, "extra-exec", "extra")
    guardian.qualify(names)
    extra = world.witness("extra")
    if kill_guardian:
        signal.pidfd_send_signal(guardian.pidfd, signal.SIGKILL)
        world.until(lambda: guardian.physical_exit, "guardian loss after admission")
        require(not guardian.complete and not guardian.proof, "guardian loss was reported complete")
        require(not exited(daemon) and not exited(extra), "helper loss negative control lacks live descendants")
        signal.pidfd_send_signal(daemon, signal.SIGKILL)
        signal.pidfd_send_signal(extra, signal.SIGKILL)
        world.until(lambda: exited(daemon) and exited(extra), "fixture retirement of held witnesses")
        require(not guardian.complete, "later known daemon/child exits erased guardian debt")
        return {"guardian_killed_after_admission": True, "daemon_and_extra_live_after_loss": True,
                "debt_retained_after_known_exits": True, "guardian_complete": False}
    signal.pidfd_send_signal(daemon, signal.SIGKILL)
    guardian.result(key, -signal.SIGKILL)
    require(not exited(extra), "killing the daemon also hid the required extra-child control")
    guardian.finish()
    require(exited(extra), "extra child survived closure after daemon kill")
    require(names.cleanup(), "namespace cleanup failed after daemon kill")
    return {"daemon_killed_and_collected_once": True, "extra_outlived_daemon": True,
            "extra_exited_after_closure": True, "guardian_complete": True}


def clients_panes(world: World) -> dict[str, Any]:
    guardian = world.guardian()
    names = world.names("owned")
    version = guardian.spawn(guardian.command("extra-exec", "version", ["-V"]))
    require(guardian.result(version).startswith(b"tmux "), "version client failed")
    version_child = world.witness("version")
    require(not exited(version_child), "version launcher descendant did not survive direct exit")
    _, daemon = guardian.launch(names, "extra-exec", "daemon-extra")
    guardian.qualify(names)
    daemon_extra = world.witness("daemon-extra")
    pane_command = shlex.join([sys.executable, str(HERE / "workload.py"), "pane-witness",
                              str(world.root / "w"), "pane"])
    client = guardian.spawn(guardian.command("extra-exec", "client-extra", ["-S", str(names.socket),
                             "new-session", "-d", "-s", "owned", pane_command]))
    guardian.result(client)
    client_extra, pane = world.witness("client-extra"), world.witness("pane")
    witnesses = [version_child, daemon_extra, client_extra, pane]
    require(all(not exited(fd) for fd in witnesses), "live version/client/pane control missing")
    guardian.finish()
    require(exited(daemon) and all(exited(fd) for fd in witnesses), "owned descendant survived full proof")
    require(names.cleanup(), "pane scope namespace cleanup failed")
    return {"version_client_descendant": True, "command_client_descendant": True,
            "original_pane_witness": True, "all_independent_witnesses_exited": True,
            "guardian_complete": True, "collected": guardian.collected}


def concurrent(world: World) -> dict[str, Any]:
    first, second = world.guardian(), world.guardian()
    left, right = world.names("left"), world.names("right")
    first_start = first.request_spawn(first.command("fork-exec", "unused", ["-D", "-S", str(left.socket), "-f", "/dev/null"]))
    second_start = second.request_spawn(second.command("extra-exec", "right-extra", ["-D", "-S", str(right.socket), "-f", "/dev/null"]))
    left_peer, right_peer = left.listener(), right.listener()
    left_daemon, right_daemon = first.adopt(left_peer), second.adopt(right_peer)
    require(left_daemon is not None and right_daemon is not None, "concurrent own adoption failed")
    require(first.adopt(right_peer) is None and second.adopt(left_peer) is None, "foreign guardian child was adopted")
    first.status(first_start)
    world.until(lambda: second_start in second.events, "concurrent second command publication")
    pending = [(guardian, guardian.request_spawn(guardian.command("native", "unused", ["-S", str(names.socket),
               "display-message", "-p", "#{pid}"]))) for guardian, names in [(first, left), (second, right)] * 3]
    for guardian, key in pending:
        world.until(lambda: key in guardian.children, "concurrent client publication")
        require(int(guardian.result(key).strip()) in (pidfd_pid(left_daemon), pidfd_pid(right_daemon)), "wrong concurrent daemon")
    extra = world.witness("right-extra")
    first.finish()
    require(exited(left_daemon) and not exited(right_daemon) and not exited(extra), "one context retired another context")
    require(left.cleanup(), "first namespace cleanup failed")
    second.finish()
    require(exited(right_daemon) and exited(extra), "second context failed to retire its subtree")
    require(right.cleanup(), "second namespace cleanup failed")
    return {"concurrent_spawn_adoption": True, "foreign_adoption_refused": True,
            "unrelated_live_context_preserved": True, "both_guardians_complete": True}


def replacement(world: World, replace_directory: bool) -> dict[str, Any]:
    first = world.guardian()
    names = world.names("owned")
    _, daemon = first.launch(names, "extra-exec", "owned-extra")
    first.qualify(names)
    extra = world.witness("owned-extra")
    saved = world.root / "saved" if replace_directory else names.directory / "old-s"
    (names.directory if replace_directory else names.socket).rename(saved)
    foreign = world.guardian()
    other = world.names("foreign", names.directory)
    _, foreign_daemon = foreign.launch(other, "native", "unused")
    foreign.qualify(other)
    foreign_socket_id = identity(other.socket)
    first.finish()
    require(exited(daemon) and exited(extra), "namespace replacement blocked owned physical retirement")
    require(not names.cleanup(), "replacement namespace was removed")
    require(identity(other.socket) == foreign_socket_id and not exited(foreign_daemon), "foreign replacement was disturbed")
    foreign.finish()
    require(other.cleanup(remove_directory=replace_directory), "foreign fixture's own cleanup failed")
    saved.rename(names.directory if replace_directory else names.socket)
    require(names.cleanup(), "restored exact namespace could not resume cleanup")
    return {"replacement": "directory" if replace_directory else "socket",
            "owned_subtree_exited": True, "replacement_preserved": True,
            "foreign_daemon_preserved": True, "namespace_debt_retained": True,
            "exact_namespace_recovery_completed": True}


CASES: dict[str, Callable[[World], dict[str, Any]]] = {
    "native": lambda world: normal(world, "native"),
    "fork-before-listen-parent-exit": early,
    "fork-extra-then-exec": lambda world: normal(world, "extra-exec"),
    "adopt-after-launcher-exit": lambda world: normal(world, "fork-exec"),
    "nonleader-thread-exec": lambda world: normal(world, "thread-exec"),
    "cancel-unpublished-birth": lambda world: unpublished(world, False),
    "guardian-killed-unpublished-birth": lambda world: unpublished(world, True),
    "daemon-killed": lambda world: daemon_kill(world, False),
    "guardian-killed-admitted": lambda world: daemon_kill(world, True),
    "version-client-pane-descendants": clients_panes,
    "concurrent-contexts": concurrent,
    "socket-replacement": lambda world: replacement(world, False),
    "directory-replacement": lambda world: replacement(world, True),
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tmux", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--case", choices=CASES)
    parser.add_argument("--helper", type=Path)
    args = parser.parse_args()
    if args.case:
        require(args.helper is not None, "isolated case needs compiled helper")
        world = World(args.helper, args.tmux)
        start = time.monotonic()
        try:
            facts = CASES[args.case](world)
            facts["threaded_host"] = all(guardian.birth_host_threads >= 4 for guardian in world.guardians)
            facts["nonleader_creator_joined_before_admission"] = all(
                guardian.creator_tid != os.getpid() and guardian.creator_exited_before_ready
                for guardian in world.guardians)
            result = {"case": args.case, "status": "PASS", "facts": facts}
        finally:
            world.close()
        result["wall_seconds"] = time.monotonic() - start
        print(json.dumps(result))
        return
    output = args.output or Path(tempfile.mkdtemp(prefix="guardian-model-"))
    output.mkdir(exist_ok=True, parents=True)
    start = time.monotonic()
    helper = output / "guardian-native.so"
    subprocess.run(["gcc", "-std=gnu11", "-O2", "-g", "-Wall", "-Wextra", "-Werror",
                    "-fPIC", "-shared", "-Wl,-z,now", "-o", str(helper), str(HERE / "guardian_native.c")], check=True)
    audit = audit_helper(helper)
    (output / "native-code-audit.json").write_text(json.dumps(audit, indent=2) + "\n")
    results = []
    for case in CASES:
        command = [sys.executable, str(Path(__file__).resolve()), "--tmux", str(args.tmux.resolve()),
                   "--helper", str(helper.resolve()), "--case", case]
        process = subprocess.run(command, capture_output=True, text=True)
        (output / f"{case}.log").write_text(process.stdout + process.stderr)
        result = json.loads(process.stdout) if process.returncode == 0 else {
            "case": case, "status": "FAIL", "returncode": process.returncode}
        results.append(result)
        print(json.dumps(result), flush=True)
    receipt = {"scope": "raw native guardian from a threaded host; Haskell scope not executed",
               "tmux": str(args.tmux), "wall_seconds": time.monotonic() - start, "results": results,
               "status": "PASS" if all(result["status"] == "PASS" for result in results) else "FAIL"}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    require(receipt["status"] == "PASS", f"guardian kernel model failed; evidence at {output}")


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        traceback.print_exc()
        raise SystemExit(1) from None
