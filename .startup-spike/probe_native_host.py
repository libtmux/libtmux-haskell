"""Qualify native acquisition state after the independent subtree model passes."""

from __future__ import annotations

import argparse
import ctypes
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from collections.abc import Callable
from typing import Any

import probe_guardian as model


def own_children() -> list[str]:
    return Path(f"/proc/self/task/{os.getpid()}/children").read_text().split()


def invoke(world: model.World) -> tuple[int, list[int]]:
    result = (ctypes.c_int * 3)(-1, -1, -1)
    outcome: list[int] = []
    worker = threading.Thread(target=lambda: outcome.append(world.native.guardian_new(result)))
    worker.start()
    worker.join(model.WAIT_SECONDS)
    model.require(not worker.is_alive(), "native refusal blocked")
    return outcome[0], list(result)


def refused_policy(world: model.World) -> dict[str, Any]:
    class Sigaction(ctypes.Structure):
        _fields_ = [("handler", ctypes.c_void_p), ("mask", ctypes.c_ulong * 16),
                    ("flags", ctypes.c_int), ("restorer", ctypes.c_void_p)]

    model.require(ctypes.sizeof(Sigaction) == 152 and Sigaction.flags.offset == 136,
                  "unexpected glibc x86_64 sigaction layout")
    old = Sigaction()
    model.require(model.libc.sigaction(signal.SIGCHLD, None, ctypes.byref(old)) == 0,
                  "cannot read SIGCHLD policy")
    before = own_children()
    observations = []
    try:
        for handler, flags in [(1, 0), (0, 2)]:  # SIG_IGN, then SA_NOCLDWAIT.
            action = Sigaction()
            action.handler, action.flags = handler, flags
            model.require(model.libc.sigaction(signal.SIGCHLD, ctypes.byref(action), None) == 0,
                          "cannot install isolated signal policy")
            error, result = invoke(world)
            model.require(error == 95 and result == [-1, -1, -1], "unwaitable host created a helper")
            model.require(own_children() == before, "refused acquisition changed child set")
            observations.append({"ignored": bool(handler), "no_cldwait": bool(flags), "refused_before_birth": True})
    finally:
        model.require(model.libc.sigaction(signal.SIGCHLD, ctypes.byref(old), None) == 0,
                      "cannot restore SIGCHLD policy")
    return {"policies": observations}


def signal_state(world: model.World) -> dict[str, Any]:
    before_policy = signal.signal(signal.SIGTERM, signal.SIG_IGN)
    before_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGUSR1, signal.SIGUSR2})
    masks: list[set[signal.Signals]] = []
    original = world.native.guardian_new

    def capturing(result: Any) -> int:
        masks.append(signal.pthread_sigmask(signal.SIG_BLOCK, set()))
        error = original(result)
        masks.append(signal.pthread_sigmask(signal.SIG_BLOCK, set()))
        return error

    world.native.guardian_new = capturing
    try:
        guardian = world.guardian()
        model.require(masks[0] == masks[1] and signal.SIGUSR1 in masks[1], "creating thread signal mask changed")
        status = dict(line.split(":", 1) for line in Path(f"/proc/{guardian.process.pid}/status").read_text().splitlines())
        model.require(int(status["SigIgn"], 16) == 0 and int(status["SigCgt"], 16) == 0,
                      "helper inherited host signal dispositions")
        model.require(int(status["SigBlk"], 16) == 1 << (signal.SIGCHLD - 1), "helper signal mask is not private")
        key = guardian.spawn([sys.executable, str(model.HERE / "workload.py"), "pane-witness",
                              str(world.root / "w"), "child-mask"])
        witness = world.witness("child-mask")
        child_status = dict(line.split(":", 1) for line in Path(f"/proc/{model.pidfd_pid(witness)}/status").read_text().splitlines())
        model.require(int(child_status["SigBlk"], 16) == 0, "configured executable inherited blocked host signals")
        guardian.finish()
        model.require(model.exited(witness) and key in guardian.statuses, "signal-state workload was not collected")
    finally:
        world.native.guardian_new = original
        signal.pthread_sigmask(signal.SIG_SETMASK, before_mask)
        signal.signal(signal.SIGTERM, before_policy)
    return {"creator_mask_restored": True, "helper_dispositions_reset": True,
            "helper_private_mask": True, "configured_child_mask_empty": True}


def host_subreaper(world: model.World) -> dict[str, Any]:
    model.require(model.libc.prctl(36, 0, 0, 0, 0) == 0, "cannot clear fixture subreaper state")
    try:
        guardian = world.guardian()
        value = ctypes.c_int(-1)
        model.require(model.libc.prctl(37, ctypes.byref(value), 0, 0, 0) == 0 and value.value == 0,
                      "native acquisition made the host a subreaper")
        guardian.finish()
    finally:
        model.require(model.libc.prctl(36, 1, 0, 0, 0) == 0, "cannot restore isolated fixture containment")
    return {"host_subreaper_unchanged": True, "private_guardian_complete": True}


def unrelated_child(world: model.World) -> dict[str, Any]:
    process = subprocess.Popen([sys.executable, str(model.HERE / "workload.py"), "witness",
                                str(world.root / "w"), "unrelated"], stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    witness = world.witness("unrelated")
    guardian = world.guardian()
    model.require(guardian.adopt(witness) is None, "guardian accepted unrelated host child")
    guardian.finish()
    model.require(not model.exited(witness) and process.poll() is None, "guardian retired or collected unrelated host child")
    signal.pidfd_send_signal(witness, signal.SIGKILL)
    world.until(lambda: model.exited(witness), "fixture's unrelated child exit")
    model.require(process.wait(timeout=0) == -signal.SIGKILL, "unrelated child status was stolen")
    return {"foreign_adoption_refused": True, "unrelated_child_alive_after_guardian_closure": True,
            "unrelated_status_collected_only_by_fixture": True}


def inherited_fds(world: model.World) -> dict[str, Any]:
    reader, writer = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        guardian = world.guardian()
        os.close(writer)
        writer = -1
        model.require(os.read(reader, 1) == b"", "helper retained an unrelated inherited writer")
        guardian.finish()
    finally:
        os.close(reader)
        if writer >= 0:
            os.close(writer)
    return {"inherited_host_descriptors_closed_before_ready": True}


def closed_stdio(world: model.World) -> dict[str, Any]:
    saved = [fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 3) for fd in (0, 1, 2)]
    try:
        for fd in (0, 1, 2):
            os.close(fd)
        guardian = world.guardian()
        model.require(guardian.control.fileno() >= 3, "native control endpoint reused a standard descriptor")
        if guardian.pidfd < 3:
            # Fixture restoration must not silently recycle a still-held pidfd.
            original = guardian.pidfd
            replacement = fcntl.fcntl(original, fcntl.F_DUPFD_CLOEXEC, 3)
            world.selector.unregister(original)
            world.all_fds.remove(original)
            os.close(original)
            guardian.pidfd = replacement
            world.all_fds.add(replacement)
            world.selector.register(replacement, model.selectors.EVENT_READ, guardian.observe_exit)
        guardian.finish()
    finally:
        for fd, saved_fd in enumerate(saved):
            os.dup2(saved_fd, fd)
            os.close(saved_fd)
    return {"closed_standard_descriptors_supported": True, "restoration_preserved_owned_descriptor_lifetimes": True}


CASES: dict[str, Callable[[model.World], dict[str, Any]]] = {
    "host-signal-policy-refusal": refused_policy,
    "host-child-signal-state": signal_state,
    "host-subreaper-unchanged": host_subreaper,
    "unrelated-host-child": unrelated_child,
    "close-inherited-host-descriptors": inherited_fds,
    "closed-standard-descriptors": closed_stdio,
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tmux", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--helper", type=Path)
    parser.add_argument("--case", choices=CASES)
    args = parser.parse_args()
    if args.case:
        model.require(args.helper is not None, "host case needs compiled helper")
        world = model.World(args.helper, args.tmux)
        start = time.monotonic()
        try:
            facts = CASES[args.case](world)
        finally:
            world.close()
        print(json.dumps({"case": args.case, "status": "PASS", "facts": facts,
                          "wall_seconds": time.monotonic() - start}))
        return
    output = args.output or Path(tempfile.mkdtemp(prefix="guardian-native-host-"))
    output.mkdir(exist_ok=True, parents=True)
    start = time.monotonic()
    subprocess.run([sys.executable, str(model.HERE / "probe_guardian.py"), "--tmux", str(args.tmux.resolve()),
                    "--output", str(output.resolve())], check=True)
    helper = output / "guardian-native.so"
    results = []
    for case in CASES:
        process = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--tmux", str(args.tmux.resolve()),
                                  "--helper", str(helper.resolve()), "--case", case], capture_output=True, text=True)
        (output / f"{case}.log").write_text(process.stdout + process.stderr)
        result = json.loads(process.stdout) if process.returncode == 0 else {"case": case, "status": "FAIL"}
        results.append(result)
        print(json.dumps(result), flush=True)
    receipt = {"scope": "native host state only; Haskell scope not executed", "results": results,
               "wall_seconds": time.monotonic() - start,
               "status": "PASS" if all(result["status"] == "PASS" for result in results) else "FAIL"}
    (output / "native-host-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    model.require(receipt["status"] == "PASS", "native host qualification failed")


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        traceback.print_exc()
        raise SystemExit(1) from None
