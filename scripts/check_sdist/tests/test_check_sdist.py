"""Archive-member, Haddock-example and consumer-workspace checks that need no Cabal build."""

import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

import check_sdist

PLAN = {
    "install-plan": [
        {"id": "base-4.22", "pkg-name": "base"},
        {"id": "libtmux-haskell-0.0.1.0-inplace", "pkg-name": "libtmux-haskell"},
    ]
}

# The archived files the generated public consumer is written from.
PUBLIC_SOURCES = [
    "test/integration/PublicMutationTest.hs",
    "test/integration/PublicCreationTest.hs",
    "test/integration/PublicLifecycleTest.hs",
    "test-support/Fixture.hs",
    "test-support/fixture-watch.c",
]


def write_tar(path: Path, files: dict[str, bytes], *, unsafe: str | None = None) -> None:
    """Write an archive of ``files``, plus an empty member named ``unsafe``."""
    with tarfile.open(path, "w:gz") as archive:
        for name, data in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
        if unsafe is not None:
            archive.addfile(tarfile.TarInfo(unsafe))


@pytest.fixture
def checkout(tmp_path: Path) -> Path:
    """A checkout with one source file."""
    root = tmp_path / "checkout"
    (root / "src").mkdir(parents=True)
    (root / "src/LibTmux.hs").write_bytes(b"module LibTmux where\n")
    return root


def verify(tmp_path: Path, root: Path, files: dict[str, bytes], unsafe: str | None = None) -> None:
    """Run the member check on an archive of ``files``."""
    archive = tmp_path / "source.tar.gz"
    write_tar(archive, files, unsafe=unsafe)
    with tarfile.open(archive) as source:
        check_sdist.verify_members(source, root)


def test_archive_members_must_equal_their_checkout_files(tmp_path: Path, checkout: Path) -> None:
    """An archive whose bytes match the checkout passes; a changed member fails."""
    verify(
        tmp_path, checkout, {"libtmux-haskell-0.0.1.0/src/LibTmux.hs": b"module LibTmux where\n"}
    )
    with pytest.raises(ValueError, match=r"differs from source: LibTmux\.hs"):
        verify(tmp_path, checkout, {"libtmux-haskell-0.0.1.0/src/LibTmux.hs": b"changed\n"})


@pytest.mark.parametrize("name", ["../escape.hs", "/etc/passwd"])
def test_unsafe_archive_member_names_are_rejected(
    tmp_path: Path, checkout: Path, name: str
) -> None:
    """Members that leave the archive root are never compared or read."""
    with pytest.raises(ValueError, match="Unsafe"):
        verify(tmp_path, checkout, {}, unsafe=name)


def test_haddock_example_directives_are_limited_to_overloaded_strings() -> None:
    """Only the one setup directive the archive consumer understands is accepted."""
    modules = ["LibTmux"]
    ok = [(":set -XOverloadedStrings", ""), ('parseWindowId "@1"', "Right (WindowId 1)\n")]
    command = check_sdist.haddock_command(PLAN, modules, ok)
    assert command[command.index("-package-id") + 1] == "base-4.22"
    assert command.count("-e") == 3
    with pytest.raises(ValueError, match="Unknown Haddock setup directive"):
        check_sdist.haddock_command(PLAN, modules, [(":set -XCPP", "")])


@pytest.mark.parametrize(
    "plan",
    [
        {"install-plan": [PLAN["install-plan"][0]]},
        {"install-plan": [*PLAN["install-plan"], {"id": "base-4.23", "pkg-name": "base"}]},
    ],
)
def test_haddock_examples_need_one_exact_base_and_library_unit(plan: dict[str, Any]) -> None:
    """A plan with a missing or ambiguous unit is refused instead of guessed."""
    with pytest.raises(ValueError, match="one exact base/library unit"):
        check_sdist.haddock_command(plan, ["LibTmux"], [("1 + 1", "2\n")])


def test_no_executable_haddock_example_is_an_error(tmp_path: Path) -> None:
    """A library whose documentation holds no runnable example fails the check."""
    (tmp_path / "dist-newstyle/cache").mkdir(parents=True)
    (tmp_path / "dist-newstyle/cache/plan.json").write_text(json.dumps(PLAN))
    for examples in [[], [(":set -XOverloadedStrings", "")]]:
        with pytest.raises(ValueError, match="No executable Haddock examples"):
            check_sdist.check_haddock_examples(tmp_path, ["LibTmux"], examples)


@pytest.mark.parametrize(
    "project",
    [
        "packages: .\n",
        f"  tag: {'a1' * 20}\n  tag: {'b2' * 20}\n",
        f"  tag: {'A1' * 20}\n",
        f"  tag: {'a1' * 19}\n",
    ],
)
def test_installation_must_name_exactly_one_full_source_revision(project: str) -> None:
    """No pin, two pins, an uppercase or a short revision are all refused."""
    with pytest.raises(ValueError, match="one reviewed source revision"):
        check_sdist.installation_pin(project)


# A stand-in for ``cabal`` that never compiles. It models what Cabal repeats per workspace
# (``solve``), keeps a store of compiled cores keyed by archive hash, and records every build,
# example run and Haddock evaluation so a test can inspect what each workspace was asked to do.
# Example programs print the ``-- out:``/``-- err:`` lines of their Main.hs and exit with its
# ``-- exit:`` code.
FAKE_CABAL = """
import hashlib, json, os, sys, tarfile
from pathlib import Path

args = sys.argv[1:]


def log(event, **fields):
    with Path(os.environ["FAKE_LOG"]).open("a") as handle:
        handle.write(json.dumps({"event": event, **fields}) + "\\n")


if args[0] == "--exe":
    code = 0
    for line in Path(args[1]).read_text().splitlines():
        kind, _, text = line.removeprefix("-- ").partition(": ")
        if kind == "out":
            sys.stdout.write(text + "\\n")
        elif kind == "err":
            sys.stderr.write(text + "\\n")
        elif kind == "exit":
            code = int(text)
    log("run", program=args[2])
    sys.exit(code)
if args[0] == "sdist":
    out = Path(next(a for a in args if a.startswith("--output-directory=")).split("=", 1)[1])
    out.mkdir(parents=True)
    with tarfile.open(out / "libtmux-haskell-0.0.1.0.tar.gz", "w:gz") as archive:
        for path in sorted(Path.cwd().rglob("*")):
            if ".git" not in path.parts and path.is_file():
                name = path.relative_to(Path.cwd()).as_posix()
                archive.add(path, "libtmux-haskell-0.0.1.0/" + name)
    sys.exit(0)

project = Path("cabal.project").read_text()
packages = project.splitlines()[0].removeprefix("packages: ").split()
tarball = next(Path(p) for p in packages if p.endswith(".tar.gz"))
sha = hashlib.sha256(tarball.read_bytes()).hexdigest()[:12]
with tarfile.open(tarball) as archive:
    core = archive.extractfile("libtmux-haskell-0.0.1.0/src/LibTmux.hs").read()
marker = core.splitlines()[0].decode()
plan = Path("dist-newstyle/cache/plan.json")
if not plan.exists() or json.loads(plan.read_text())["sha"] != sha:
    plan.parent.mkdir(parents=True, exist_ok=True)
    plan.write_text(json.dumps({"sha": sha, "install-plan": [
        {"id": "base-4.22", "pkg-name": "base"},
        {"id": "libtmux-haskell-0.0.1.0-" + sha, "pkg-name": "libtmux-haskell"},
    ]}))
    log("solve", cwd=os.getcwd(), sha=sha, marker=marker)


def program(target):
    return Path("dist-newstyle/bin", target.removeprefix("exe:")).resolve()


if args[0] == "list-bin":
    print(program(args[1]))
elif args[0] == "build":
    store = Path(os.environ["FAKE_STORE"], sha)
    if not store.exists():
        store.mkdir(parents=True)
        log("compile-core", sha=sha, marker=marker)
    targets = [a for a in args[1:] if a.startswith("exe:")]
    for target in targets:
        package = next(
            Path(p) for p in packages
            if p != str(tarball)
            and f"executable {target.removeprefix('exe:')}\\n" in "".join(
                c.read_text() for c in Path(p).glob("*.cabal"))
        )
        exe = program(target)
        exe.parent.mkdir(parents=True, exist_ok=True)
        exe.write_text(
            f"#!/bin/sh\\nexec {sys.executable} -S {__file__} --exe {package.resolve() / 'Main.hs'} {exe}\\n"
        )
        exe.chmod(0o755)
    log("build", cwd=os.getcwd(), targets=targets, packages=packages, project=project,
        files={p: sorted(f.name for f in Path(p).iterdir()) for p in packages if p != str(tarball)})
elif args[0] == "exec":
    ghc = args[args.index("--") + 1 :]
    for index, word in enumerate(ghc):
        if word == "-e" and not ghc[index + 1].startswith(":"):
            print(eval(ghc[index + 1]))
    log("haddock", cwd=os.getcwd(), package_ids=[
        ghc[i + 1] for i, word in enumerate(ghc) if word == "-package-id"])
"""

FAKE_RUNNER = """
import argparse, json, os, subprocess, sys
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--program")
parser.add_argument("--expected-panes", type=int, default=1)
arguments = parser.parse_args()
result = subprocess.run([arguments.program], capture_output=True, check=True)
if result.stdout != Path(__file__).with_name("expected.stdout").read_bytes() or result.stderr:
    raise SystemExit("unexpected example output")
with Path(os.environ["FAKE_LOG"]).open("a") as handle:
    handle.write(json.dumps({"event": "runner", "script": __file__, "panes": arguments.expected_panes}) + "\\n")
sys.stdout.buffer.write(result.stdout)
"""

# (example id, example directory holding its runner, fixture pane count)
EXAMPLES = [
    ("typed-values", None, None),
    ("capture-graph", "capture-graph", 2),
    ("shared-runtime", "capture-graph", None),
    ("owned-server", None, None),
]


@dataclass
class Consumers:
    """A checkout and the events its fake ``cabal`` recorded."""

    root: Path
    log: Path

    def events(self, kind: str) -> list[dict[str, Any]]:
        """Return the recorded events of one kind, in order."""
        rows = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [row for row in rows if row["event"] == kind]


def git(root: Path, *args: str) -> str:
    """Run Git in the fixture checkout and return its output."""
    command = ["git", "-c", "user.name=test", "-c", "user.email=test@invalid", *args]
    return subprocess.run(command, cwd=root, check=True, capture_output=True, text=True).stdout


@pytest.fixture
def consumers(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Consumers:
    """Point the script at a two-commit checkout and a fake ``cabal``.

    The first commit is the installation pin, whose core source starts ``-- pin``; HEAD adds
    four declared examples, the public command cases and a core starting ``-- head``.
    """
    root = tmp_path / "checkout"
    (root / "src").mkdir(parents=True)
    manifest = "name: libtmux-haskell\nversion: 0.0.1.0\n"
    (root / "libtmux-haskell.cabal").write_text(
        manifest + "\nlibrary\n  exposed-modules: LibTmux\n  other-modules: Hidden\n"
    )
    (root / "src/LibTmux.hs").write_text("-- pin\nmodule LibTmux where\n")
    git(root, "init", "-q")
    git(root, "add", "-A")
    git(root, "commit", "-qm", "pin")
    pin = git(root, "rev-parse", "HEAD").strip()
    (root / "src/LibTmux.hs").write_text(
        "-- head\nmodule LibTmux where\n-- | Sum.\n--\n-- >>> 1 + 2 + 3\n-- 6\n"
    )
    for name in PUBLIC_SOURCES:
        (root / name).parent.mkdir(parents=True, exist_ok=True)
        (root / name).write_text(f"-- {name}\n")
    entries = []
    for name, runner, panes in EXAMPLES:
        folder = root / "examples" / name
        folder.mkdir(parents=True)
        (folder / "Main.hs").write_text(f"module Main where\n-- out: {name}\n")
        (folder / f"libtmux-{name}.cabal").write_text(f"executable {name}\n  main-is: Main.hs\n")
        (folder / "expected.stdout").write_text(f"{name}\n")
        (folder / "cabal.project.vcs").write_text(f"  tag: {pin}\n")
        entry: dict[str, Any] = {
            "id": name,
            "source": f"examples/{name}/Main.hs",
            "package": f"examples/{name}/libtmux-{name}.cabal",
            "vcs_project": f"examples/{name}/cabal.project.vcs",
            "stdout": f"examples/{name}/expected.stdout",
            "executable": name,
        }
        if runner:
            entry["runner"] = f"examples/{runner}/run.py"
        if panes:
            entry["fixture_panes"] = panes
        entries.append(entry)
    (root / "examples/capture-graph/run.py").write_text(FAKE_RUNNER)
    git(root, "add", "-A")
    git(root, "commit", "-qm", "head")

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "cabal").write_text(f"#!{sys.executable} -S\n{FAKE_CABAL}")
    (bin_dir / "cabal").chmod(0o755)
    (tmp_path / "tmp").mkdir()
    log = tmp_path / "events.jsonl"
    log.touch()
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_LOG", str(log))
    monkeypatch.setenv("FAKE_STORE", str(tmp_path / "store"))
    monkeypatch.setattr(tempfile, "tempdir", str(tmp_path / "tmp"))
    monkeypatch.setattr(check_sdist, "ROOT", root)
    monkeypatch.setattr(check_sdist, "MANIFEST", root / "libtmux-haskell.cabal")
    monkeypatch.setattr(check_sdist, "check_docs", lambda: entries)
    return Consumers(root, log)


def test_each_source_builds_and_runs_its_consumers_in_one_workspace(consumers: Consumers) -> None:
    """The archive and the installation pin each get one solved, built workspace.

    Every declared example, with its own runner and expected output, runs from the workspace of
    the source it must pass against; the public cases join only the archive's workspace. Neither
    workspace lists the checkout or the other source.
    """
    check_sdist.main()
    solves = consumers.events("solve")
    markers = {solve["cwd"]: solve["marker"] for solve in solves}
    assert sorted(solve["marker"] for solve in solves) == ["-- head", "-- pin"]
    cores = consumers.events("compile-core")
    assert sorted(core["marker"] for core in cores) == ["-- head", "-- pin"]
    builds = {build["cwd"]: build for build in consumers.events("build")}
    assert builds.keys() == markers.keys()
    files = {
        "typed-values": ["Main.hs", "libtmux-typed-values.cabal"],
        "capture-graph": ["Main.hs", "expected.stdout", "libtmux-capture-graph.cabal", "run.py"],
        "shared-runtime": ["Main.hs", "expected.stdout", "libtmux-shared-runtime.cabal", "run.py"],
        "owned-server": ["Main.hs", "libtmux-owned-server.cabal"],
    }
    public = {
        "public-mutations": [
            "Fixture.hs",
            "Main.hs",
            "PublicCreationTest.hs",
            "PublicLifecycleTest.hs",
            "PublicMutationTest.hs",
            "consumer.cabal",
            "fixture-watch.c",
        ]
    }
    for cwd, marker in markers.items():
        expected = files | (public if marker == "-- head" else {})
        targets = {f"exe:{name}" for name in files} | (
            {"exe:public-mutations-consumer"} if marker == "-- head" else set()
        )
        library, *packages = builds[cwd]["packages"]
        assert library.endswith(".tar.gz")
        assert packages == list(expected)
        assert builds[cwd]["files"] == expected
        assert set(builds[cwd]["targets"]) == targets
        assert str(consumers.root) not in builds[cwd]["project"]
        runs = consumers.events("run")
        ran = {Path(run["program"]).name for run in runs if run["program"].startswith(cwd)}
        assert ran == {target.removeprefix("exe:") for target in targets}
        runners = [
            (Path(run["script"]).parent.name, run["panes"])
            for run in consumers.events("runner")
            if run["script"].startswith(cwd)
        ]
        assert runners == [("capture-graph", 2), ("shared-runtime", 1)]
    archive = next(cwd for cwd, marker in markers.items() if marker == "-- head")
    (haddock,) = consumers.events("haddock")
    sha = next(solve["sha"] for solve in solves if solve["cwd"] == archive)
    assert haddock["cwd"] == archive
    assert haddock["package_ids"] == ["base-4.22", "libtmux-haskell-0.0.1.0-" + sha]


@pytest.mark.parametrize(
    ("main_lines", "error", "message"),
    [
        pytest.param("-- exit: 3\n", subprocess.CalledProcessError, "exit status 3", id="status"),
        pytest.param("-- out: extra\n", ValueError, "output: owned-server", id="stdout"),
        pytest.param("-- err: noise\n", ValueError, "output: owned-server", id="stderr"),
    ],
)
def test_the_last_example_failing_fails_the_check_before_the_pin(
    consumers: Consumers, main_lines: str, error: type[Exception], message: str
) -> None:
    """A later example's exit status, extra stdout or any stderr is not masked by earlier passes."""
    with (consumers.root / "examples/owned-server/Main.hs").open("a") as program:
        program.write(main_lines)
    with pytest.raises(error, match=message):
        check_sdist.main()
    ran = [Path(run["program"]).name for run in consumers.events("run")]
    assert ran == ["typed-values", "capture-graph", "shared-runtime", "owned-server"]
    assert {solve["marker"] for solve in consumers.events("solve")} == {"-- head"}


def test_generated_consumer_ends_through_the_retained_daemon_guard(tmp_path: Path) -> None:
    """The archive runner wraps its whole test tree in the fixture's guard.

    Retirement writes no diagnostic, so a daemon that outlives both signals is reported only by
    this guard's exit status.
    """
    archive = tmp_path / "source.tar.gz"
    prefix = "libtmux-haskell-0.0.1.0/"
    write_tar(archive, {prefix + name: b"" for name in PUBLIC_SOURCES})
    with tarfile.open(archive) as source:
        check_sdist.write_public_consumer(source, prefix, tmp_path / "consumer", "0.0.1.0")
    runner = (tmp_path / "consumer/Main.hs").read_text()
    assert "import Fixture (guardRetained)\n" in runner
    assert "main = guardRetained (defaultMain (testGroup" in runner
    assert runner.endswith("PublicLifecycleTest.tests]))\n")


@pytest.fixture
def consumer_binary(tmp_path: Path) -> Callable[[int, str], str]:
    """Write a stand-in consumer that prints to stderr and exits with a chosen status."""

    def write(status: int, stderr: str) -> str:
        script = tmp_path / "consumer"
        script.write_text(
            f"#!{sys.executable} -S\nimport sys\nsys.stderr.write({stderr!r})\nsys.exit({status})\n"
        )
        script.chmod(0o755)
        return str(script)

    return write


@pytest.mark.parametrize(
    ("status", "stderr", "message"),
    [
        pytest.param(
            3, "fixture daemons still owned: sleeper\n", "exited 3: .*sleeper", id="owned"
        ),
        pytest.param(1, "", "exited 1", id="failed"),
        pytest.param(0, "noise\n", "emitted stderr: noise", id="stderr"),
    ],
)
def test_installed_consumer_must_exit_zero_without_stderr(
    consumer_binary: Callable[[int, str], str],
    tmp_path: Path,
    status: int,
    stderr: str,
    message: str,
) -> None:
    """A clean run passes; a retained owner, a failure or any stderr fails with its cause."""
    check_sdist.check_public_commands(consumer_binary(0, ""), tmp_path)
    with pytest.raises(ValueError, match=message):
        check_sdist.check_public_commands(consumer_binary(status, stderr), tmp_path)


@pytest.fixture
def commands(monkeypatch: pytest.MonkeyPatch) -> list[tuple[str, object]]:
    """Record each external command and its time limit; none of them runs."""
    seen: list[tuple[str, object]] = []

    def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[bytes]:
        seen.append((command[0], kwargs.get("timeout")))
        return subprocess.CompletedProcess(command, 0, b"ok\n", b"")

    def output(command: list[str], **kwargs: object) -> str:
        seen.append((command[0], kwargs.get("timeout")))
        return "program"

    monkeypatch.setattr(check_sdist, "bounded_run", run)
    monkeypatch.setattr(check_sdist, "output", output)
    return seen


@pytest.mark.parametrize(("declared", "limit"), [({}, 120), ({"timeout": 7}, 7)])
def test_an_example_consumer_bounds_its_build_and_run(
    tmp_path: Path,
    commands: list[tuple[str, object]],
    declared: dict[str, int],
    limit: int,
) -> None:
    """Build, binary lookup and the example's own run each carry a time limit."""
    entry = {
        "id": "demo",
        "source": "Main.hs",
        "package": "demo.cabal",
        "stdout": "expected.stdout",
        "executable": "demo",
        **declared,
    }
    check_sdist.check_example_consumers(
        [entry], tmp_path / "workspace", "../lib.tar.gz", lambda path: b"ok\n"
    )
    assert commands == [("cabal", 600), ("cabal", 120), ("program", limit)]


def test_haddock_examples_run_with_a_time_limit(
    tmp_path: Path, commands: list[tuple[str, object]]
) -> None:
    """The ``ghc -e`` run that executes the documentation examples is bounded."""
    (tmp_path / "dist-newstyle/cache").mkdir(parents=True)
    (tmp_path / "dist-newstyle/cache/plan.json").write_text(json.dumps(PLAN))
    with pytest.raises(ValueError, match="Haddock example output differs"):
        check_sdist.check_haddock_examples(tmp_path, ["LibTmux"], [("1 + 1", "2\n")])
    assert commands == [("cabal", 600)]
