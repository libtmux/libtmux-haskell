# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Generate the option and hook catalogue from pinned tmux tables."""

import argparse
import ast
import hashlib
import json
import re
import sys
import tempfile
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "internal/LibTmux/Internal/OptionTable.hs"
SOURCES = Path(__file__).with_name("sources.json")
sys.path.append(str(Path(__file__).resolve().parents[1] / "bounded"))

from bounded import run

TABLE_HEADER = "const struct options_table_entry options_table[] = {"
TOKENS = re.compile(
    r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[A-Za-z_][A-Za-z_0-9]*|[^\s]',
    re.DOTALL,
)
SCOPES = {
    "SERVER": "ServerScope",
    "SESSION": "SessionScope",
    "WINDOW": "WindowScope",
    "PANE": "PaneScope",
}
KINDS = {
    "STRING": "StringKind",
    "NUMBER": "NumberKind",
    "KEY": "KeyKind",
    "COLOUR": "ColourKind",
    "FLAG": "FlagKind",
    "CHOICE": "ChoiceKind",
    "COMMAND": "CommandKind",
}
FLAGS = {"IS_ARRAY", "IS_HOOK", "IS_STYLE", "IS_COLOUR"}


@dataclass(frozen=True)
class Source:
    """The revision and exact source bytes for one released tmux."""

    version: str
    commit: str
    sha256: str


@dataclass(frozen=True)
class Entry:
    """Fields from a single expanded table initializer."""

    kind: str
    scopes: tuple[str, ...]
    flags: frozenset[str]
    choices: tuple[str, ...]


type Revision = tuple[str, tuple[str, Entry] | None]


def tokenize(text: str) -> list[str]:
    """Keep C strings intact while discarding comments."""
    return [token for token in TOKENS.findall(text) if not token.startswith(("/*", "//"))]


def separated(tokens: list[str]) -> Iterator[list[str]]:
    """Split C entries at commas outside strings and nested expressions."""
    opening = {"{": "}", "[": "]", "(": ")"}
    stack: list[str] = []
    start = 0
    for index, token in enumerate(tokens):
        if token in opening:
            stack.append(opening[token])
        elif token in opening.values():
            if not stack or stack.pop() != token:
                raise ValueError(f"unbalanced C token {token}")
        elif token == "," and not stack:
            yield tokens[start:index]
            start = index + 1
    if stack:
        raise ValueError("unclosed C initializer")
    if start < len(tokens):
        yield tokens[start:]


def fields(initializer: list[str]) -> dict[str, list[str]]:
    """Read the named fields of one table entry."""
    if initializer[:1] != ["{"] or initializer[-1:] != ["}"]:
        raise ValueError(f"expected a C table initializer: {initializer}")
    result: dict[str, list[str]] = {}
    for part in separated(initializer[1:-1]):
        if len(part) < 4 or part[0] != "." or part[2] != "=" or part[1] in result:
            raise ValueError(f"unexpected designated field: {part}")
        result[part[1]] = part[3:]
    return result


def string_literals(tokens: list[str]) -> str:
    """Concatenate adjacent C strings in a name or choice."""
    if not tokens or any(not token.startswith('"') for token in tokens):
        raise ValueError(f"expected C string literals: {tokens}")
    decoded = "".join(ast.literal_eval(token) for token in tokens)
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9-]*", decoded):
        raise ValueError(f"unrecognized catalogue name or choice: {decoded!r}")
    return decoded


def symbols(tokens: list[str]) -> tuple[str, ...]:
    """Read one native option constant or a union of constants."""
    prefix = "OPTIONS_TABLE_"
    if len(tokens) % 2 != 1 or tokens[1::2] != ["|"] * (len(tokens) // 2):
        raise ValueError(f"unrecognized option constants: {tokens}")
    if any(not token.startswith(prefix) for token in tokens[::2]):
        raise ValueError(f"unrecognized option constant: {tokens}")
    return tuple(token.removeprefix(prefix) for token in tokens[::2])


def parse(source: str) -> dict[str, Entry]:
    """Read the expanded table including choice arrays and its final sentinel."""
    prefix, found, tail = source.partition(TABLE_HEADER)
    table, ended, remaining = tail.rpartition("};")
    if not found or not ended or remaining.strip():
        raise ValueError("could not locate the tmux option table")
    choices = {
        name: tuple(string_literals(row) for row in separated(tokenize(body)) if row != ["NULL"])
        for name, body in re.findall(r"(options_table_\w+_list)\[\]\s*=\s*\{([^{}]+)\}", prefix)
    }
    initializers = list(separated(tokenize(table)))
    if not initializers or fields(initializers.pop()) != {"name": ["NULL"]}:
        raise ValueError("option table is missing its sentinel")

    result: dict[str, Entry] = {}
    for initializer in initializers:
        data = fields(initializer)
        if not {"name", "type", "scope"} <= data.keys():
            raise ValueError("table entry lacks its name, type or scope")
        name = string_literals(data["name"])
        (kind,) = symbols(data["type"])
        scope = symbols(data["scope"])
        flags = frozenset(symbols(data["flags"])) if "flags" in data else frozenset()
        if name in result or kind not in KINDS or not flags <= FLAGS:
            raise ValueError(f"unsupported or duplicate table definition for {name}")
        allowed = choices[data["choices"][0]] if "choices" in data else ()
        if (kind == "CHOICE") != bool(allowed) or not scope or not set(scope) <= SCOPES.keys():
            raise ValueError(f"unrecognized choices or scopes for {name}")
        if "IS_HOOK" in flags and (kind != "COMMAND" or "IS_ARRAY" not in flags):
            raise ValueError(f"invalid hook declaration for {name}")
        result[name] = Entry(kind, scope, flags, allowed)
    return result


def preprocess(source: bytes, compiler: str, temporary: Path) -> str:
    """Expand tmux's macros without importing platform headers."""
    text = source.decode()
    if re.search(r"^\s*#\s*(?:if|elif|else|endif)", text, re.MULTILINE):
        raise ValueError("qualify conditional C definitions before changing the source pins")
    temporary.write_text(re.sub(r"^\s*#\s*include[^\n]*$", "", text, flags=re.MULTILINE))
    return run(
        [compiler, "-E", "-P", "-undef", "-x", "c", temporary],
        timeout=3,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def source_bytes(checkout: Path, pin: Source) -> bytes:
    """Read a pinned git object and verify the table's digest."""
    if not re.fullmatch(r"[0-9a-f]{40}", pin.commit) or not re.fullmatch(
        r"[0-9a-f]{64}", pin.sha256
    ):
        raise ValueError(f"invalid tmux source pin for {pin.version}")
    content = run(
        ["git", "show", f"{pin.commit}:options-table.c"],
        cwd=checkout,
        timeout=3,
        check=True,
        capture_output=True,
    ).stdout
    if hashlib.sha256(content).hexdigest() != pin.sha256:
        raise ValueError(f"tmux {pin.version} source digest changed")
    return content


def histories(releases: list[tuple[str, dict[str, Entry]]]) -> dict[str, list[Revision]]:
    """Retain additions, changed shapes and removals in release order."""
    result: dict[str, list[Revision]] = {}
    previous: dict[str, tuple[str, Entry]] = {}
    for release, entries in releases:
        current = {
            name: (previous[name][0] if name in previous else release, entry)
            for name, entry in entries.items()
        }
        for name in previous.keys() | current.keys():
            if previous.get(name) != current.get(name):
                result.setdefault(name, []).append((release, current.get(name)))
        previous = current
    return result


def render_entry(entry: Entry) -> str:
    """Render a validated entry using closed Haskell constructors."""
    scope = "[" + ", ".join(SCOPES[name] for name in entry.scopes) + "]"
    if "IS_HOOK" in entry.flags:
        return f"Hook {scope}"
    kind = KINDS[entry.kind]
    if "IS_STYLE" in entry.flags:
        kind = "StyleKind"
    if "IS_COLOUR" in entry.flags:
        kind = "ColourStringKind"
    shape = "Array" if "IS_ARRAY" in entry.flags else "Scalar"
    choices = json.dumps(entry.choices)
    return f"Option {kind} {scope} {shape} {choices}"


HEADER = """-- Generated by scripts/generate_options/generate_options.py.
-- Source revisions and table digests are in scripts/generate_options/sources.json.
module LibTmux.Internal.OptionTable
  ( OptionScope (..), OptionKind (..), OptionShape (..), Definition (..), definitions )
  where

import Data.Text (Text)

-- | The scope declared by tmux's option table.
data OptionScope = ServerScope | SessionScope | WindowScope | PaneScope
  deriving stock (Eq, Ord, Show)

-- | The option's native value type. Text stored as a style or theme colour
-- uses its own kind, preserving the native flags.
data OptionKind
  = StringKind | NumberKind | KeyKind | ColourKind | FlagKind | ChoiceKind
  | CommandKind | StyleKind | ColourStringKind
  deriving stock (Eq, Ord, Show)

-- | An option holds one value or a keyed collection.
data OptionShape = Scalar | Array
  deriving stock (Eq, Ord, Show)

data Definition = Option !OptionKind ![OptionScope] !OptionShape ![Text] | Hook ![OptionScope]

definitions :: [(Text, [(Text, Maybe (Text, Definition))])]
definitions =
"""


def render(history: dict[str, list[Revision]]) -> str:
    """Produce a stable data-only Haskell module."""
    lines = []
    for name, revisions in sorted(history.items()):
        versions = []
        for version, definition in revisions:
            value = "Nothing"
            if definition is not None:
                since, entry = definition
                value = f'Just ("{since}", {render_entry(entry)})'
            versions.append(f'("{version}", {value})')
        lines.append(f'("{name}", [{", ".join(versions)}])')
    return HEADER + "  [ " + "\n  , ".join(lines) + "\n  ]\n"


def source_order(pin: Source) -> tuple[int, int, str]:
    """Order stable versions as tmux does, including patch letters."""
    match = re.fullmatch(r"([0-9]+)\.([0-9]+)([a-z]?)", pin.version)
    if match is None:
        raise ValueError(f"invalid pinned stable release: {pin.version}")
    return int(match[1]), int(match[2]), match[3]


def main() -> None:
    """Generate or check the table using the specified local tmux checkout."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--tmux", type=Path, required=True, help="tmux git checkout with pinned commits"
    )
    parser.add_argument("--cc", default="cc", help="C preprocessor command")
    parser.add_argument(
        "--check", action="store_true", help="fail when the generated table differs"
    )
    args = parser.parse_args()
    pins = [Source(**record) for record in json.loads(SOURCES.read_text())]
    versions = [source_order(pin) for pin in pins]
    if not versions or versions != sorted(set(versions)):
        raise ValueError("source pins must contain unique releases in ascending order")
    with tempfile.TemporaryDirectory() as temporary:
        table = Path(temporary) / "options-table.c"
        releases = [
            (pin.version, parse(preprocess(source_bytes(args.tmux, pin), args.cc, table)))
            for pin in pins
        ]
    generated = render(histories(releases))
    if args.check:
        if OUTPUT.read_text() != generated:
            raise SystemExit("Regenerate the option table from the pinned tmux checkout")
    else:
        OUTPUT.write_text(generated)
    print(f"Checked {len(releases)} pinned tmux option tables")


if __name__ == "__main__":
    main()
