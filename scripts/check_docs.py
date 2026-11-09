"""Check the example catalogue, displayed source/output and local guide links."""

import argparse
import json
from pathlib import Path
import re
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CATALOGUE = ROOT / "examples/catalogue.json"
MARKER = re.compile(
    r"<!-- example(?P<kind>-output|-project|-package)?: (?P<id>[^ ]+) -->\n"
    r"```(?P<language>[^\n]+)\n(?P<body>.*?)```", re.DOTALL)


def check_workflow(proof):
    """Resolve a literal named job/step/command in the repository's CI layout."""
    source = (ROOT / proof["workflow"]).read_text()
    jobs = list(re.finditer(r"^  ([\w-]+):\s*$", source, re.MULTILINE))
    job = next((match for match in jobs if match[1] == proof["job"]), None)
    if job is None:
        raise ValueError("Example workflow job does not exist")
    end = next((match.start() for match in jobs if match.start() > job.start()), len(source))
    body = source[job.end():end]
    steps = list(re.finditer(r"^      - (.*)$", body, re.MULTILINE))
    step = next((match for match in steps if match[1] == "name: " + proof["step"]), None)
    if step is None:
        raise ValueError("Example workflow step does not exist in its job")
    end = next((match.start() for match in steps if match.start() > step.start()), len(body))
    command = re.search(r"^        run: (.+)$", body[step.end():end], re.MULTILINE)
    if command is None or shlex.split(command[1]) != proof["command"]:
        raise ValueError("Example workflow command differs from its declaration")


def check():
    document = json.loads(CATALOGUE.read_text())
    if set(document) != {"schema", "examples"} or document["schema"] != "libtmux.examples/1":
        raise ValueError("Unknown example catalogue schema")
    entries = document["examples"]
    if not entries:
        raise ValueError("No declared examples")
    examples = {}
    paths = {"source", "package", "project", "vcs_project", "stdout"}
    fields = paths | {"id", "executable", "capability", "command", "verification"}
    for entry in entries:
        if set(entry) not in [fields, fields | {"runner"}] or entry["id"] in examples:
            raise ValueError("Invalid or duplicate example entry")
        for key in paths | ({"runner"} if "runner" in entry else set()):
            path = Path(entry[key])
            if path.is_absolute() or ".." in path.parts or not (ROOT / path).is_file():
                raise ValueError(f"Missing or invalid {key} for {entry['id']}")
        if Path(entry["source"]).parts != ("examples", entry["id"], "Main.hs"):
            raise ValueError("An example must have one Main.hs in its own directory")
        if "runner" in entry:
            runner = Path(entry["runner"]).parts
            if (len(runner) != 3 or runner[0] != "examples" or runner[2] != "run.py"
                    or not any(owner["id"] == runner[1] and owner.get("runner") == entry["runner"]
                               for owner in entries)):
                raise ValueError("An example runner must belong to a declared example directory")
            command = ["python3", entry["runner"]]
            if runner[1] != entry["id"]:
                command += ["--executable", entry["executable"], "--expected-output", entry["stdout"]]
            if entry["command"] != command:
                raise ValueError("An example command must execute its declared runner")
        examples[entry["id"]] = entry
        proof = entry["verification"]
        if set(proof) != {"workflow", "job", "step", "command", "checks"}:
            raise ValueError("Missing example execution provenance")
        if not (ROOT / proof["workflow"]).is_file() or not proof["job"] or not proof["step"]:
            raise ValueError("Invalid example workflow locator")
        if set(proof["checks"]) != {"exit-status", "stdout", "stderr-empty", "archive-consumer"}:
            raise ValueError("Incomplete example result checks")
        if not entry["command"] or not proof["command"] or not entry["executable"]:
            raise ValueError("Missing example execution command")
        check_workflow(proof)
    discovered = {str(path.relative_to(ROOT)) for path in (ROOT / "examples").rglob("*")
                  if path.suffix in {".hs", ".lhs"}}
    if discovered != {entry["source"] for entry in entries}:
        raise ValueError("Declared and discovered example programs differ")

    documents = [ROOT / "README.md", *sorted((ROOT / "docs").rglob("*.md")),
                 *sorted((ROOT / ".github").rglob("*.md")),
                 *sorted((ROOT / "examples").rglob("*.md")), ROOT / "AGENTS.md"]
    seen = set()
    required = {"": ("source", "haskell"), "-output": ("stdout", "text"),
                "-project": ("vcs_project", "cabal"), "-package": ("package", "cabal")}
    for path in documents:
        text = path.read_text()
        markers = list(MARKER.finditer(text))
        if text.count("<!-- example") != len(markers):
            raise ValueError(f"Malformed example marker in {path.name}")
        for fence in re.finditer(r"^ {0,3}(?:`{3,}|~{3,})[ \t]*(?:haskell|hs)(?=[ \t\r\n])[^\n]*",
                                 text, re.MULTILINE | re.IGNORECASE):
            if not any(marker.start() <= fence.start() < marker.end() for marker in markers):
                raise ValueError(f"Unregistered Haskell example in {path.relative_to(ROOT)}")
        for match in markers:
            kind, name = match["kind"] or "", match["id"]
            if name not in examples:
                raise ValueError(f"Unknown example {name} in {path.name}")
            field, language = required[kind]
            if match["language"] != language or match["body"] != (ROOT / examples[name][field]).read_text():
                raise ValueError(f"{path.name}: {name} {field} differs from its source")
            seen.add((name, kind))
        targets = re.findall(r"\]\(([^)]+)\)", text)
        for attribute, value in re.findall(r'''\b(src|srcset|href)\s*=\s*["']([^"']+)["']''', text, re.IGNORECASE):
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
    return entries


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="execute documented commands after provisioning")
    args = parser.parse_args()
    entries = check()
    if args.run:
        for entry in entries:
            result = subprocess.run(entry["command"], cwd=ROOT, capture_output=True)
            if result.returncode or result.stdout != (ROOT / entry["stdout"]).read_bytes() or result.stderr:
                raise ValueError(f"Documented command failed: {entry['id']}; exit={result.returncode}; "
                                 f"stdout={result.stdout!r}; stderr={result.stderr!r}")
    print(f"PASS: {len(entries)} declared example, displayed assets and local guide links")
