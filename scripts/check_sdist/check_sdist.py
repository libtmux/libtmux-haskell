# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Build and execute public consumers from the core source archive."""

import json
import re
import subprocess
import sys
import tarfile
import tempfile
from collections.abc import Callable
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "libtmux-haskell.cabal"
for sibling in ("check_docs", "prepare_haddock"):
    sys.path.append(str(SCRIPTS / sibling))

from check_docs import Entry
from check_docs import check as check_docs
from prepare_haddock import cabal_modules

type Example = tuple[str, str]


def run(args: list[str], cwd: Path) -> None:
    """Run a command that must succeed."""
    subprocess.run(args, cwd=cwd, check=True)


def archived(source: tarfile.TarFile, name: str) -> bytes:
    """Read one regular file from the archive."""
    member = source.extractfile(name)
    if member is None:
        raise ValueError(f"Source archive member is not a file: {name}")
    return member.read()


def verify_members(source: tarfile.TarFile, root: Path) -> None:
    """Require every archived file to be safe and identical to its checkout file."""
    for member in source.getmembers():
        name = Path(member.name)
        if name.is_absolute() or ".." in name.parts:
            raise ValueError("Unsafe source archive member")
        if member.isfile():
            local = root.joinpath(*name.parts[1:])
            if archived(source, member.name) != local.read_bytes():
                raise ValueError(f"Archive member differs from source: {local.name}")


def haddock_examples(source: str) -> list[Example]:
    """List the ``>>>`` examples of a module as ``(expression, expected output)`` pairs.

    >>> haddock_examples('''
    ... -- | Parse an id.
    ... --
    ... -- >>> parseWindowId "@1"
    ... -- Right (WindowId 1)
    ... -- >>> :set -XOverloadedStrings
    ... x = 1
    ... ''')
    [('parseWindowId "@1"', 'Right (WindowId 1)\\n'), (':set -XOverloadedStrings', '')]
    """
    lines = source.splitlines()
    examples = []
    for index, line in enumerate(lines):
        if not line.startswith("-- >>> "):
            continue
        command = line.removeprefix("-- >>> ")
        expected = []
        for following in lines[index + 1 :]:
            if not following.startswith("-- ") or following.startswith("-- >>> "):
                break
            expected.append(following.removeprefix("-- "))
        examples.append((command, "\n".join(expected) + ("\n" if expected else "")))
    return examples


def main() -> None:
    """Build the archive, then build and run every consumer from it."""
    examples = check_docs()
    match = re.search(r"^version:\s*(\S+)", MANIFEST.read_text(), re.MULTILINE)
    if match is None:
        raise ValueError("The Cabal manifest has no version")
    version = match.group(1)
    with tempfile.TemporaryDirectory(prefix="libtmux-haskell-consumer-") as temporary:
        directory = Path(temporary)
        archives = directory / "archives"
        run(["cabal", "sdist", "all", "--output-directory=" + str(archives)], ROOT)
        archive = archives / f"libtmux-haskell-{version}.tar.gz"
        with tarfile.open(archive) as source:
            verify_members(source, ROOT)
            prefix = f"libtmux-haskell-{version}/"
            doctests: list[Example] = []
            doctest_modules: list[str] = []
            for module in sorted(cabal_modules(MANIFEST)[0]):
                path = "src/" + module.replace(".", "/") + ".hs"
                found = haddock_examples(archived(source, prefix + path).decode())
                if found:
                    doctest_modules.append(module)
                    doctests.extend(found)
            workspace = directory / "archive"
            write_public_consumer(source, prefix, workspace / "public-mutations", version)
            executables = check_example_consumers(
                examples,
                workspace,
                f"../archives/libtmux-haskell-{version}.tar.gz",
                lambda path: archived(source, prefix + path),
                {"public-mutations": "exe:public-mutations-consumer"},
            )
            check_haddock_examples(workspace, doctest_modules, doctests)
            check_public_commands(executables["exe:public-mutations-consumer"], directory)
            check_installation_pin(directory, examples)
        print("PASS: archive members, documented public example and Haddock examples")


def installation_pin(project: str) -> str:
    """Return the one source revision a ``cabal.project.vcs`` names.

    >>> installation_pin("  tag: " + "a1" * 20)
    'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1'
    """
    pins = re.findall(r"^\s+tag:\s+([a-f0-9]{40})\s*$", project, re.MULTILINE)
    if len(pins) != 1:
        raise ValueError("Installation must name one reviewed source revision")
    return pins[0]


def check_installation_pin(directory: Path, examples: list[Entry]) -> None:
    """Run current programs against the source revision offered for installation."""
    capture = next(entry for entry in examples if entry["id"] == "capture-graph")
    pin = installation_pin((ROOT / capture["vcs_project"]).read_text())
    run(["git", "merge-base", "--is-ancestor", pin, "HEAD"], ROOT)
    manifest = subprocess.check_output(
        ["git", "show", pin + ":libtmux-haskell.cabal"], cwd=ROOT, text=True
    )
    match = re.search(r"^version:\s*(\S+)", manifest, re.MULTILINE)
    if match is None:
        raise ValueError("The pinned Cabal manifest has no version")
    name = f"libtmux-haskell-{match.group(1)}"
    archive = directory / (name + ".tar.gz")
    archive.write_bytes(
        subprocess.check_output(
            ["git", "archive", "--format=tar.gz", "--prefix=" + name + "/", pin], cwd=ROOT
        )
    )
    check_example_consumers(
        examples,
        directory / "installation",
        "../" + archive.name,
        lambda path: (ROOT / path).read_bytes(),
    )
    print("PASS: documented installation pin supports the current public examples")


def check_example_consumers(
    examples: list[Entry],
    workspace: Path,
    library: str,
    read_source: Callable[[str], bytes],
    extra: dict[str, str] | None = None,
) -> dict[str, str]:
    """Build and check every example against ``library`` in one isolated workspace.

    ``extra`` maps further package directories already written under ``workspace`` to their
    executable targets. One Cabal invocation builds every target, so Cabal solves and configures
    this source once, not once per example. Return the built executables by target.
    """
    extra = extra or {}
    for entry in examples:
        package = workspace / entry["id"]
        package.mkdir(parents=True)
        for field in ["source", "package", *(["runner", "stdout"] if "runner" in entry else [])]:
            (package / Path(entry[field]).name).write_bytes(read_source(entry[field]))
    packages = [library, *(entry["id"] for entry in examples), *extra]
    (workspace / "cabal.project").write_text(
        f"packages: {' '.join(packages)}\nindex-state: 2026-11-06T00:00:00Z\ntests: False\n"
    )
    targets = ["exe:" + entry["executable"] for entry in examples] + list(extra.values())
    run(["cabal", "build", *targets, "--offline"], workspace)
    executables = {
        target: subprocess.check_output(
            ["cabal", "list-bin", target, "--offline"], cwd=workspace, text=True
        ).strip()
        for target in targets
    }
    for entry in examples:
        check_example(entry, workspace, executables["exe:" + entry["executable"]], read_source)
    return executables


def check_example(
    entry: Entry, workspace: Path, executable: str, read_source: Callable[[str], bytes]
) -> None:
    """Run one built example and compare its exit status, stdout and stderr with the catalogue."""
    command = (
        [
            "python3",
            str(workspace / entry["id"] / Path(entry["runner"]).name),
            "--program",
            executable,
        ]
        if "runner" in entry
        else [executable]
    )
    if "fixture_panes" in entry:
        command += ["--expected-panes", str(entry["fixture_panes"])]
    result = subprocess.run(command, cwd=workspace.parent, check=True, capture_output=True)
    if result.stdout != read_source(entry["stdout"]) or result.stderr:
        raise ValueError(f"Installed example produced unexpected output: {entry['id']}")


def write_public_consumer(
    source: tarfile.TarFile, prefix: str, consumer: Path, version: str
) -> None:
    """Write the archive's public command cases as a package that imports only its library."""
    consumer.mkdir(parents=True)
    for origin, name in [
        ("test/integration/PublicMutationTest.hs", "PublicMutationTest.hs"),
        ("test/integration/PublicCreationTest.hs", "PublicCreationTest.hs"),
        ("test/integration/PublicLifecycleTest.hs", "PublicLifecycleTest.hs"),
        ("test-support/Fixture.hs", "Fixture.hs"),
        ("test-support/fixture-watch.c", "fixture-watch.c"),
    ]:
        (consumer / name).write_bytes(archived(source, prefix + origin))
    (consumer / "Main.hs").write_text(
        "module Main (main) where\n"
        "import Fixture (guardRetained)\n"
        "import PublicMutationTest qualified\n"
        "import PublicCreationTest qualified\n"
        "import PublicLifecycleTest qualified\n"
        "import Test.Tasty (defaultMain, testGroup)\n"
        "main :: IO ()\n"
        'main = guardRetained (defaultMain (testGroup "installed public commands"'
        " [PublicMutationTest.tests, PublicCreationTest.tests, PublicLifecycleTest.tests]))\n"
    )
    (consumer / "consumer.cabal").write_text(
        "cabal-version: 3.18\nname: public-mutations-consumer\nversion: 0.0.0\n"
        "build-type: Simple\n"
        "executable public-mutations-consumer\n"
        "  main-is: Main.hs\n"
        "  other-modules: Fixture PublicMutationTest PublicCreationTest PublicLifecycleTest\n"
        "  default-language: GHC2024\n"
        "  default-extensions: OverloadedRecordDot OverloadedStrings DuplicateRecordFields"
        " NoFieldSelectors\n"
        "  ghc-options: -Wall -Werror -threaded -rtsopts\n"
        "  c-sources: fixture-watch.c\n"
        "  cc-options: -std=c11 -Wall -Wextra\n"
        "  build-depends: base >=4.22 && <4.23, async, bytestring, directory, filepath,\n"
        f"    libtmux-haskell ^>={version}, os-string, tasty, tasty-hunit, text, typed-process,"
        " unix\n"
    )


def check_public_commands(executable: str, directory: Path) -> None:
    """Run the built public command, lifecycle and recovery cases.

    They must exit zero and emit no stderr. The consumer ends through the fixture's guard, which
    exits 3 and names the owners when a fixture daemon survived retirement, so a leak that
    retirement reports to nobody still fails here.
    """
    result = subprocess.run(
        [executable, "--hide-successes"], cwd=directory, check=False, capture_output=True
    )
    stderr = result.stderr.decode(errors="replace")
    if result.returncode:
        stdout = result.stdout.decode(errors="replace")[-2000:]
        raise ValueError(
            f"Installed public consumer exited {result.returncode}: {stderr}\n{stdout}"
        )
    if result.stderr:
        raise ValueError(f"Installed public mutation consumer emitted stderr: {stderr}")
    print("PASS: installed public command, lifecycle and recovery behavior")


def haddock_command(plan: dict[str, Any], modules: list[str], examples: list[Example]) -> list[str]:
    """Build the ``ghc -e`` command that runs the examples against the archived library."""
    units = {
        name: [item["id"] for item in plan["install-plan"] if item["pkg-name"] == name]
        for name in ["base", "libtmux-haskell"]
    }
    if any(len(matches) != 1 for matches in units.values()):
        raise ValueError("Haddock consumer needs one exact base/library unit")
    command = [
        "cabal",
        "exec",
        "--offline",
        "-v0",
        "--",
        "ghc",
        "-v0",
        "-ignore-dot-ghci",
        "-XGHC2024",
        "-hide-all-packages",
        "-package-id",
        units["base"][0],
        "-package-id",
        units["libtmux-haskell"][0],
        "-e",
        ":module + " + " ".join(modules),
    ]
    for expression, _ in examples:
        if expression.startswith(":") and expression != ":set -XOverloadedStrings":
            raise ValueError("Unknown Haddock setup directive")
        command.extend(["-e", expression])
    return command


def check_haddock_examples(consumer: Path, modules: list[str], examples: list[Example]) -> None:
    """Execute every public Haddock example and compare its output."""
    if not examples or not any(not command.startswith(":") for command, _ in examples):
        raise ValueError("No executable Haddock examples")
    plan = json.loads((consumer / "dist-newstyle/cache/plan.json").read_text())
    command = haddock_command(plan, modules, examples)
    result = subprocess.run(command, cwd=consumer, capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError(f"Haddock example execution failed: {result.stderr}")
    expected = "".join(output for _, output in examples)
    if result.stdout != expected or result.stderr:
        raise ValueError(f"Haddock example output differs: {result.stdout!r}; {result.stderr!r}")
    executed = sum(not expression.startswith(":") for expression, _ in examples)
    print(f"PASS: {executed} Haddock examples")


if __name__ == "__main__":
    main()
