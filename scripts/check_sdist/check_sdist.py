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

from check_docs import DEFAULT_TIMEOUT, Entry
from check_docs import check as check_docs
from prepare_haddock import cabal_modules

type Example = tuple[str, str]

# Seconds. Every external command is bounded so a hang fails with the command's
# name before the job's time limit stops it without one.
QUICK = 120
BUILD = 600


def run(args: list[str], cwd: Path, timeout: int = QUICK) -> None:
    """Run a command that must succeed within ``timeout`` seconds."""
    subprocess.run(args, cwd=cwd, check=True, timeout=timeout)


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
            consumers = directory / "archive-examples"
            check_example_consumers(
                examples,
                consumers,
                f"../archives/libtmux-haskell-{version}.tar.gz",
                lambda path: archived(source, prefix + path),
            )
            check_haddock_examples(consumers, doctest_modules, doctests)
            check_installation_pin(directory, examples)
            check_public_commands(source, prefix, directory, version)
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
        ["git", "show", pin + ":libtmux-haskell.cabal"], cwd=ROOT, text=True, timeout=QUICK
    )
    match = re.search(r"^version:\s*(\S+)", manifest, re.MULTILINE)
    if match is None:
        raise ValueError("The pinned Cabal manifest has no version")
    name = f"libtmux-haskell-{match.group(1)}"
    archive = directory / (name + ".tar.gz")
    archive.write_bytes(
        subprocess.check_output(
            ["git", "archive", "--format=tar.gz", "--prefix=" + name + "/", pin],
            cwd=ROOT,
            timeout=QUICK,
        )
    )
    check_example_consumers(
        examples,
        directory / "installation-examples",
        "../" + archive.name,
        lambda path: (ROOT / path).read_bytes(),
    )
    print("PASS: documented installation pin supports the current public examples")


def check_example_consumers(
    examples: list[Entry], workspace: Path, library: str, read_source: Callable[[str], bytes]
) -> None:
    """Build one archive's separate packages together, then check every output."""
    workspace.mkdir()
    for entry in examples:
        consumer = workspace / entry["id"]
        consumer.mkdir()
        for field in ["source", "package", *(["runner", "stdout"] if "runner" in entry else [])]:
            (consumer / Path(entry[field]).name).write_bytes(read_source(entry[field]))
    packages = " ".join(entry["id"] for entry in examples)
    (workspace / "cabal.project").write_text(
        f"packages: {library} {packages}\nindex-state: 2026-11-06T00:00:00Z\ntests: False\n"
    )
    run(["cabal", "build", "all", "--offline", "--jobs=2"], workspace, BUILD)
    for entry in examples:
        consumer = workspace / entry["id"]
        target = "exe:" + entry["executable"]
        executable = subprocess.check_output(
            ["cabal", "list-bin", target, "--offline"], cwd=workspace, text=True, timeout=QUICK
        ).strip()
        command = (
            ["python3", str(consumer / Path(entry["runner"]).name), "--program", executable]
            if "runner" in entry
            else [executable]
        )
        if "fixture_panes" in entry:
            command += ["--expected-panes", str(entry["fixture_panes"])]
        result = subprocess.run(
            command, cwd=workspace, check=True, capture_output=True,
            timeout=entry.get("timeout", DEFAULT_TIMEOUT),
        )
        if result.stdout != read_source(entry["stdout"]) or result.stderr:
            raise ValueError(f"Installed example {entry['id']} produced unexpected output")


def check_public_commands(
    source: tarfile.TarFile, prefix: str, directory: Path, version: str
) -> None:
    """Run public command cases against the archive, without private imports."""
    consumer = directory / "public-mutations"
    consumer.mkdir()
    for origin, name in [
        ("test/integration/PublicMutationTest.hs", "PublicMutationTest.hs"),
        ("test/integration/PublicCreationTest.hs", "PublicCreationTest.hs"),
        ("test-support/Fixture.hs", "Fixture.hs"),
        ("test-support/fixture-watch.c", "fixture-watch.c"),
    ]:
        (consumer / name).write_bytes(archived(source, prefix + origin))
    (consumer / "Main.hs").write_text(
        "module Main (main) where\n"
        "import PublicMutationTest qualified\n"
        "import PublicCreationTest qualified\n"
        "import Test.Tasty (defaultMain, testGroup)\n"
        "main :: IO ()\n"
        'main = defaultMain (testGroup "installed public commands"'
        " [PublicMutationTest.tests, PublicCreationTest.tests])\n"
    )
    (consumer / "cabal.project").write_text(
        f"packages: . ../archives/libtmux-haskell-{version}.tar.gz\n"
        "index-state: 2026-11-06T00:00:00Z\ntests: False\n"
    )
    (consumer / "consumer.cabal").write_text(
        "cabal-version: 3.18\nname: public-mutations-consumer\nversion: 0.0.0\n"
        "build-type: Simple\n"
        "executable public-mutations-consumer\n"
        "  main-is: Main.hs\n"
        "  other-modules: Fixture PublicMutationTest PublicCreationTest\n"
        "  default-language: GHC2024\n"
        "  default-extensions: OverloadedRecordDot OverloadedStrings DuplicateRecordFields"
        " NoFieldSelectors\n"
        "  ghc-options: -Wall -Werror -threaded\n"
        "  c-sources: fixture-watch.c\n"
        "  cc-options: -std=c11 -Wall -Wextra\n"
        "  build-depends: base >=4.22 && <4.23, async, bytestring, directory, filepath,\n"
        f"    libtmux-haskell ^>={version}, os-string, tasty, tasty-hunit, text, typed-process,"
        " unix\n"
    )
    target = "exe:public-mutations-consumer"
    run(["cabal", "build", target, "--offline"], consumer, BUILD)
    executable = subprocess.check_output(
        ["cabal", "list-bin", target, "--offline"], cwd=consumer, text=True, timeout=QUICK
    ).strip()
    result = subprocess.run(
        [executable, "--hide-successes"],
        cwd=directory,
        check=True,
        capture_output=True,
        timeout=BUILD,
    )
    if result.stderr:
        raise ValueError("Installed public mutation consumer emitted stderr")
    print("PASS: installed public command behavior and recovery")


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
    result = subprocess.run(
        command, cwd=consumer, capture_output=True, text=True, check=False, timeout=BUILD
    )
    if result.returncode:
        raise ValueError(f"Haddock example execution failed: {result.stderr}")
    expected = "".join(output for _, output in examples)
    if result.stdout != expected or result.stderr:
        raise ValueError(f"Haddock example output differs: {result.stdout!r}; {result.stderr!r}")
    executed = sum(not expression.startswith(":") for expression, _ in examples)
    print(f"PASS: {executed} Haddock examples")


if __name__ == "__main__":
    main()
