"""Type-contract orchestration, checked against a stand-in ``cabal`` that needs no GHC."""

import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

import check_types

FAKE_CABAL = """#!{python}
import json
import pathlib
import sys

arguments = sys.argv[1:]
if arguments[0] == "build":
    sys.exit(0)
assert arguments[0] == "exec", arguments
with pathlib.Path("calls.jsonl").open("a") as calls:
    calls.write(json.dumps(arguments) + "\\n")
outcome = json.loads(pathlib.Path("outcomes.json").read_text())[arguments[-1]]
sys.stdout.write(outcome["output"])
sys.exit(outcome["status"])
"""
UNITS = ["base-4.22", "text-2.1", "libtmux-haskell-0.0.1.0-inplace"]  # ids in the fixture plan


def diagnostic(code: int, message: str, severity: str = "Error") -> str:
    """One line of GHC's JSON diagnostic output."""
    return json.dumps({"severity": severity, "code": code, "message": [message]}) + "\n"


@dataclass
class Checkout:
    """A disposable checkout whose GHC outcomes are written by the test."""

    root: Path
    outcomes: dict[str, dict[str, Any]]

    def write(self) -> None:
        """Publish the outcomes to the stand-in ``cabal``."""
        (self.root / "outcomes.json").write_text(json.dumps(self.outcomes))

    def set_outcome(self, source: str, status: int, output: str) -> None:
        """Replace what compiling ``source`` does."""
        self.outcomes[source] = {"status": status, "output": output}
        self.write()

    def calls(self) -> list[list[str]]:
        """The ``cabal exec`` argument lists, in order."""
        lines = (self.root / "calls.jsonl").read_text().splitlines()
        return [json.loads(line) for line in lines]


@pytest.fixture
def checkout(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Checkout:
    """A checkout where every declared case behaves as intended."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    cabal = bin_dir / "cabal"
    cabal.write_text(FAKE_CABAL.format(python=sys.executable))
    cabal.chmod(0o700)
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
    root = tmp_path / "checkout"
    (root / "dist-newstyle/cache").mkdir(parents=True)
    plan = [
        {"id": "base-4.22", "pkg-name": "base"},
        {"id": "text-2.1", "pkg-name": "text", "component-name": "lib"},
        {"id": "text-2.1-tests", "pkg-name": "text", "component-name": "test:unit"},
        {"id": "libtmux-haskell-0.0.1.0-inplace", "pkg-name": "libtmux-haskell"},
    ]
    (root / "dist-newstyle/cache/plan.json").write_text(json.dumps({"install-plan": plan}))
    outcomes = {source: {"status": 0, "output": ""} for source in check_types.ACCEPTED}
    for case in check_types.REJECTED:
        code = case.code if isinstance(case.code, int) else case.code[0]
        output = "warning: noise\n" + diagnostic(code, case.expected)
        outcomes[case.source] = {"status": 1, "output": output}
    result = Checkout(root, outcomes)
    result.write()
    return result


def test_every_compile_case_file_is_declared() -> None:
    """A file under test/compile-pass or test/compile-fail cannot be left unchecked."""
    declared = {*check_types.ACCEPTED, *(case.source for case in check_types.REJECTED)}
    on_disk = {
        path.relative_to(check_types.ROOT).as_posix()
        for directory in ("compile-pass", "compile-fail")
        for path in (check_types.ROOT / "test" / directory).glob("*.hs")
    }
    assert declared == on_disk


@pytest.mark.parametrize(
    "plan",
    [
        {"install-plan": []},
        {
            "install-plan": [
                {"id": "base-1", "pkg-name": "base"},
                {"id": "base-2", "pkg-name": "base"},
            ]
        },
        {"install-plan": [{"id": "base-1", "pkg-name": "base", "component-name": "exe:base"}]},
    ],
)
def test_each_package_needs_exactly_one_library_unit(plan: dict[str, Any]) -> None:
    """Zero or several library units for a package fail instead of guessing."""
    with pytest.raises(check_types.TypeCheckError, match="Expected one library unit for base"):
        check_types.library_units(plan)


def test_all_cases_run_against_exactly_the_selected_units(checkout: Checkout) -> None:
    """Every case compiles with the three library units and nothing else."""
    message = check_types.check(checkout.root)
    assert message == "PASS: public API (6 positive and 18 intended negative compilation cases)"
    calls = checkout.calls()
    assert [call[-1] for call in calls] == [
        *check_types.ACCEPTED,
        *(case.source for case in check_types.REJECTED),
    ]
    for call in calls:
        packages = [call[index + 1] for index, word in enumerate(call) if word == "-package-id"]
        assert packages == UNITS
        assert {"-hide-all-packages", "-fno-code", "-Werror"} <= set(call)


def test_a_positive_case_that_fails_to_compile_stops_the_check(checkout: Checkout) -> None:
    """A passing case that stops compiling is a failure."""
    checkout.set_outcome(check_types.ACCEPTED[1], 1, "error")
    with pytest.raises(check_types.TypeCheckError, match=r"Compilation failed: .*ObservationApi"):
        check_types.check(checkout.root)


def test_a_negative_case_that_compiles_is_rejected(checkout: Checkout) -> None:
    """A case meant to fail must not compile."""
    case = check_types.REJECTED[0]
    checkout.set_outcome(case.source, 0, "")
    with pytest.raises(check_types.TypeCheckError, match="Unexpected compilation success"):
        check_types.check(checkout.root)


@pytest.mark.parametrize(
    "output",
    [
        diagnostic(39999, "Some other message"),
        diagnostic(12345, "Num Dimension"),
        diagnostic(39999, "Num Dimension", severity="Warning"),
        "error: Num Dimension, but not a JSON diagnostic\n",
    ],
)
def test_a_negative_case_must_fail_for_its_intended_reason(
    checkout: Checkout, output: str, capsys: pytest.CaptureFixture[str]
) -> None:
    """Failing with a different error, severity or format is not the intended failure."""
    case = check_types.REJECTED[0]
    checkout.set_outcome(case.source, 1, output)
    with pytest.raises(check_types.TypeCheckError, match="Missing intended type error"):
        check_types.check(checkout.root)
    assert output in capsys.readouterr().err


@pytest.mark.parametrize("capture", [False, True])
def test_each_compilation_has_a_time_limit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capture: bool
) -> None:
    """A GHC run that never ends fails with its command instead of the job's time limit."""
    seen: list[object] = []

    def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        seen.append(kwargs.get("timeout"))
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(check_types, "run", run)
    check_types.compile_source(tmp_path, UNITS, tmp_path, "Case.hs", capture=capture)
    assert seen == [check_types.QUICK]


def test_the_library_build_has_a_time_limit(monkeypatch: pytest.MonkeyPatch) -> None:
    """The ``cabal build`` ahead of the cases is bounded, and a timeout is a reported failure."""
    seen: list[object] = []

    def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        seen.append(kwargs.get("timeout"))
        raise subprocess.TimeoutExpired(command, 1)

    monkeypatch.setattr(check_types, "run", run)
    with pytest.raises(SystemExit, match="timed out"):
        check_types.main()
    assert seen == [check_types.BUILD]


@pytest.mark.parametrize(("code", "accepted"), [(61948, True), (87110, True), (83865, False)])
def test_retired_module_diagnostics_depend_on_hidden_packages(code: int, accepted: bool) -> None:
    """GHC reports absence differently when an older hidden package has the module."""
    assert (
        check_types.reports_error(
            diagnostic(code, "LibTmux.Query.Pane"), (61948, 87110), "LibTmux.Query.Pane"
        )
        is accepted
    )
