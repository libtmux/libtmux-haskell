# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Measure public capture on small, medium and large owned tmux graphs."""

import argparse
import csv
import hashlib
import io
import json
import os
import platform
import shutil
import statistics
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.append(str(Path(__file__).resolve().parents[1] / "bounded"))

import bounded
from bounded import BUILD, QUICK

type Size = tuple[str, int, int, int]
type Sample = dict[str, int]

CASE_BUDGET = 120
SIZES: list[Size] = [("small", 1, 3, 6), ("medium", 5, 25, 75), ("large", 15, 80, 250)]
HARNESS = ["bench/Capture.hs", "scripts/capture_benchmark/capture_benchmark.py"]


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


def check_samples(rows: list[Sample], size: Size) -> None:
    """Require every sample to observe the graph the fixture built, with sane timings."""
    _, session_count, window_count, pane_count = size
    pane_counts = spread(pane_count, window_count)
    extra_links = min(window_count, 3) if session_count > 1 else 0
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
        if (
            not 0 < row["capture_ns"] <= row["elapsed_ns"]
            or row["haskell_cpu_ps"] < 0
            or not 0 < row["setup_ns"] == rows[0]["setup_ns"]
        ):
            raise RuntimeError("capture benchmark returned inconsistent timing")


def run_workload(
    program: str, binary: str, size: Size, samples: int, key: str, output: Path
) -> list[Sample]:
    """Run one Haskell-owned graph and keep its raw output."""
    _, sessions, windows, panes = size
    result = bounded.run(
        [
            program,
            binary,
            str(sessions),
            str(windows),
            str(panes),
            str(samples),
            "+RTS",
            "-N1",
            "-RTS",
        ],
        capture_output=True,
        timeout=CASE_BUDGET,
    )
    (output / f"{key}.stdout").write_bytes(result.stdout)
    (output / f"{key}.stderr").write_bytes(result.stderr)
    result.check_returncode()
    if result.stderr:
        raise RuntimeError("capture benchmark wrote stderr")
    return parse_samples(result.stdout, samples)


def measure(
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
    version = bounded.output([binary, "-V"], timeout=QUICK).strip()
    key = f"{version.replace(' ', '-')}-{binary_index}-{binary_hash[:12]}-{name}"
    started = time.monotonic()
    before = host_state()
    rows = run_workload(program, binary, size, samples, key, output)
    check_samples(rows, size)
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
        "setupSeconds": round(rows[0]["setup_ns"] / 1_000_000_000, 3),
        "caseSeconds": round(time.monotonic() - started, 3),
        "captureMilliseconds": {
            "min": min(elapsed),
            "median": statistics.median(elapsed),
            "max": max(elapsed),
        },
        "defaultTimeoutSeconds": 2,
        "ownedScopeClosed": True,
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
        bounded.run(
            [git, "rev-parse", "--show-toplevel"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
            timeout=QUICK,
        )
        if git
        else None
    )
    if not owner or owner.returncode or Path(owner.stdout.strip()).resolve() != ROOT:
        git = None
    revision = (
        bounded.run(
            [git, "rev-parse", "HEAD"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
            timeout=QUICK,
        )
        if git
        else None
    )
    patch = (
        bounded.run(
            [git, "diff", "--binary", "HEAD"],
            cwd=ROOT,
            capture_output=True,
            check=False,
            timeout=QUICK,
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
        "ghc": bounded.output(["ghc", "--numeric-version"], timeout=QUICK).strip(),
        "cabal": bounded.output(["cabal", "--numeric-version"], timeout=QUICK).strip(),
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
    bounded.run(
        ["cabal", "build", "bench:capture", "--offline"], cwd=ROOT, check=True, timeout=BUILD
    )
    program = bounded.output(
        ["cabal", "list-bin", "bench:capture", "--offline", "-v0"],
        cwd=ROOT,
        timeout=QUICK,
    ).strip()
    if not Path(program).is_file():
        args.output.rmdir()
        parser.exit(1, "Cabal returned no capture benchmark executable\n")
    reports = []
    for binary_index, candidate in enumerate(args.tmux, 1):
        binary = shutil.which(candidate)
        if binary is None:
            raise RuntimeError("benchmark tmux executable was not found")
        binary_hash = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
        for size in SIZES:
            reports.append(
                measure(
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
