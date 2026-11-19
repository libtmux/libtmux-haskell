"""Benchmark driver checks that need neither tmux nor a Haskell build."""

import json
import sys
from pathlib import Path

import pytest

import capture_benchmark as bench

MEDIUM = ("medium", 5, 25, 75)


def sample(**changes: int) -> bench.Sample:
    """One CSV row for the medium graph on its first iteration."""
    row = {
        "iteration": 1,
        "elapsed_ns": 2_000,
        "capture_ns": 1_000,
        "haskell_cpu_ps": 80_000,
        "setup_ns": 90_000_000,
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


def test_samples_that_match_the_built_graph_are_accepted() -> None:
    """Medium graph: 3 panes per window, 3 extra links and 3 repeated appearances."""
    bench.check_samples([sample()], MEDIUM)


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
        bench.check_samples([sample(**changes)], MEDIUM)


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
import sys
assert sys.argv[1:] == ["-V"], sys.argv
print("tmux 9.9")
"""
FAKE_PROGRAM = """#!{python}
from pathlib import Path
import sys
assert Path(sys.argv[1]).name == "tmux", sys.argv
sessions, windows, panes, samples = map(int, sys.argv[2:6])
assert sys.argv[6:] == ["+RTS", "-N1", "-RTS"], sys.argv
print("iteration,elapsed_ns,haskell_cpu_ps,capture_ns,sessions,windows,panes,window_links,pane_occurrences,setup_ns")
for index in range(1, samples + 1):
    print(index, 2000, 80000, 1000, sessions, windows, panes, 7, 10, 90000000, sep=",")
"""


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
    report = bench.measure(
        str(binary),
        1,
        "ab" * 32,
        str(program),
        ("tiny", 2, 3, 4),
        2,
        output,
    )

    key = "tmux-9.9-1-" + "ab" * 6 + "-tiny"
    assert report["artifactKey"] == key
    assert (report["status"], report["sessions"], report["windows"], report["panes"]) == (
        "PASS",
        2,
        3,
        4,
    )
    assert report["captureMilliseconds"] == {"min": 0.002, "median": 0.002, "max": 0.002}
    assert report["setupSeconds"] == 0.09
    assert report["ownedScopeClosed"] is True
    assert sorted(path.name for path in output.iterdir()) == [
        f"{key}.json",
        f"{key}.stderr",
        f"{key}.stdout",
    ]
    assert json.loads((output / f"{key}.json").read_text())["artifactKey"] == key


def test_the_driver_prepares_the_benchmark_before_looking_for_its_executable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """The driver builds once and fails cleanly if Cabal supplies no executable."""
    output = tmp_path / "results"
    commands = []
    monkeypatch.setattr(bench.bounded, "run", lambda args, **kwargs: commands.append(args))
    monkeypatch.setattr(bench.bounded, "output", lambda *_, **__: str(tmp_path / "none"))
    monkeypatch.setattr(
        sys, "argv", ["capture_benchmark", "--tmux", "tmux", "--output", str(output)]
    )
    with pytest.raises(SystemExit) as exit_status:
        bench.main()
    assert exit_status.value.code == 1
    assert commands == [["cabal", "build", "bench:capture", "--offline"]]
    assert "Cabal returned no capture benchmark executable" in capsys.readouterr().err
    assert not output.exists()
