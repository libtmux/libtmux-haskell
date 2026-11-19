"""Verify that documentation checks reject defects in disposable copies."""

import json
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

import check_docs


@dataclass
class Catalogue:
    """The example catalogue of a disposable checkout."""

    path: Path

    def load(self) -> dict[str, Any]:
        """Read the catalogue document."""
        return json.loads(self.path.read_text())

    def save(self, document: dict[str, Any]) -> None:
        """Replace the catalogue document."""
        self.path.write_text(json.dumps(document))

    @staticmethod
    def entry(document: dict[str, Any], name: str) -> dict[str, Any]:
        """Return one example entry by identifier."""
        return next(entry for entry in document["examples"] if entry["id"] == name)


@pytest.fixture
def root(tmp_path: Path) -> Path:
    """Copy the documents, and the files they link to, into a disposable checkout."""
    for directory in ["docs", ".github", "examples", "bench", "src", "internal", "scripts", "test"]:
        shutil.copytree(
            check_docs.ROOT / directory,
            tmp_path / directory,
            ignore=shutil.ignore_patterns("__pycache__", "dist-newstyle"),
        )
    for filename in [
        "README.md",
        "AGENTS.md",
        "LICENSE",
        ".tool-versions",
        "libtmux-haskell.cabal",
        "capabilities.json",
    ]:
        shutil.copy2(check_docs.ROOT / filename, tmp_path / filename)
    return tmp_path


@pytest.fixture
def catalogue(root: Path) -> Catalogue:
    """The catalogue inside the disposable checkout."""
    return Catalogue(root / "examples/catalogue.json")


def test_registered_programs_are_valid(root: Path) -> None:
    """The unmodified checkout reports every maintained program."""
    assert {entry["id"] for entry in check_docs.check(root)} == {
        "typed-values",
        "capture-graph",
        "offline-graph",
        "shared-runtime",
        "query-graph",
        "mutate-graph",
        "create-session",
        "managed-program",
        "paste-buffer",
        "resize-geometry",
        "configure-session",
        "watch-window",
    }


@pytest.mark.parametrize(
    ("guide", "markup"),
    [
        ("README.md", "\n```haskell\nmain = pure ()\n```\n"),
        ("docs/tasks/new.md", "~~~hs\nmain = pure ()\n~~~\n"),
    ],
)
def test_unregistered_haskell_fence_is_rejected(root: Path, guide: str, markup: str) -> None:
    """A Haskell fence outside a registered marker fails, including in nested guides."""
    path = root / guide
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as document:
        document.write(markup)
    with pytest.raises(ValueError, match="Unregistered Haskell"):
        check_docs.check(root)


def test_undeclared_source_is_rejected(root: Path) -> None:
    """A Haskell program missing from the catalogue fails."""
    (root / "examples/typed-values/Helper.hs").write_text("module Helper where\n")
    with pytest.raises(ValueError, match="Declared and discovered"):
        check_docs.check(root)


def test_stale_snippet_is_rejected(root: Path) -> None:
    """A displayed snippet that differs from its source file fails."""
    path = root / "docs/values.md"
    path.write_text(path.read_text().replace('parseWindowId "@17"', 'parseWindowId "@18"'))
    with pytest.raises(ValueError, match="differs from its source"):
        check_docs.check(root)


@pytest.mark.parametrize(
    "markup",
    [
        '<img src="docs/assets/missing.png" alt="Missing logo">',
        '<source srcset="docs/assets/missing.svg" type="image/svg+xml">',
    ],
)
def test_missing_html_logo_is_rejected(root: Path, markup: str) -> None:
    """A local image or source set that does not exist fails."""
    path = root / "README.md"
    path.write_text(path.read_text() + "\n" + markup + "\n")
    with pytest.raises(ValueError, match="Broken local link"):
        check_docs.check(root)


@pytest.mark.parametrize(
    ("key", "value", "message"),
    [
        ("examples", [], "No declared examples"),
        ("schema", "libtmux.examples/unknown", "Unknown example catalogue"),
    ],
)
def test_invalid_catalogue_is_rejected(
    root: Path, catalogue: Catalogue, key: str, value: object, message: str
) -> None:
    """An empty catalogue or an unknown schema fails."""
    document = catalogue.load()
    document[key] = value
    catalogue.save(document)
    with pytest.raises(ValueError, match=message):
        check_docs.check(root)


@pytest.mark.parametrize(
    ("key", "value"),
    [
        ("job", "missing-job"),
        ("step", "Missing step"),
        ("command", ["python3", "scripts/missing.py"]),
    ],
)
def test_stale_workflow_locator_is_rejected(
    root: Path, catalogue: Catalogue, key: str, value: object
) -> None:
    """A job, step or command that no longer exists in the workflow fails."""
    document = catalogue.load()
    next(iter(document["examples"]))["verification"][key] = value
    catalogue.save(document)
    with pytest.raises(ValueError, match="Example workflow"):
        check_docs.check(root)


@pytest.mark.parametrize(
    "command",
    [["python3", "runner.py"], ["cabal", "run", "--verbose=0", "another-program"]],
)
def test_documented_command_runs_its_own_executable(
    root: Path, catalogue: Catalogue, command: list[str]
) -> None:
    """Checkout and installed checks must run the same program."""
    document = catalogue.load()
    catalogue.entry(document, "capture-graph")["command"] = command
    catalogue.save(document)
    with pytest.raises(ValueError, match="command must run its declared Cabal executable"):
        check_docs.check(root)


def test_live_examples_find_the_selected_releases(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Cabal examples resolve each explicit tmux through its own PATH."""
    current = tmp_path / "current" / "tmux"
    floor = tmp_path / "floor" / "tmux"
    monkeypatch.setenv("LIBTMUX_TEST_TMUX", str(current))
    monkeypatch.setenv("LIBTMUX_TEST_FLOOR_TMUX", str(floor))
    monkeypatch.setenv("PATH", "/usr/bin")
    endpoints = check_docs.example_endpoints("3.3a")
    assert [(label, env["PATH"]) for label, env in endpoints if env] == [
        ("configured endpoint", f"{current.parent}:/usr/bin"),
        ("tmux 3.3a", f"{floor.parent}:/usr/bin"),
    ]
    assert check_docs.example_endpoints("3.8") == endpoints[:1]


@pytest.mark.parametrize("timeout", [0, 901, 1.5, True, "60"])
def test_an_invalid_command_timeout_is_rejected(
    root: Path, catalogue: Catalogue, timeout: object
) -> None:
    """The per-entry ``timeout`` is a whole number of seconds within the limit."""
    document = catalogue.load()
    catalogue.entry(document, "typed-values")["timeout"] = timeout
    catalogue.save(document)
    with pytest.raises(ValueError, match="example timeout"):
        check_docs.check(root)


def test_a_command_timeout_may_be_set_per_entry(root: Path, catalogue: Catalogue) -> None:
    """The positive control for the timeout field."""
    document = catalogue.load()
    catalogue.entry(document, "typed-values")["timeout"] = 300
    catalogue.save(document)
    assert check_docs.check(root)


@pytest.mark.parametrize(("declared", "expected"), [({}, 120), ({"timeout": 7}, 7)])
def test_documented_commands_run_with_a_time_limit(
    root: Path, monkeypatch: pytest.MonkeyPatch, declared: dict[str, int], expected: int
) -> None:
    """An entry's own ``timeout`` wins; otherwise the default bounds the command."""
    seen: list[object] = []

    def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[bytes]:
        seen.append(kwargs.get("timeout"))
        return subprocess.CompletedProcess(command, 0, b"ok\n", b"")

    (root / "out").write_bytes(b"ok\n")
    monkeypatch.setattr(check_docs, "run", run)
    check_docs.run_entry({"id": "x", "command": ["x"], "stdout": "out", **declared}, root)
    assert seen == [expected]


def test_a_hung_documented_command_names_its_example(
    root: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A command that outlives its limit fails the check with the example's identifier."""

    def hang(command: list[str], **kwargs: object) -> None:
        raise subprocess.TimeoutExpired(command, 1)

    (root / "out").write_bytes(b"ok\n")
    monkeypatch.setattr(check_docs, "run", hang)
    with pytest.raises(ValueError, match="timed out after 120 s: typed-values"):
        check_docs.run_entry({"id": "typed-values", "command": ["x"], "stdout": "out"}, root)
