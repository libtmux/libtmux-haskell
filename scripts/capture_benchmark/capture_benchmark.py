# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Measure public capture on small, medium and large owned tmux graphs."""

import argparse
import csv
import hashlib
import importlib.util
import io
import json
import os
import platform
import shutil
import statistics
import subprocess
import time
from contextlib import ExitStack
from pathlib import Path
from types import ModuleType
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "examples/capture-graph/run.py"

type Size = tuple[str, int, int, int]
type Sample = dict[str, int]

SIZES: list[Size] = [("small", 1, 3, 6), ("medium", 5, 25, 75), ("large", 15, 80, 250)]
HARNESS = [
    "bench/Capture.hs",
    "scripts/capture_benchmark/capture_benchmark.py",
    "examples/capture-graph/run.py",
]


def load_fixture(source: Path = SOURCE) -> ModuleType:
    """Import the capture-graph example's daemon fixture by path."""
    spec = importlib.util.spec_from_file_location("capture_fixture", source)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load the benchmark fixture from {source}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def spread(total: int, parts: int) -> list[int]:
    """Split ``total`` into ``parts`` counts that differ by at most one, largest first.

    >>> spread(25, 5)
    [5, 5, 5, 5, 5]
    >>> spread(80, 15)
    [6, 6, 6, 6, 6, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5]
    >>> sum(spread(250, 80))
    250
    """
    return [total // parts + (index < total % parts) for index in range(parts)]


def host_state() -> dict[str, Any]:
    """Record load, memory and free disk, for judging how noisy a measurement was."""
    memory = {
        line.split(":", 1)[0]: int(line.split()[1])
        for line in Path("/proc/meminfo").read_text().splitlines()
        if line.startswith(("MemTotal:", "MemAvailable:", "SwapFree:"))
    }
    disk = os.statvfs(ROOT)
    return {
        "loadAverage": os.getloadavg(),
        "memoryKiB": memory,
        "freeDiskBytes": disk.f_bavail * disk.f_frsize,
    }


def parse_samples(stdout: bytes, samples: int) -> list[Sample]:
    """Parse the benchmark's CSV rows and require one per requested sample.

    >>> parse_samples(b"iteration,elapsed_ns\\n1,40\\n2,50\\n", 2)
    [{'iteration': 1, 'elapsed_ns': 40}, {'iteration': 2, 'elapsed_ns': 50}]
    >>> parse_samples(b"iteration,elapsed_ns\\n1,40\\n", 2)
    Traceback (most recent call last):
    RuntimeError: capture benchmark returned the wrong sample count
    """
    rows = [
        {field: int(value) for field, value in row.items()}
        for row in csv.DictReader(io.StringIO(stdout.decode("ascii")))
    ]
    if len(rows) != samples:
        raise RuntimeError("capture benchmark returned the wrong sample count")
    return rows


def check_samples(rows: list[Sample], size: Size, pane_counts: list[int], extra_links: int) -> None:
    """Require every sample to observe the graph the fixture built, with sane timings."""
    _, session_count, window_count, pane_count = size
    for index, row in enumerate(rows, 1):
        occurrences = pane_count + pane_counts[0] + (sum(pane_counts[:3]) if extra_links else 0)
        observed = (
            row["iteration"],
            row["sessions"],
            row["windows"],
            row["panes"],
            row["window_links"],
            row["pane_occurrences"],
        )
        expected = (
            index,
            session_count,
            window_count,
            pane_count,
            window_count + 1 + extra_links,
            occurrences,
        )
        if observed != expected:
            raise RuntimeError(f"capture benchmark observed a different graph: {row}")
        if row["capture_ns"] > row["elapsed_ns"] or row["elapsed_ns"] <= 0:
            raise RuntimeError("capture benchmark returned inconsistent timing")


def measure(
    fixture: ModuleType,
    binary: str,
    binary_index: int,
    binary_hash: str,
    program: str,
    size: Size,
    samples: int,
    output: Path,
) -> dict[str, Any]:
    """Build one owned graph, run the Haskell benchmark against it and record the result."""
    name, session_count, window_count, pane_count = size
    version = subprocess.check_output([binary, "-V"], text=True).strip()
    key = f"{version.replace(' ', '-')}-{binary_index}-{binary_hash[:12]}-{name}"
    started = time.monotonic()
    before = host_state()
    with ExitStack() as panes, fixture.fixture(binary) as (socket, environment):

        def tmux(*arguments: str) -> list[str]:
            if time.monotonic() - started > 120:
                raise RuntimeError("benchmark fixture exceeded its two-minute case budget")
            result = subprocess.run(
                [binary, "-u", "-N", "-S", socket, *arguments],
                env=environment,
                capture_output=True,
                check=True,
                timeout=1,
            )
            if result.stderr:
                raise RuntimeError(f"fixture command wrote stderr: {result.stderr!r}")
            return result.stdout.decode("ascii").strip().split()

        def created(*arguments: str) -> tuple[str, str]:
            fields = tmux(*arguments)
            if len(fields) != 3 or not fields[0].startswith("@") or not fields[1].startswith("%"):
                raise RuntimeError("invalid benchmark window/pane receipt")
            descriptor = os.pidfd_open(int(fields[2]))
            panes.callback(os.close, descriptor)
            panes.callback(fixture.exited, [descriptor])
            return fields[0], fields[1]

        first = tmux("display-message", "-p", "-t", "demo:0", "-F", "#{window_id} #{pane_id}")
        if len(first) != 2:
            raise RuntimeError("missing initial benchmark window")
        windows = [(first[0], first[1])]
        sessions = ["demo"]
        counts = spread(window_count, session_count)
        format_ = "#{window_id} #{pane_id} #{pane_pid}"
        for index, count in enumerate(counts):
            if index:
                session = "bench-" + str(index)
                sessions.append(session)
                windows.append(
                    created(
                        "new-session",
                        "-d",
                        "-P",
                        "-F",
                        format_,
                        "-s",
                        session,
                        "-x",
                        "200",
                        "-y",
                        "60",
                        "/bin/cat",
                        "-",
                    )
                )
            else:
                session = "demo"
            for _ in range(count - 1):
                windows.append(
                    created(
                        "new-window",
                        "-d",
                        "-P",
                        "-F",
                        format_,
                        "-t",
                        session + ":",
                        "/bin/cat",
                        "-",
                    )
                )
        pane_counts = spread(pane_count, window_count)
        for (_, pane), count in zip(windows, pane_counts, strict=True):
            for _ in range(count - 1):
                created(
                    "split-window", "-h", "-d", "-P", "-F", format_, "-t", pane, "/bin/cat", "-"
                )
        extra_links = 0
        if session_count > 1:
            for index, (window, _) in enumerate(windows[:3]):
                tmux(
                    "link-window",
                    "-d",
                    "-s",
                    window,
                    "-t",
                    sessions[(index + 1) % session_count] + ":" + str(100 + index),
                )
                extra_links += 1
        setup_seconds = time.monotonic() - started
        result = subprocess.run(
            [program, socket, binary, str(samples), "+RTS", "-N1", "-RTS"],
            env=environment,
            capture_output=True,
            check=False,
            timeout=min(120, 3 * samples + 5),
        )
        (output / f"{key}.stdout").write_bytes(result.stdout)
        (output / f"{key}.stderr").write_bytes(result.stderr)
        result.check_returncode()
        if result.stderr:
            raise RuntimeError("capture benchmark wrote stderr")
        rows = parse_samples(result.stdout, samples)
        check_samples(rows, size, pane_counts, extra_links)
    # The fixture daemon and initial pane have exited before the remaining
    # pane pidfds are observed by the outer ownership scope.
    elapsed = [row["elapsed_ns"] / 1_000_000 for row in rows]
    report = {
        "status": "PASS",
        "version": version,
        "size": name,
        "samples": rows,
        "artifactKey": key,
        "tmuxBinarySha256": binary_hash,
        "sessions": session_count,
        "windows": window_count,
        "panes": pane_count,
        "setupSeconds": round(setup_seconds, 3),
        "caseSeconds": round(time.monotonic() - started, 3),
        "captureMilliseconds": {
            "min": min(elapsed),
            "median": statistics.median(elapsed),
            "max": max(elapsed),
        },
        "defaultTimeoutSeconds": 2,
        "ownedDaemonAndAllTrackedPanesExitObserved": True,
        "hostBefore": before,
        "hostAfter": host_state(),
    }
    (output / f"{key}.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report["captureMilliseconds"]}), flush=True)
    return report


def source_identity(program: str, reports: list[dict[str, Any]]) -> dict[str, Any]:
    """Identify the sources, executable and toolchain a sweep measured."""
    git = shutil.which("git")
    owner = (
        subprocess.run(
            [git, "rev-parse", "--show-toplevel"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        if git
        else None
    )
    if not owner or owner.returncode or Path(owner.stdout.strip()).resolve() != ROOT:
        git = None
    revision = (
        subprocess.run(
            [git, "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=False
        )
        if git
        else None
    )
    patch = (
        subprocess.run(
            [git, "diff", "--binary", "HEAD"], cwd=ROOT, capture_output=True, check=False
        )
        if git
        else None
    )
    sources = {
        str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
        for directory in ["src", "internal", "cbits"]
        for path in sorted((ROOT / directory).rglob("*"))
        if path.is_file() and path.suffix in {".hs", ".c", ".h"}
    }
    return {
        "revision": revision.stdout.strip() if revision and revision.returncode == 0 else None,
        "trackedPatchSha256": (
            hashlib.sha256(patch.stdout).hexdigest() if patch and patch.returncode == 0 else None
        ),
        "librarySourceSha256": sources,
        "benchmarkExecutableSha256": hashlib.sha256(Path(program).read_bytes()).hexdigest(),
        "harnessSha256": {
            path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in HARNESS
        },
        "ghc": subprocess.check_output(["ghc", "--numeric-version"], text=True).strip(),
        "cabal": subprocess.check_output(["cabal", "--numeric-version"], text=True).strip(),
        "platform": platform.platform(),
        "cases": reports,
        "limits": (
            "Small fixed sample count on a shared host; Haskell CPU excludes daemon/client CPU; "
            "no allocation or concurrency qualification."
        ),
    }


def main() -> None:
    """Run every size against every selected tmux binary and write ``result.json``."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--tmux",
        action="append",
        required=True,
        help="select a binary; repeat for a release sweep",
    )
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument(
        "--output",
        type=Path,
        required=True,
        help="new directory for raw samples and host context",
    )
    args = parser.parse_args()
    if not 1 <= args.samples <= 50:
        parser.error("samples must be between 1 and 50")
    args.output.mkdir(parents=True, exist_ok=False)
    program = subprocess.check_output(
        ["cabal", "list-bin", "bench:capture", "--offline", "-v0"], cwd=ROOT, text=True
    ).strip()
    fixture = load_fixture()
    reports = []
    for binary_index, candidate in enumerate(args.tmux, 1):
        binary = shutil.which(candidate)
        if binary is None:
            raise RuntimeError("benchmark tmux executable was not found")
        binary_hash = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
        for size in SIZES:
            reports.append(
                measure(
                    fixture,
                    binary,
                    binary_index,
                    binary_hash,
                    program,
                    size,
                    args.samples,
                    args.output,
                )
            )
    identity = source_identity(program, reports)
    (args.output / "result.json").write_text(json.dumps(identity, indent=2) + "\n")


if __name__ == "__main__":
    main()
