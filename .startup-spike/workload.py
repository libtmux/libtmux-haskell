"""Disposable fork/exec and independent-witness workloads for the guardian model."""

from __future__ import annotations

import array
import os
import socket
import sys
import threading


def witness(address: str, tag: str, gate: int | None = None) -> None:
    for fd in (0, 1, 2):
        os.close(fd)
    peer = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    peer.connect(address)
    own = os.pidfd_open(os.getpid())
    peer.sendmsg([tag.encode()], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [own]))])
    os.close(own)
    if gate is not None:
        os.write(gate, b"W")
        os.close(gate)
    peer.recv(1)
    os._exit(0)


def main() -> None:
    if sys.argv[1] == "witness":
        witness(sys.argv[2], sys.argv[3])
    shape, tmux, address, tag = sys.argv[2:6]
    argv = [tmux, *sys.argv[6:]]
    if shape in ("early-exit", "extra-exec"):
        read, write = os.pipe2(os.O_CLOEXEC)
        pid = os.fork()
        if pid == 0:
            os.close(read)
            witness(address, tag, write)
        os.close(write)
        assert os.read(read, 1) == b"W"
        os.close(read)
        if shape == "early-exit":
            os._exit(1)
    if shape == "fork-exec":
        if os.fork():
            os._exit(0)
    if shape == "thread-exec":
        thread = threading.Thread(target=lambda: os.execve(tmux, argv, os.environ))
        thread.start()
        threading.Event().wait()
    os.execve(tmux, argv, os.environ)


if __name__ == "__main__":
    main()
