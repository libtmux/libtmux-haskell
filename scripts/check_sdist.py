"""Build and execute public consumers from the core source archive."""

from pathlib import Path
import json
import re
import subprocess
import tarfile
import tempfile
from check_docs import check as check_docs
from prepare_haddock import _modules

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "libtmux-haskell.cabal"


def run(args, cwd):
    subprocess.run(args, cwd=cwd, check=True)


def main():
    examples = check_docs()
    version = re.search(r"^version:\s*(\S+)", MANIFEST.read_text(), re.MULTILINE).group(1)
    with tempfile.TemporaryDirectory(prefix="libtmux-haskell-consumer-") as directory:
        directory = Path(directory)
        archives = directory / "archives"
        run(["cabal", "sdist", "all", "--output-directory=" + str(archives)], ROOT)
        archive = archives / f"libtmux-haskell-{version}.tar.gz"
        with tarfile.open(archive) as source:
            for member in source.getmembers():
                name = Path(member.name)
                if name.is_absolute() or ".." in name.parts:
                    raise ValueError("Unsafe source archive member")
                if member.isfile():
                    local = ROOT.joinpath(*name.parts[1:])
                    if source.extractfile(member).read() != local.read_bytes():
                        raise ValueError(f"Archive member differs from source: {local.name}")
            prefix = f"libtmux-haskell-{version}/"
            doctests = []
            doctest_modules = []
            for module in sorted(_modules(MANIFEST)[0]):
                path = "src/" + module.replace(".", "/") + ".hs"
                examples_in_module = haddock_examples(source.extractfile(prefix + path).read().decode())
                if examples_in_module:
                    doctest_modules.append(module)
                    doctests.extend(examples_in_module)
            for index, entry in enumerate(examples):
                consumer = directory / entry["id"]
                consumer.mkdir()
                check_example_consumer(entry, consumer, f"../archives/libtmux-haskell-{version}.tar.gz",
                                       lambda path: source.extractfile(prefix + path).read())
                if index == 0:
                    check_haddock_examples(consumer, doctest_modules, doctests)
            check_installation_pin(directory, examples)
            check_public_commands(source, prefix, directory, version)
        print("PASS: archive members, documented public example and Haddock examples")


def check_installation_pin(directory, examples):
    """Run current programs against the source revision offered for installation."""
    project = (ROOT / next(entry["vcs_project"] for entry in examples if entry["id"] == "capture-graph")).read_text()
    pins = re.findall(r"^\s+tag:\s+([a-f0-9]{40})\s*$", project, re.MULTILINE)
    if len(pins) != 1:
        raise ValueError("Installation must name one reviewed source revision")
    pin = pins[0]
    run(["git", "merge-base", "--is-ancestor", pin, "HEAD"], ROOT)
    manifest = subprocess.check_output(["git", "show", pin + ":libtmux-haskell.cabal"], cwd=ROOT, text=True)
    version = re.search(r"^version:\s*(\S+)", manifest, re.MULTILINE).group(1)
    name = f"libtmux-haskell-{version}"
    archive = directory / (name + ".tar.gz")
    archive.write_bytes(subprocess.check_output(
        ["git", "archive", "--format=tar.gz", "--prefix=" + name + "/", pin], cwd=ROOT))
    for entry in examples:
        consumer = directory / ("installation-" + entry["id"])
        consumer.mkdir()
        check_example_consumer(entry, consumer, "../" + archive.name,
                               lambda path: (ROOT / path).read_bytes())
    print("PASS: documented installation pin supports the current public examples")


def check_example_consumer(entry, consumer, library, read_source):
    for field in ["source", "package", *(["runner", "stdout"] if "runner" in entry else [])]:
        (consumer / Path(entry[field]).name).write_bytes(read_source(entry[field]))
    (consumer / "cabal.project").write_text(
        f"packages: . {library}\nindex-state: 2026-11-06T00:00:00Z\ntests: False\n")
    target = "exe:" + entry["executable"]
    run(["cabal", "build", target, "--offline"], consumer)
    executable = subprocess.check_output(
        ["cabal", "list-bin", target, "--offline"], cwd=consumer, text=True).strip()
    command = (["python3", str(consumer / Path(entry["runner"]).name), "--program", executable]
               if "runner" in entry else [executable])
    if "fixture_panes" in entry:
        command += ["--expected-panes", str(entry["fixture_panes"])]
    result = subprocess.run(command, cwd=consumer.parent, check=True, capture_output=True)
    if result.stdout != read_source(entry["stdout"]) or result.stderr:
        raise ValueError("Installed example produced unexpected output")


def check_public_commands(source, prefix, directory, version):
    """Run public command cases against the archive, without private imports."""
    consumer = directory / "public-mutations"
    consumer.mkdir()
    for origin, name in [
        ("test/integration/PublicMutationTest.hs", "PublicMutationTest.hs"),
        ("test/integration/PublicCreationTest.hs", "PublicCreationTest.hs"),
        ("test-support/Fixture.hs", "Fixture.hs"),
        ("test-support/fixture-watch.c", "fixture-watch.c"),
    ]:
        (consumer / name).write_bytes(source.extractfile(prefix + origin).read())
    (consumer / "Main.hs").write_text(
        "module Main (main) where\n"
        "import PublicMutationTest qualified\n"
        "import PublicCreationTest qualified\n"
        "import Test.Tasty (defaultMain, testGroup)\n"
        "main :: IO ()\n"
        "main = defaultMain (testGroup \"installed public commands\" [PublicMutationTest.tests, PublicCreationTest.tests])\n"
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
        "  default-extensions: OverloadedRecordDot OverloadedStrings DuplicateRecordFields NoFieldSelectors\n"
        "  ghc-options: -Wall -Werror -threaded\n"
        "  c-sources: fixture-watch.c\n"
        "  cc-options: -std=c11 -Wall -Wextra\n"
        "  build-depends: base >=4.22 && <4.23, async, bytestring, directory, filepath,\n"
        f"    libtmux-haskell ^>={version}, os-string, tasty, tasty-hunit, text, typed-process, unix\n"
    )
    target = "exe:public-mutations-consumer"
    run(["cabal", "build", target, "--offline"], consumer)
    executable = subprocess.check_output(
        ["cabal", "list-bin", target, "--offline"], cwd=consumer, text=True
    ).strip()
    result = subprocess.run([executable, "--hide-successes"], cwd=directory, check=True, capture_output=True)
    if result.stderr:
        raise ValueError("Installed public mutation consumer emitted stderr")
    print("PASS: installed public command behavior and recovery")


def haddock_examples(source):
    lines = source.splitlines()
    examples = []
    for index, line in enumerate(lines):
        if not line.startswith("-- >>> "):
            continue
        command = line.removeprefix("-- >>> ")
        expected = []
        for following in lines[index + 1:]:
            if not following.startswith("-- ") or following.startswith("-- >>> "):
                break
            expected.append(following.removeprefix("-- "))
        examples.append((command, "\n".join(expected) + ("\n" if expected else "")))
    return examples


def check_haddock_examples(consumer, modules, examples):
    if not examples or not any(not command.startswith(":") for command, _ in examples):
        raise ValueError("No executable Haddock examples")
    plan = json.loads((consumer / "dist-newstyle/cache/plan.json").read_text())
    units = {name: [item["id"] for item in plan["install-plan"] if item["pkg-name"] == name]
             for name in ["base", "libtmux-haskell"]}
    if any(len(matches) != 1 for matches in units.values()):
        raise ValueError("Haddock consumer needs one exact base/library unit")
    command = ["cabal", "exec", "--offline", "-v0", "--", "ghc", "-v0", "-ignore-dot-ghci",
               "-XGHC2024", "-hide-all-packages", "-package-id", units["base"][0],
               "-package-id", units["libtmux-haskell"][0], "-e",
               ":module + " + " ".join(modules)]
    for expression, _ in examples:
        if expression.startswith(":") and expression != ":set -XOverloadedStrings":
            raise ValueError("Unknown Haddock setup directive")
        command.extend(["-e", expression])
    result = subprocess.run(command, cwd=consumer, capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f"Haddock example execution failed: {result.stderr}")
    expected = "".join(output for _, output in examples)
    if result.stdout != expected or result.stderr:
        raise ValueError(f"Haddock example output differs: {result.stdout!r}; {result.stderr!r}")
    print(f"PASS: {sum(not expression.startswith(':') for expression, _ in examples)} Haddock examples")


if __name__ == "__main__":
    main()
