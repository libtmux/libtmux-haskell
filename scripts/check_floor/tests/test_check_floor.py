from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

import check_floor


def test_environment_drops_endpoint_selectors(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    for key in ["TMUX", "TMUX_PANE", "LIBTMUX_SOCKET", "LIBTMUX_SOCKET_PATH"]:
        monkeypatch.setenv(key, "unowned")
    env = check_floor.environment(tmp_path)
    assert not {"TMUX", "TMUX_PANE", "LIBTMUX_SOCKET", "LIBTMUX_SOCKET_PATH"} & env.keys()
    assert env["TMUX_TMPDIR"] == env["LIBTMUX_TEST_SANDBOX"] == str(tmp_path)


def test_hook_observation_requires_an_error_path(monkeypatch: pytest.MonkeyPatch) -> None:
    replies = iter(
        [
            subprocess.CompletedProcess([], 1, b"", b"invalid option: libtmux-floor-0\n"),
            subprocess.CompletedProcess([], 1, b"", b"invalid option: libtmux-floor-1\n"),
        ]
    )
    monkeypatch.setattr(check_floor, "run", lambda *_: next(replies))
    assert check_floor.hook_marker([], {}) == b"invalid option: libtmux-floor-0\n"
    with pytest.raises(RuntimeError, match="ran a configured hook"):
        check_floor.hook_marker([], {})


def test_retirement_requires_kernel_no_children(monkeypatch: pytest.MonkeyPatch) -> None:
    owned = check_floor.Children()
    observations: list[object] = [None, object(), ChildProcessError()]
    collected: list[bool] = []
    waited: list[bool] = []

    def collect() -> None:
        collected.append(True)

    def wait(which: int, pid: int, flags: int) -> object:
        assert (which, pid, flags) == (os.P_ALL, 0, os.WEXITED | os.WNOHANG)
        waited.append(True)
        value = observations.pop(0)
        if isinstance(value, ChildProcessError):
            raise value
        return value

    monkeypatch.setattr(owned, "collect", collect)
    monkeypatch.setattr(check_floor.os, "waitid", wait)
    owned.retire()
    assert len(collected) == len(waited) == 3


def test_empty_snapshots_still_obey_the_retirement_deadline(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    owned = check_floor.Children()
    ticks = iter([0.0, 2.0])
    monkeypatch.setattr(owned, "collect", lambda: None)
    monkeypatch.setattr(check_floor.os, "waitid", lambda *_: None)
    monkeypatch.setattr(check_floor.time, "monotonic", lambda: next(ticks))
    with pytest.raises(RuntimeError, match="retained an owned child"):
        owned.retire()


@pytest.mark.parametrize("stream", ["stdout", "stderr"])
def test_command_output_is_bounded(monkeypatch: pytest.MonkeyPatch, stream: str) -> None:
    def emit(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[bytes]:
        fd = kwargs[stream]
        assert isinstance(fd, int)
        os.write(fd, b"x" * (65536 + 1))
        return subprocess.CompletedProcess(command, 0, b"", b"")

    monkeypatch.setattr(check_floor, "bounded_run", emit)
    with pytest.raises(RuntimeError, match="output limit"):
        check_floor.run(["fixture-command"], {})
