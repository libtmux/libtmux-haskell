# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Check the example catalogue, displayed source/output and local guide links."""

import argparse
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.append(str(Path(__file__).resolve().parents[1] / "bounded"))

from bounded import run

MARKER = re.compile(
    r"<!-- example(?P<kind>-output|-project|-package)?: (?P<id>[^ ]+) -->\n"
    r"```(?P<language>[^\n]+)\n(?P<body>.*?)```",
    re.DOTALL,
)

# Seconds a documented command may run unless its catalogue entry sets "timeout".
DEFAULT_TIMEOUT = 120
MAX_TIMEOUT = 900

type Entry = dict[str, Any]


def check_workflow(proof: dict[str, Any], root: Path = ROOT) -> None:
    """Resolve a literal named job/step/command in the repository's CI layout."""
    source = (root / proof["workflow"]).read_text()
    jobs = list(re.finditer(r"^  ([\w-]+):\s*$", source, re.MULTILINE))
    job = next((match for match in jobs if match[1] == proof["job"]), None)
    if job is None:
        raise ValueError("Example workflow job does not exist")
    end = next((match.start() for match in jobs if match.start() > job.start()), len(source))
    body = source[job.end() : end]
    steps = list(re.finditer(r"^      - (.*)$", body, re.MULTILINE))
    step = next((match for match in steps if match[1] == "name: " + proof["step"]), None)
    if step is None:
        raise ValueError("Example workflow step does not exist in its job")
    end = next((match.start() for match in steps if match.start() > step.start()), len(body))
    command = re.search(r"^        run: (.+)$", body[step.end() : end], re.MULTILINE)
    if command is None or shlex.split(command[1]) != proof["command"]:
        raise ValueError("Example workflow command differs from its declaration")


def check_catalogue(root: Path) -> dict[str, Entry]:
    """Validate the catalogue entries and return them by identifier."""
    document = json.loads((root / "examples/catalogue.json").read_text())
    if set(document) != {"schema", "examples"} or document["schema"] != "libtmux.examples/1":
        raise ValueError("Unknown example catalogue schema")
    entries: list[Entry] = document["examples"]
    if not entries:
        raise ValueError("No declared examples")
    examples: dict[str, Entry] = {}
    paths = {"source", "package", "project", "vcs_project", "stdout"}
    fields = paths | {"id", "executable", "capability", "command", "verification"}
    optional = {"runner", "fixture_panes", "timeout"}
    for entry in entries:
        keys = set(entry)
        if (
            not fields <= keys <= fields | optional
            or ("fixture_panes" in keys and "runner" not in keys)
            or entry["id"] in examples
        ):
            raise ValueError("Invalid or duplicate example entry")
        timeout = entry.get("timeout", DEFAULT_TIMEOUT)
        if type(timeout) is not int or not 1 <= timeout <= MAX_TIMEOUT:
            raise ValueError(f"Invalid example timeout for {entry['id']}")
        for key in paths | ({"runner"} if "runner" in entry else set()):
            path = Path(entry[key])
            if path.is_absolute() or ".." in path.parts or not (root / path).is_file():
                raise ValueError(f"Missing or invalid {key} for {entry['id']}")
        if Path(entry["source"]).parts != ("examples", entry["id"], "Main.hs"):
            raise ValueError("An example must have one Main.hs in its own directory")
        if "runner" in entry:
            runner = Path(entry["runner"]).parts
            if (
                len(runner) != 3
                or runner[0] != "examples"
                or runner[2] != "run.py"
                or not any(
                    owner["id"] == runner[1] and owner.get("runner") == entry["runner"]
                    for owner in entries
                )
            ):
                raise ValueError("An example runner must belong to a declared example directory")
            command = ["python3", entry["runner"]]
            if runner[1] != entry["id"]:
                command += [
                    "--executable",
                    entry["executable"],
                    "--expected-output",
                    entry["stdout"],
                ]
            if "fixture_panes" in entry:
                panes = entry["fixture_panes"]
                if type(panes) is not int or not 1 <= panes <= 10000:
                    raise ValueError("Invalid example physical pane count")
                command += ["--expected-panes", str(panes)]
            if entry["command"] != command:
                raise ValueError("An example command must execute its declared runner")
        examples[entry["id"]] = entry
        proof = entry["verification"]
        if set(proof) != {"workflow", "job", "step", "command", "checks"}:
            raise ValueError("Missing example execution provenance")
        if not (root / proof["workflow"]).is_file() or not proof["job"] or not proof["step"]:
            raise ValueError("Invalid example workflow locator")
        if set(proof["checks"]) != {"exit-status", "stdout", "stderr-empty", "archive-consumer"}:
            raise ValueError("Incomplete example result checks")
        if not entry["command"] or not proof["command"] or not entry["executable"]:
            raise ValueError("Missing example execution command")
        check_workflow(proof, root)
    discovered = {
        str(path.relative_to(root))
        for path in (root / "examples").rglob("*")
        if path.suffix in {".hs", ".lhs"}
    }
    if discovered != {entry["source"] for entry in entries}:
        raise ValueError("Declared and discovered example programs differ")
    return examples


def check_documents(root: Path, examples: dict[str, Entry]) -> None:
    """Check displayed assets, unregistered Haskell fences and local links."""
    documents = [
        root / "README.md",
        *sorted((root / "docs").rglob("*.md")),
        *sorted((root / ".github").rglob("*.md")),
        *sorted((root / "examples").rglob("*.md")),
        root / "AGENTS.md",
    ]
    seen: set[tuple[str, str]] = set()
    required = {
        "": ("source", "haskell"),
        "-output": ("stdout", "text"),
        "-project": ("vcs_project", "cabal"),
        "-package": ("package", "cabal"),
    }
    for path in documents:
        text = path.read_text()
        markers = list(MARKER.finditer(text))
        if text.count("<!-- example") != len(markers):
            raise ValueError(f"Malformed example marker in {path.name}")
        for fence in re.finditer(
            r"^ {0,3}(?:`{3,}|~{3,})[ \t]*(?:haskell|hs)(?=[ \t\r\n])[^\n]*",
            text,
            re.MULTILINE | re.IGNORECASE,
        ):
            if not any(marker.start() <= fence.start() < marker.end() for marker in markers):
                raise ValueError(f"Unregistered Haskell example in {path.relative_to(root)}")
        for match in markers:
            kind, name = match["kind"] or "", match["id"]
            if name not in examples:
                raise ValueError(f"Unknown example {name} in {path.name}")
            field, language = required[kind]
            source = root / examples[name][field]
            if match["language"] != language or match["body"] != source.read_text():
                raise ValueError(f"{path.name}: {name} {field} differs from its source")
            seen.add((name, kind))
        targets = re.findall(r"\]\(([^)]+)\)", text)
        for attribute, value in re.findall(
            r"""\b(src|srcset|href)\s*=\s*["']([^"']+)["']""", text, re.IGNORECASE
        ):
            if attribute.lower() == "srcset":
                targets.extend(part.split()[0] for part in value.split(",") if part.strip())
            else:
                targets.append(value)
        for target in targets:
            if "://" in target or target.startswith("#"):
                continue
            if not (path.parent / target.split("#")[0]).is_file():
                raise ValueError(f"Broken local link in {path.name}: {target}")
    if not {(name, kind) for name in examples for kind in ["", "-output"]} <= seen:
        raise ValueError("An example has no displayed source or expected output")


def check(root: Path = ROOT) -> list[Entry]:
    """Validate the catalogue and documents under ``root``; return its entries."""
    examples = check_catalogue(root)
    check_documents(root, examples)
    return list(examples.values())


def run_entry(entry: Entry, root: Path = ROOT) -> None:
    """Run one documented command and compare its exit status, stdout and stderr.

    The command is stopped after the entry's ``timeout`` seconds, or ``DEFAULT_TIMEOUT``.
    """
    timeout = entry.get("timeout", DEFAULT_TIMEOUT)
    try:
        result = run(entry["command"], cwd=root, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise ValueError(
            f"Documented command timed out after {timeout} s: {entry['id']}"
        ) from error
    expected = (root / entry["stdout"]).read_bytes()
    if result.returncode or result.stdout != expected or result.stderr:
        raise ValueError(
            f"Documented command failed: {entry['id']}; exit={result.returncode}; "
            f"stdout={result.stdout!r}; stderr={result.stderr!r}"
        )


def main() -> None:
    """Run the checks, and with ``--run`` execute each documented command."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--run", action="store_true", help="execute documented commands after provisioning"
    )
    args = parser.parse_args()
    entries = check()
    if args.run:
        for entry in entries:
            run_entry(entry)
    print(f"PASS: {len(entries)} declared example, displayed assets and local guide links")


if __name__ == "__main__":
    main()
