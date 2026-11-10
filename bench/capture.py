"""Measure public capture on small, medium and large owned tmux graphs."""

import argparse
from contextlib import ExitStack
import csv
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "examples/capture-graph/run.py"
SPEC = importlib.util.spec_from_file_location("capture_fixture", SOURCE)
FIXTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURE)
SIZES = [("small", 1, 3, 6), ("medium", 5, 25, 75), ("large", 15, 80, 250)]


def host_state():
    memory = {line.split(":", 1)[0]: int(line.split()[1])
              for line in Path("/proc/meminfo").read_text().splitlines()
              if line.startswith(("MemTotal:", "MemAvailable:", "SwapFree:"))}
    disk = os.statvfs(ROOT)
    return {"loadAverage": os.getloadavg(), "memoryKiB": memory,
            "freeDiskBytes": disk.f_bavail * disk.f_frsize}


def measure(binary, binary_index, binary_hash, program, size, samples, output):
    name, session_count, window_count, pane_count = size
    version = subprocess.check_output([binary, "-V"], text=True).strip()
    key = f"{version.replace(' ', '-')}-{binary_index}-{binary_hash[:12]}-{name}"
    started = time.monotonic()
    before = host_state()
    with ExitStack() as panes:
        with FIXTURE.fixture(binary) as (socket, environment):
            def tmux(*arguments):
                if time.monotonic() - started > 120:
                    raise RuntimeError("benchmark fixture exceeded its two-minute case budget")
                result = subprocess.run([binary, "-u", "-N", "-S", socket, *arguments],
                                        env=environment, capture_output=True, check=True, timeout=1)
                if result.stderr:
                    raise RuntimeError(f"fixture command wrote stderr: {result.stderr!r}")
                return result.stdout.decode("ascii").strip().split()

            def created(*arguments):
                fields = tmux(*arguments)
                if len(fields) != 3 or not fields[0].startswith("@") or not fields[1].startswith("%"):
                    raise RuntimeError("invalid benchmark window/pane receipt")
                descriptor = os.pidfd_open(int(fields[2]))
                panes.callback(os.close, descriptor)
                panes.callback(FIXTURE.exited, [descriptor])
                return fields[0], fields[1]

            first = tmux("display-message", "-p", "-t", "demo:0", "-F", "#{window_id} #{pane_id}")
            if len(first) != 2:
                raise RuntimeError("missing initial benchmark window")
            windows = [(first[0], first[1])]
            sessions = ["demo"]
            counts = [window_count // session_count + (index < window_count % session_count)
                      for index in range(session_count)]
            format_ = "#{window_id} #{pane_id} #{pane_pid}"
            for index, count in enumerate(counts):
                if index:
                    session = "bench-" + str(index)
                    sessions.append(session)
                    windows.append(created("new-session", "-d", "-P", "-F", format_, "-s", session,
                                           "-x", "200", "-y", "60", "/bin/cat", "-"))
                else:
                    session = "demo"
                for _ in range(count - 1):
                    windows.append(created("new-window", "-d", "-P", "-F", format_,
                                           "-t", session + ":", "/bin/cat", "-"))
            pane_counts = [pane_count // window_count + (index < pane_count % window_count)
                           for index in range(window_count)]
            for (_, pane), count in zip(windows, pane_counts, strict=True):
                for _ in range(count - 1):
                    created("split-window", "-h", "-d", "-P", "-F", format_,
                            "-t", pane, "/bin/cat", "-")
            extra_links = 0
            if session_count > 1:
                for index, (window, _) in enumerate(windows[:3]):
                    tmux("link-window", "-d", "-s", window,
                         "-t", sessions[(index + 1) % session_count] + ":" + str(100 + index))
                    extra_links += 1
            setup_seconds = time.monotonic() - started
            result = subprocess.run([program, socket, binary, str(samples), "+RTS", "-N1", "-RTS"],
                                    env=environment, capture_output=True, timeout=min(120, 3 * samples + 5))
            (output / f"{key}.stdout").write_bytes(result.stdout)
            (output / f"{key}.stderr").write_bytes(result.stderr)
            result.check_returncode()
            if result.stderr:
                raise RuntimeError("capture benchmark wrote stderr")
            rows = [{field: int(value) for field, value in row.items()}
                    for row in csv.DictReader(io.StringIO(result.stdout.decode("ascii")))]
            if len(rows) != samples:
                raise RuntimeError("capture benchmark returned the wrong sample count")
            for index, row in enumerate(rows, 1):
                occurrences = pane_count + pane_counts[0] + (sum(pane_counts[:3]) if extra_links else 0)
                if (row["iteration"], row["sessions"], row["windows"], row["panes"],
                    row["window_links"], row["pane_occurrences"]) != (
                        index, session_count, window_count, pane_count,
                        window_count + 1 + extra_links, occurrences):
                    raise RuntimeError(f"capture benchmark observed a different graph: {row}")
                if row["capture_ns"] > row["elapsed_ns"] or row["elapsed_ns"] <= 0:
                    raise RuntimeError("capture benchmark returned inconsistent timing")
        # The fixture daemon and initial pane have exited before the remaining
        # pane pidfds are observed by the outer ownership scope.
    elapsed = [row["elapsed_ns"] / 1_000_000 for row in rows]
    report = {"status": "PASS", "version": version, "size": name, "samples": rows,
              "artifactKey": key, "tmuxBinarySha256": binary_hash,
              "sessions": session_count, "windows": window_count, "panes": pane_count,
              "setupSeconds": round(setup_seconds, 3), "caseSeconds": round(time.monotonic() - started, 3),
              "captureMilliseconds": {"min": min(elapsed), "median": statistics.median(elapsed), "max": max(elapsed)},
              "defaultTimeoutSeconds": 2, "ownedDaemonAndAllTrackedPanesExitObserved": True,
              "hostBefore": before, "hostAfter": host_state()}
    (output / f"{key}.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report["captureMilliseconds"]}), flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tmux", action="append", required=True, help="select a binary; repeat for a release sweep")
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--output", type=Path, required=True, help="new directory for raw samples and host context")
    args = parser.parse_args()
    if not 1 <= args.samples <= 50:
        parser.error("samples must be between 1 and 50")
    args.output.mkdir(parents=True, exist_ok=False)
    program = subprocess.check_output(["cabal", "list-bin", "bench:capture", "--offline", "-v0"],
                                      cwd=ROOT, text=True).strip()
    reports = []
    for binary_index, candidate in enumerate(args.tmux, 1):
        binary = shutil.which(candidate)
        if binary is None:
            raise RuntimeError("benchmark tmux executable was not found")
        binary_hash = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
        for size in SIZES:
            reports.append(measure(binary, binary_index, binary_hash, program, size, args.samples, args.output))
    git = shutil.which("git")
    owner = subprocess.run([git, "rev-parse", "--show-toplevel"], cwd=ROOT, capture_output=True, text=True) if git else None
    if not owner or owner.returncode or Path(owner.stdout.strip()).resolve() != ROOT:
        git = None
    revision = subprocess.run([git, "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True) if git else None
    patch = subprocess.run([git, "diff", "--binary", "HEAD"], cwd=ROOT, capture_output=True) if git else None
    sources = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
               for directory in ["src", "internal", "cbits"]
               for path in sorted((ROOT / directory).rglob("*"))
               if path.is_file() and path.suffix in {".hs", ".c", ".h"}}
    identity = {"revision": revision.stdout.strip() if revision and revision.returncode == 0 else None,
                "trackedPatchSha256": hashlib.sha256(patch.stdout).hexdigest() if patch and patch.returncode == 0 else None,
                "librarySourceSha256": sources,
                "benchmarkExecutableSha256": hashlib.sha256(Path(program).read_bytes()).hexdigest(),
                "harnessSha256": {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
                                   for path in ["bench/Capture.hs", "bench/capture.py", "examples/capture-graph/run.py"]},
                "ghc": subprocess.check_output(["ghc", "--numeric-version"], text=True).strip(),
                "cabal": subprocess.check_output(["cabal", "--numeric-version"], text=True).strip(),
                "platform": platform.platform(), "cases": reports,
                "limits": "Small fixed sample count on a shared host; Haskell CPU excludes daemon/client CPU; no allocation or concurrency qualification."}
    (args.output / "result.json").write_text(json.dumps(identity, indent=2) + "\n")


if __name__ == "__main__":
    main()
