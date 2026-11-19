"""A time limit stops the command and every process it started."""

import ast
import os
import select
import subprocess
import sys
from pathlib import Path

import pytest

import bounded

PARENT = """
import os, subprocess, sys
witness, gate = map(int, sys.argv[1:3])
subprocess.Popen(
    [sys.executable, "-c", "import os, sys; os.read(int(sys.argv[1]), 1)", str(gate)],
    pass_fds=[witness, gate], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
sys.stdout.buffer.write(b"out\\r\\n")
sys.stdout.flush()
sys.stderr.buffer.write(b"err\\r\\n")
sys.stderr.flush()
if sys.argv[3] == "fail":
    raise SystemExit(3)
os.read(gate, 1)
"""


@pytest.mark.parametrize(
    ("mode", "error"),
    [("block", subprocess.TimeoutExpired), ("fail", subprocess.CalledProcessError)],
)
def test_a_command_error_stops_the_process_group(mode: str, error: type[Exception]) -> None:
    """Both processes hold the witness open until they exit."""
    witness, writer = os.pipe()
    gate, release = os.pipe()
    with (
        os.fdopen(witness, "rb") as retired,
        os.fdopen(writer, "wb") as parent_witness,
        os.fdopen(gate, "rb"),
        os.fdopen(release, "wb"),
    ):
        with pytest.raises(error) as failure:
            bounded.run(
                [sys.executable, "-c", PARENT, str(writer), str(gate), mode],
                timeout=0.5,
                check=True,
                capture_output=True,
                text=True,
                pass_fds=[writer, gate],
            )
        parent_witness.close()
        ready, _, _ = select.select([retired], [], [], 0.25)
        assert ready, "a child of the failed command is still running"
        assert retired.read(1) == b""
        problem = failure.value
        if isinstance(problem, subprocess.TimeoutExpired):
            assert (problem.output, problem.stderr) == (b"out\r\n", b"err\r\n")
        else:
            assert isinstance(problem, subprocess.CalledProcessError)
            assert (problem.returncode, problem.output, problem.stderr) == (3, "out\n", "err\n")


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
