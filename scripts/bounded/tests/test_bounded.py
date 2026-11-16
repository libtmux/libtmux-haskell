"""A time limit stops the command and every process it started."""

import os
import select
import subprocess
import sys

import pytest

import bounded

# Starts a sleeping child that inherits the descriptor named in argv, then sleeps itself.
PARENT = """
import subprocess, sys, time
inherited = int(sys.argv[1])
subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], pass_fds=[inherited])
time.sleep(60)
"""


def test_a_timeout_stops_the_children_of_the_command() -> None:
    """Both processes hold the pipe's write end; it reaches end-of-file only if both die."""
    reader, writer = os.pipe()
    try:
        with pytest.raises(subprocess.TimeoutExpired):
            bounded.run([sys.executable, "-c", PARENT, str(writer)], timeout=0.5, pass_fds=[writer])
        os.close(writer)
        ready, _, _ = select.select([reader], [], [], 5)
        assert ready, "a child of the timed-out command is still running"
        assert os.read(reader, 1) == b""
    finally:
        os.close(reader)


def test_a_finished_command_returns_its_output_and_status() -> None:
    result = bounded.run(
        [sys.executable, "-c", "print('out')"],
        timeout=bounded.QUICK,
        capture_output=True,
        text=True,
    )
    assert (result.returncode, result.stdout) == (0, "out\n")
    assert (
        bounded.output([sys.executable, "-c", "print('text')"], timeout=bounded.QUICK) == "text\n"
    )


def test_check_raises_for_a_failing_command() -> None:
    with pytest.raises(subprocess.CalledProcessError):
        bounded.run(
            [sys.executable, "-c", "raise SystemExit(3)"], timeout=bounded.QUICK, check=True
        )
