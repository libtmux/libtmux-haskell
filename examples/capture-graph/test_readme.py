"""Run the README sequence after Cabal builds the example executables."""

import subprocess
from pathlib import Path

import pytest

from run import fixture

ROOT = Path(__file__).resolve().parents[2]
PROGRAMS = ("capture-graph", "query-graph", "mutate-graph", "create-session")


@pytest.fixture(scope="session")
def readme_programs() -> dict[str, str]:
    programs = {}
    for name in PROGRAMS:
        path = subprocess.check_output(
            ["cabal", "list-bin", "exe:" + name, "--offline"], cwd=ROOT, text=True
        ).strip()
        assert Path(path).is_file(), "build the README executables before this check"
        programs[name] = path
    return programs


def test_readme_examples_share_one_server(
    tmux_binary: str, readme_programs: dict[str, str]
) -> None:
    with fixture(tmux_binary, expected_panes=1) as (socket, environment):
        for name, program in readme_programs.items():
            result = subprocess.run(
                [program, socket, tmux_binary],
                env=environment,
                capture_output=True,
                text=True,
                timeout=1,
                check=False,
            )
            assert result.returncode == 0, result.stderr
            assert result.stderr == ""
            assert result.stdout == (ROOT / "examples" / name / "expected.stdout").read_text()
