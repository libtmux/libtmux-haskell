"""Build and execute a public consumer from the core source archive."""

from pathlib import Path
import json
import re
import subprocess
import tarfile
import tempfile
from check_docs import check as check_docs

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
            for path in ["src/LibTmux/Id.hs", "src/LibTmux/Value.hs", "src/LibTmux/Version.hs"]:
                doctests.extend(haddock_examples(source.extractfile(prefix + path).read().decode()))
            for index, entry in enumerate(examples):
                consumer = directory / entry["id"]
                consumer.mkdir()
                for field in ["source", "package"]:
                    (consumer / Path(entry[field]).name).write_bytes(source.extractfile(prefix + entry[field]).read())
                if "runner" in entry:
                    for field in ["runner", "stdout"]:
                        (consumer / Path(entry[field]).name).write_bytes(source.extractfile(prefix + entry[field]).read())
                expected = source.extractfile(prefix + entry["stdout"]).read()
                (consumer / "cabal.project").write_text(
                    f"packages: . ../archives/libtmux-haskell-{version}.tar.gz\nindex-state: 2026-11-06T00:00:00Z\ntests: False\n")
                target = "exe:" + entry["executable"]
                run(["cabal", "build", target, "--offline"], consumer)
                executable = subprocess.check_output(
                    ["cabal", "list-bin", target, "--offline"], cwd=consumer, text=True).strip()
                command = (["python3", str(consumer / Path(entry["runner"]).name), "--program", executable]
                           if "runner" in entry else [executable])
                result = subprocess.run(command, cwd=directory, check=True, capture_output=True)
                if result.stdout != expected or result.stderr:
                    raise ValueError("Archive example produced unexpected output")
                if index == 0:
                    check_haddock_examples(consumer, doctests)
        print("PASS: archive members, documented public example and Haddock examples")


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


def check_haddock_examples(consumer, examples):
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
               ":module + LibTmux.Id LibTmux.Value LibTmux.Version"]
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
