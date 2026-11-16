"""Benchmark driver checks that need neither tmux nor a Haskell build."""

import json
import sys
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path
from types import ModuleType
from typing import cast

import pytest

import capture_benchmark as bench

MEDIUM = ("medium", 5, 25, 75)


def sample(**changes: int) -> bench.Sample:
    """One CSV row for the medium graph on its first iteration."""
    row = {
        "iteration": 1,
        "elapsed_ns": 2_000,
        "capture_ns": 1_000,
        "sessions": 5,
        "windows": 25,
        "panes": 75,
        "window_links": 29,
        "pane_occurrences": 87,
    }
    return {**row, **changes}


def test_every_size_gives_each_window_a_pane() -> None:
    """The workload table splits its windows and panes without leaving a window empty."""
    for _, sessions, windows, panes in bench.SIZES:
        assert sum(bench.spread(windows, sessions)) == windows
        assert min(bench.spread(panes, windows)) >= 1


def test_the_harness_names_files_that_exist() -> None:
    """The sources hashed into every result still exist at their recorded paths."""
    assert [path for path in bench.HARNESS if not (bench.ROOT / path).is_file()] == []


def test_the_capture_graph_fixture_provides_the_daemon_and_exit_watch() -> None:
    """The driver relies on two names from the example runner's fixture."""
    fixture = bench.load_fixture()
    assert callable(fixture.fixture)
    assert callable(fixture.exited)


def test_samples_that_match_the_built_graph_are_accepted() -> None:
    """Medium graph: 3 panes per window, 3 extra links and 3 repeated appearances."""
    bench.check_samples([sample()], MEDIUM, bench.spread(75, 25), extra_links=3)


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"panes": 74}, "different graph"),
        ({"window_links": 28}, "different graph"),
        ({"pane_occurrences": 86}, "different graph"),
        ({"iteration": 2}, "different graph"),
        ({"capture_ns": 2_001}, "inconsistent timing"),
        ({"elapsed_ns": 0, "capture_ns": 0}, "inconsistent timing"),
    ],
)
def test_samples_from_a_different_graph_or_with_bad_timing_are_rejected(
    changes: dict[str, int], message: str
) -> None:
    """A sample that does not describe the built graph, or whose timing is impossible, fails."""
    with pytest.raises(RuntimeError, match=message):
        bench.check_samples([sample(**changes)], MEDIUM, bench.spread(75, 25), extra_links=3)


@pytest.mark.parametrize("samples", ["0", "51"])
def test_sample_count_is_validated_before_any_output_exists(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, samples: str
) -> None:
    """An out-of-range sample count exits before creating the output directory."""
    output = tmp_path / "results"
    monkeypatch.setattr(
        sys,
        "argv",
        ["capture_benchmark", "--tmux", "tmux", "--samples", samples, "--output", str(output)],
    )
    with pytest.raises(SystemExit) as exit_status:
        bench.main()
    assert exit_status.value.code == 2
    assert not output.exists()


def test_an_existing_output_directory_is_refused(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Results go to a new directory, so an earlier sweep is never overwritten."""
    monkeypatch.setattr(
        sys, "argv", ["capture_benchmark", "--tmux", "tmux", "--output", str(tmp_path)]
    )
    with pytest.raises(FileExistsError):
        bench.main()


FAKE_TMUX = """#!{python}
import os, sys
arguments = sys.argv[1:]
if arguments == ["-V"]:
    print("tmux 9.9")
    sys.exit(0)
verb = arguments[4]
with open(os.environ["FAKE_TMUX_LOG"], "a") as log:
    log.write(verb + "\\n")
if verb == "display-message":
    print("@0 %0")
elif verb != "link-window":
    print("@1 %1", os.getppid())
"""
FAKE_PROGRAM = """#!{python}
import sys
print("iteration,elapsed_ns,capture_ns,sessions,windows,panes,window_links,pane_occurrences")
for index in range(1, int(sys.argv[3]) + 1):
    print(index, 2000, 1000, 2, 3, 4, 7, 10, sep=",")
"""


class FakeFixture:
    """Stands in for the capture-graph fixture: one socket path and no daemon."""

    def __init__(self, tmp_path: Path) -> None:
        self.tmp_path = tmp_path
        self.exits: list[list[int]] = []

    @contextmanager
    def fixture(self, binary: str) -> Generator[tuple[str, dict[str, str]]]:
        """Yield a socket path and an environment that names the call log."""
        yield str(self.tmp_path / "socket"), {"FAKE_TMUX_LOG": str(self.tmp_path / "calls.log")}

    def exited(self, descriptors: list[int]) -> None:
        """Record the descriptors the driver asked to observe."""
        self.exits.append(descriptors)


def test_measure_builds_the_graph_runs_the_workload_and_records_the_case(tmp_path: Path) -> None:
    """Two sessions, three windows and four panes are built, linked, measured and reported."""
    binary = tmp_path / "tmux"
    binary.write_text(FAKE_TMUX.format(python=sys.executable))
    binary.chmod(0o700)
    program = tmp_path / "program"
    program.write_text(FAKE_PROGRAM.format(python=sys.executable))
    program.chmod(0o700)
    output = tmp_path / "out"
    output.mkdir()
    fixture = FakeFixture(tmp_path)

    report = bench.measure(
        cast(ModuleType, fixture),
        str(binary),
        1,
        "ab" * 32,
        str(program),
        ("tiny", 2, 3, 4),
        2,
        output,
    )

    verbs = (tmp_path / "calls.log").read_text().split()
    assert verbs == [
        *["display-message", "new-window", "new-session", "split-window"],
        *["link-window"] * 3,
    ]
    assert len(fixture.exits) == 3
    key = "tmux-9.9-1-" + "ab" * 6 + "-tiny"
    assert report["artifactKey"] == key
    assert (report["status"], report["sessions"], report["windows"], report["panes"]) == (
        "PASS",
        2,
        3,
        4,
    )
    assert report["captureMilliseconds"] == {"min": 0.002, "median": 0.002, "max": 0.002}
    assert report["ownedDaemonAndAllTrackedPanesExitObserved"] is True
    assert sorted(path.name for path in output.iterdir()) == [
        f"{key}.json",
        f"{key}.stderr",
        f"{key}.stdout",
    ]
    assert json.loads((output / f"{key}.json").read_text())["artifactKey"] == key
