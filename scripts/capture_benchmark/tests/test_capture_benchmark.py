"""Benchmark driver checks that need neither tmux nor a Haskell build."""

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
