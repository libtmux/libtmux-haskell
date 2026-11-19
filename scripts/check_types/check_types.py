# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Check the public API's type contracts with ``ghc -fno-code``.

Each positive case under ``test/compile-pass`` must compile against the built
library. Each negative case under ``test/compile-fail`` must fail with one
specific GHC diagnostic, not merely fail.
"""

import json
import subprocess
import sys
import tempfile
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.append(str(Path(__file__).resolve().parents[1] / "bounded"))

from bounded import BUILD, QUICK, run

PLAN = Path("dist-newstyle/cache/plan.json")
PACKAGES = ("base", "text", "libtmux-haskell")


@dataclass(frozen=True)
class Rejection:
    """A source that must fail with a GHC error of ``code`` mentioning ``expected``."""

    source: str
    code: int
    expected: str


ACCEPTED = (
    "test/compile-pass/ValueApi.hs",
    "test/compile-pass/ObservationApi.hs",
    "test/compile-pass/QueryApi.hs",
    "test/compile-pass/MutationApi.hs",
    "test/compile-pass/CreationApi.hs",
)
REJECTED = (
    Rejection("test/compile-fail/DimensionLiteral.hs", 39999, "Num Dimension"),
    Rejection("test/compile-fail/MixedIndices.hs", 83865, "Expected: PaneIndex -> WindowIndex"),
    Rejection("test/compile-fail/MixedIds.hs", 83865, "Expected: PaneId -> WindowId"),
    Rejection(
        "test/compile-fail/FixtureOriginCoercion.hs",
        18872,
        "LibTmux.Snapshot.Fixture.FixtureOrigin",
    ),
    Rejection("test/compile-fail/QueryMixedRows.hs", 83865, "Expected: Q.Field Pane Integer"),
    Rejection("test/compile-fail/QueryWrongOperand.hs", 83865, "Bool"),
    Rejection("test/compile-fail/QueryBooleanNumber.hs", 83865, "Expected: Q.Field Pane Integer"),
    Rejection(
        "test/compile-fail/QueryNumericText.hs",
        83865,
        "Actual: Q.Field Pane LibTmux.Value.Dimension",
    ),
    Rejection("test/compile-fail/QueryExprCoercion.hs", 18872, "coerce"),
    Rejection("test/compile-fail/QuerySourceCoercion.hs", 18872, "coerce"),
    Rejection("test/compile-fail/MutationWrongEntity.hs", 83865, "WindowRef"),
    Rejection("test/compile-fail/ResizeWrongEntity.hs", 83865, "WindowRef"),
    Rejection("test/compile-fail/RecoveryFromUmbrella.hs", 76037, "inspectCleanup"),
    Rejection("test/compile-fail/CreationEmptyArgv.hs", 83865, "NonEmpty"),
    Rejection("test/compile-fail/CreationConstructor.hs", 1928, "CreatedSession"),
    Rejection("test/compile-fail/CreationEmptyPane.hs", 76037, "EmptyPane"),
)


class TypeCheckError(Exception):
    """A type-contract case did not behave as declared."""


def library_units(plan: Mapping[str, Any]) -> list[str]:
    """Pick the one library unit of each package GHC is allowed to see.

    >>> plan = {"install-plan": [
    ...     {"id": "base-4.22", "pkg-name": "base"},
    ...     {"id": "text-2.1", "pkg-name": "text", "component-name": "lib"},
    ...     {"id": "text-2.1-test", "pkg-name": "text", "component-name": "test:unit"},
    ...     {"id": "libtmux-haskell-0.1-inplace", "pkg-name": "libtmux-haskell"},
    ... ]}
    >>> library_units(plan)
    ['base-4.22', 'text-2.1', 'libtmux-haskell-0.1-inplace']
    """
    units = []
    for name in PACKAGES:
        matches = {
            item["id"]
            for item in plan["install-plan"]
            if item.get("pkg-name") == name and (item.get("component-name") or "lib") == "lib"
        }
        if len(matches) != 1:
            raise TypeCheckError(f"Expected one library unit for {name}")
        units.append(matches.pop())
    return units


def reports_error(output: str, code: int, expected: str) -> bool:
    """Whether GHC's JSON diagnostics hold an error with ``code`` that contains ``expected``.

    Lines that are not JSON diagnostics are ignored.

    >>> line = '{"severity": "Error", "code": 83865, "message": ["Expected: A", "Actual: B"]}'
    >>> reports_error("noise\\n" + line, 83865, "Expected: A Actual: B")
    True
    >>> reports_error(line, 39999, "Expected: A")
    False
    >>> reports_error(line.replace("Error", "Warning"), 83865, "Expected: A")
    False
    """
    for line in output.splitlines():
        try:
            diagnostic = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(diagnostic, dict):
            continue
        message = diagnostic.get("message")
        text = " ".join(map(str, message)) if isinstance(message, list) else ""
        if (
            diagnostic.get("severity") == "Error"
            and diagnostic.get("code") == code
            and expected in text
        ):
            return True
    return False


def compile_source(
    root: Path, units: list[str], scratch: Path, source: str, *, capture: bool
) -> subprocess.CompletedProcess[str]:
    """Typecheck ``source`` against the exact library units, without generating code."""
    command = [
        "cabal",
        "exec",
        "--offline",
        "-v0",
        "--",
        "ghc",
        "-v0",
        "-fno-code",
        "-fforce-recomp",
        "-XGHC2024",
        "-Wall",
        "-Werror",
        "-fdiagnostics-as-json",
        "-outputdir",
        str(scratch),
        "-hide-all-packages",
        *(argument for unit in units for argument in ("-package-id", unit)),
        source,
    ]
    if capture:
        return run(
            command,
            cwd=root,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=QUICK,
        )
    return run(command, cwd=root, check=False, text=True, timeout=QUICK)


def check_accepted(root: Path, units: list[str], scratch: Path, source: str) -> None:
    """Require ``source`` to compile."""
    if compile_source(root, units, scratch, source, capture=False).returncode:
        raise TypeCheckError(f"Compilation failed: {source}")


def check_rejected(root: Path, units: list[str], scratch: Path, case: Rejection) -> None:
    """Require ``case.source`` to fail with its declared diagnostic."""
    result = compile_source(root, units, scratch, case.source, capture=True)
    if result.returncode == 0:
        raise TypeCheckError(f"Unexpected compilation success: {case.source}")
    if not reports_error(result.stdout, case.code, case.expected):
        print(result.stdout, file=sys.stderr, end="")
        raise TypeCheckError(f"Missing intended type error: {case.source}")


def check(root: Path = ROOT) -> str:
    """Build the library, run every case and return the pass summary."""
    run(
        ["cabal", "build", "lib:libtmux-haskell", "--offline", "-v0"],
        cwd=root,
        check=True,
        timeout=BUILD,
    )
    units = library_units(json.loads((root / PLAN).read_text()))
    with tempfile.TemporaryDirectory(prefix="libtmux-haskell-types-") as directory:
        scratch = Path(directory)
        for source in ACCEPTED:
            check_accepted(root, units, scratch, source)
        for case in REJECTED:
            check_rejected(root, units, scratch, case)
    return (
        f"PASS: public API ({len(ACCEPTED)} positive and "
        f"{len(REJECTED)} intended negative compilation cases)"
    )


def main() -> None:
    """Run the checks and exit nonzero on the first failed case."""
    try:
        print(check())
    except (
        TypeCheckError,
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
        OSError,
        ValueError,
    ) as error:
        sys.exit(f"Type check failed: {error}")


if __name__ == "__main__":
    main()
