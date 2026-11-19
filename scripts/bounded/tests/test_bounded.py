"""A time limit stops the command and every process it started."""

import ast
import os
import select
import subprocess
import sys
from pathlib import Path

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


STARTERS = {"run", "Popen", "check_output", "check_call", "call", "getoutput", "getstatusoutput"}


def direct_starts(source: str) -> list[int]:
    """Return the lines where ``source`` starts a process without the helper."""
    lines = []
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.ImportFrom) and node.module == "subprocess":
            lines.extend(node.lineno for alias in node.names if alias.name in STARTERS)
        elif (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and isinstance(node.func.value, ast.Name)
            and node.func.value.id == "subprocess"
            and node.func.attr in STARTERS
        ):
            lines.append(node.lineno)
    return lines


def test_the_scan_finds_a_direct_start() -> None:
    """The negative control: both spellings of a direct start are reported."""
    assert direct_starts("import subprocess\nsubprocess.run(['x'])\n") == [2]
    assert direct_starts("from subprocess import Popen, PIPE\n") == [1]
    assert direct_starts("import subprocess\nsubprocess.CompletedProcess\n") == []


def test_no_script_starts_a_process_without_the_helper() -> None:
    """A direct ``subprocess.run`` would leave a timed-out command's children running."""
    scripts = Path(__file__).resolve().parents[2]
    found = {
        f"{path.relative_to(scripts)}:{line}": None
        for path in sorted(scripts.glob("*/*.py"))
        if path.name != "bounded.py"
        for line in direct_starts(path.read_text())
    }
    assert not found, sorted(found)
