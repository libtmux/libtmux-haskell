# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Prepare a separate, link-checked copy of Haddock 2.33.0 HTML.

Raw artifacts remain authoritative. This compatibility step repairs
navigation and contains wide native sections within the default theme.
It neither changes the compiled interface nor establishes source freshness.
"""

import argparse
import hashlib
import json
import posixpath
import re
import shutil
import tempfile
from collections import Counter, defaultdict
from collections.abc import Collection, Iterable, Iterator, Mapping, Sequence
from html import escape
from html.parser import HTMLParser
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[2]
type Edit = tuple[int, int, str]
type Link = tuple[str, str]
type FieldTargets = dict[tuple[str, str], str]

VOID = {
    "area",
    "base",
    "br",
    "col",
    "embed",
    "hr",
    "img",
    "input",
    "link",
    "meta",
    "param",
    "source",
    "track",
    "wbr",
}
RESPONSIVE_CSS = b"""
/* Contain long headings and wide native tables on narrow viewports. */
@media screen and (max-width: 999px) {
  #module-header .caption { overflow-wrap: anywhere; }
  #interface .subs,
  #index { overflow-x: auto; }
}
"""
SOURCE_RESPONSIVE_CSS = b"""
@media screen {
  html.libtmux-source-scroll body > pre { overflow-x: auto; }
}
span.annot span.annottext[popover] {
  position: fixed; inset: 0 auto auto 0; margin: 0; box-sizing: border-box;
  width: max-content; max-width: calc(100vw - 16px); max-height: calc(100vh - 16px);
  white-space: pre-wrap; overflow-wrap: anywhere; overflow: auto;
}
span.annot span.annottext[popover]:not(:popover-open) { display: none; }
span.annot span.annottext[popover]:popover-open { display: block; }
"""
SOURCE_SCRIPT = b"""
;(() => {
  const initialize = () => {
    if (!HTMLElement.prototype.showPopover || !document.querySelector('body > pre')) return;
    let active;
    const close = () => {
      if (active?.tooltip.matches(':popover-open')) active.tooltip.hidePopover();
      active = undefined;
    };
    document.addEventListener('pointerover', event => {
      const annotation = event.target.closest('span.annot');
      const tooltip = annotation?.querySelector(':scope > span.annottext');
      if (!tooltip || annotation === active?.annotation) return;
      close();
      tooltip.setAttribute('popover', 'manual');
      tooltip.showPopover();
      active = {annotation, tooltip};
      const anchor = annotation.getBoundingClientRect();
      const box = tooltip.getBoundingClientRect();
      const left = Math.max(8, Math.min(anchor.left, innerWidth - box.width - 8));
      const top = anchor.bottom + box.height <= innerHeight - 8
        ? anchor.bottom : Math.max(8, anchor.top - box.height);
      tooltip.style.left = `${left}px`;
      tooltip.style.top = `${top}px`;
    });
    document.addEventListener('pointerout', event => {
      if (active && !active.annotation.contains(event.relatedTarget)) close();
    });
    document.addEventListener('scroll', event => {
      if (active && !active.tooltip.contains(event.target)) close();
    }, true);
    document.addEventListener('keydown', event => { if (event.key === 'Escape') close(); });
    window.addEventListener('resize', close);
    document.documentElement.classList.add('libtmux-source-scroll');
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize, {once: true});
  else initialize();
})();
"""


class Node:
    """One parsed HTML element with its source offsets."""

    def __init__(
        self,
        tag: str,
        attrs: Iterable[tuple[str, str | None]],
        start: int,
        start_end: int,
        parent: "Node | None" = None,
    ) -> None:
        self.tag, self.parent = tag, parent
        self.attrs = {name: value or "" for name, value in attrs}
        self.start, self.start_end = start, start_end
        self.end_start, self.end = start_end, start_end
        self.children: list[Node] = []
        self.data: list[str] = []

    def has(self, name: str) -> bool:
        return name in self.attrs.get("class", "").split()

    def ancestors(self) -> Iterator["Node"]:
        parent = self.parent
        while parent is not None:
            yield parent
            parent = parent.parent

    def walk(self) -> Iterator["Node"]:
        yield self
        for child in self.children:
            yield from child.walk()

    def text(self) -> str:
        return "".join(self.data)


class Document(HTMLParser):
    """An HTML page parsed into a tree that remembers where each element sits."""

    def __init__(self, text: str) -> None:
        super().__init__(convert_charrefs=True)
        self.source = text
        self.lines = [0]
        self.lines.extend(match.end() for match in re.finditer("\n", text))
        self.root = Node("", (), 0, 0)
        self.stack = [self.root]
        self.nodes: list[Node] = []
        self.feed(text)
        self.close()
        if len(self.stack) != 1:
            raise ValueError("Unclosed native HTML element")

    def position(self) -> int:
        line, column = self.getpos()
        return self.lines[line - 1] + column

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if len(attrs) != len(dict(attrs)):
            raise ValueError("Duplicate native HTML attribute")
        start = self.position()
        node = Node(tag, attrs, start, start + len(self.get_starttag_text() or ""), self.stack[-1])
        self.stack[-1].children.append(node)
        self.nodes.append(node)
        if tag not in VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        if tag not in VOID:
            self.stack.pop()

    def handle_endtag(self, tag: str) -> None:
        if tag in VOID:
            return
        if self.stack[-1].tag != tag:
            raise ValueError(f"Unexpected native HTML closing tag: {tag}")
        node = self.stack.pop()
        node.end_start = self.position()
        node.end = self.source.index(">", node.end_start) + 1

    def handle_data(self, data: str) -> None:
        for node in self.stack:
            node.data.append(data)


def _one[T](items: Sequence[T], description: str) -> T:
    if len(items) != 1:
        raise ValueError(f"Expected one {description}; found {len(items)}")
    return items[0]


def _attribute(document: Document, node: Node, name: str, value: str | None) -> Edit:
    raw = document.source[node.start : node.start_end]
    pattern = rf'\s{re.escape(name)}="[^"]*"'
    if name in node.attrs:
        replacement = "" if value is None else f' {name}="{escape(value, quote=True)}"'
        raw, count = re.subn(pattern, lambda _: replacement, raw)
        if count != 1:
            raise ValueError(f"Unqualified native attribute encoding: {name}")
    elif value is not None:
        if not raw.endswith(">") or raw.endswith("/>"):
            raise ValueError("Unqualified native anchor shape")
        raw = raw[:-1] + f' {name}="{escape(value, quote=True)}">'
    return node.start, node.start_end, raw


def _apply(document: Document, edits: Iterable[Edit]) -> str:
    result: list[str] = []
    previous = 0
    for start, end, replacement in sorted(edits, key=lambda edit: (edit[0], edit[1])):
        if start < previous:
            raise ValueError("Overlapping native navigation edits")
        result.extend([document.source[previous:start], replacement])
        previous = end
    result.append(document.source[previous:])
    return "".join(result)


def _insert_choices(
    document: Document,
    entries: list[tuple[str, list[Link]]],
    heading: str,
    source: bool = False,
) -> Edit:
    layout = [
        node
        for node in document.nodes
        if node.tag == "div" and not any(parent.tag == "pre" for parent in node.ancestors())
    ]
    content = [node for node in layout if node.attrs.get("id") == "content"]
    footer = [node for node in layout if node.attrs.get("id") == "footer"]
    body = [node for node in document.nodes if node.tag == "body"]
    position = (
        _one(body, "source body").end_start
        if source
        else content[0].end_start
        if len(content) == 1
        else footer[0].start
        if len(footer) == 1
        else _one(body, "body").end_start
    )
    rendered = '<section class="subs"><h2>' + escape(heading) + "</h2><dl>"
    for anchor, links in entries:
        label = anchor.removeprefix("v:")
        rendered += f'<dt id="{escape(anchor, quote=True)}"><code>{escape(label)}</code></dt><dd>'
        rendered += ", ".join(
            f'<a href="#{escape(target, quote=True)}">{escape(label)}</a>'
            for target, label in links
        )
        rendered += "</dd>"
    return position, position, rendered + "</dl></section>"


def _field_edits(document: Document) -> tuple[list[Edit], FieldTargets]:
    fields: defaultdict[str, list[tuple[str, Node]]] = defaultdict(list)
    for block in (node for node in document.nodes if node.has("top")):
        headers = [node for node in block.children if node.tag == "p" and node.has("src")]
        if len(headers) != 1:
            continue
        owners = [
            node.attrs["id"][2:]
            for node in headers[0].walk()
            if node.has("def") and node.attrs.get("id", "").startswith("t:")
        ]
        for field in (node for node in block.walk() if node.tag == "dfn" and node.has("src")):
            if not any(node.has("fields") for node in field.ancestors()):
                continue
            owner = _one(owners, "record owner")
            binder = _one([node for node in field.walk() if node.has("def")], "field binder")
            anchor = binder.attrs.get("id", "")
            if not anchor.startswith("v:") or binder.text() != anchor[2:]:
                raise ValueError("Unqualified native field binder")
            fields[anchor].append((owner, binder))
    edits: list[Edit] = []
    targets: FieldTargets = {}
    choices: list[tuple[str, list[Link]]] = []
    ids = Counter(node.attrs["id"] for node in document.nodes if "id" in node.attrs)
    for anchor, binders in fields.items():
        if len(binders) == 1:
            continue
        if ids[anchor] != len(binders) or len({owner for owner, _ in binders}) != len(binders):
            raise ValueError(f"Unexpected duplicate field anchor: {anchor}")
        links: list[Link] = []
        for owner, binder in binders:
            target = f"v:{owner}.{anchor[2:]}"
            if ids[target]:
                raise ValueError(f"Existing owner-qualified anchor: {target}")
            targets[owner, anchor] = target
            edits.append(_attribute(document, binder, "id", target))
            links.append((target, f"{owner}.{anchor[2:]}"))
        choices.append((anchor, links))
    for short in (node for node in document.nodes if node.has("short") and node.has("src")):
        owners = [
            node.attrs["href"][3:]
            for node in short.children
            if node.tag == "a" and node.attrs.get("href", "").startswith("#t:")
        ]
        if len(owners) != 1:
            continue
        for node in short.walk():
            target = targets.get((owners[0], node.attrs.get("href", "").removeprefix("#")))
            if node.tag == "a" and target is not None:
                edits.append(_attribute(document, node, "href", "#" + target))
    if choices:
        edits.append(_insert_choices(document, choices, "Record field destinations"))
    return edits, targets


def _method_edits(document: Document) -> list[Edit]:
    edits: list[Edit] = []
    for methods in (node for node in document.nodes if node.has("methods")):
        instance = next(
            (
                node
                for node in methods.ancestors()
                if node.tag == "details" and node.attrs.get("id", "").startswith("i:id:")
            ),
            None,
        )
        if instance is None:
            raise ValueError("Instance method has no native instance owner")
        for signature in (node for node in methods.children if node.tag == "p" and node.has("src")):
            binder = _one(
                [node for node in signature.children[:1] if node.tag == "a"],
                "leading instance method binder",
            )
            old = binder.attrs.get("href", "")
            if not old.startswith("#v:") or "id" in binder.attrs:
                raise ValueError("Unqualified instance method anchor")
            target = "m:" + instance.attrs["id"] + ":" + old[1:]
            changed = _attribute(document, binder, "href", "#" + target)[2]
            changed = changed[:-1] + f' id="{escape(target, quote=True)}">'
            edits.append((binder.start, binder.start_end, changed))
            for link in signature.children:
                if link.has("selflink"):
                    if link.attrs.get("href") != old:
                        raise ValueError("Instance method selflink differs from its binder")
                    edits.append(_attribute(document, link, "href", "#" + target))
    return edits


def _source_edits(document: Document) -> list[Edit]:
    identifiers: defaultdict[str, list[tuple[str | None, Node]]] = defaultdict(list)
    line: str | None = None
    for node in document.nodes:
        anchor = node.attrs.get("id")
        if anchor is None:
            continue
        if re.fullmatch(r"line-[1-9][0-9]*", anchor):
            line = anchor
        identifiers[anchor].append((line, node))
    edits: list[Edit] = []
    choices: list[tuple[str, list[Link]]] = []
    for anchor, nodes in identifiers.items():
        if len(nodes) == 1:
            continue
        if (
            anchor.startswith("line-")
            or any(line is None for line, _ in nodes)
            or any(not any(parent.tag == "pre" for parent in node.ancestors()) for _, node in nodes)
        ):
            raise ValueError(f"Unexpected duplicate source anchor: {anchor}")
        lines = list(dict.fromkeys(line for line, _ in nodes if line is not None))
        for _, node in nodes[1:] if len(lines) == 1 else nodes:
            edits.append(_attribute(document, node, "id", None))
        if len(lines) > 1:
            choices.append((anchor, [(line, line.replace("-", " ")) for line in lines]))
    if choices:
        edits.append(
            _insert_choices(document, choices, "Source identifier destinations", source=True)
        )
    body = _one([node for node in document.nodes if node.tag == "body"], "source body")
    listing = _one([node for node in body.children if node.tag == "pre"], "source listing")
    if listing.attrs:
        raise ValueError("Unqualified native source listing attributes")
    opening = _attribute(document, listing, "tabindex", "0")[2]
    opening = opening[:-1] + ' role="region" aria-label="Haskell source">'
    edits.append((listing.start, listing.start_end, opening))
    viewport = "width=device-width, initial-scale=1"
    metas = [
        node
        for node in document.nodes
        if node.tag == "meta" and node.attrs.get("name") == "viewport"
    ]
    if metas:
        if _one(metas, "source viewport").attrs.get("content") != viewport:
            raise ValueError("Unqualified native source viewport")
    else:
        markup = f'<meta name="viewport" content="{viewport}" />'
        heads = [node for node in document.nodes if node.tag == "head"]
        if heads:
            head = _one(heads, "source head")
            edits.append((head.start_end, head.start_end, markup))
        else:
            edits.append((body.start, body.start, "<head>" + markup + "</head>"))
    return edits


def _destination(page: str, href: str) -> Link | None:
    """Resolve a link to ``(page, fragment)``; ``None`` for an external link.

    >>> _destination("LibTmux.html", "LibTmux-Query.html#t:Query")
    ('LibTmux-Query.html', 't:Query')
    >>> _destination("src/LibTmux.html", "../LibTmux-Id.html")
    ('LibTmux-Id.html', '')
    >>> _destination("LibTmux.html", "#v:capture")
    ('LibTmux.html', 'v:capture')
    >>> _destination("LibTmux.html", "https://hackage.haskell.org/") is None
    True
    >>> _destination("LibTmux.html", "../../etc/passwd")
    Traceback (most recent call last):
    ValueError: Native link escapes the artifact
    """
    parsed = urlsplit(href)
    if parsed.scheme or parsed.netloc:
        if parsed.scheme not in {"https", "http", "mailto"}:
            raise ValueError(f"Unsupported native link scheme: {parsed.scheme}")
        return None
    if parsed.query:
        raise ValueError("Unqualified local native query link")
    target = (
        posixpath.normpath(posixpath.join(posixpath.dirname(page), unquote(parsed.path)))
        if parsed.path
        else page
    )
    if target.startswith(("../", "/")):
        raise ValueError("Native link escapes the artifact")
    return target, parsed.fragment


def _validate(
    pages: Mapping[str, str], documents: Mapping[str, Document], search_links: list[Link]
) -> int:
    ids: dict[str, Counter[str]] = {}
    for page, document in documents.items():
        counts = Counter(node.attrs["id"] for node in document.nodes if "id" in node.attrs)
        if any(count != 1 for count in counts.values()):
            raise ValueError(f"Unexpected duplicate HTML ID in {page}")
        ids[page] = counts
    checked = 0
    links = [
        (page, node.attrs["href"])
        for page, document in documents.items()
        for node in document.nodes
        if node.tag == "a" and "href" in node.attrs
    ]
    for page, href in links + search_links:
        target = _destination(page, href)
        if target is None:
            continue
        path, anchor = target
        if path not in pages:
            raise ValueError(f"Missing native page: {page}: {href}")
        # HTML tries the literal fragment before its percent-decoded form.
        if anchor and (
            path not in ids or not any(value in ids[path] for value in [anchor, unquote(anchor)])
        ):
            raise ValueError(f"Missing native anchor: {page}: {href}")
        checked += 1
    return checked


def _public_page_edits(document: Document, counts: Counter[str]) -> tuple[list[Edit], FieldTargets]:
    """Check a public module page's Haddock version, then repair its fields and methods."""
    footer = _one(
        [node for node in document.nodes if node.attrs.get("id") == "footer"], "Haddock footer"
    )
    version = re.search(r"\bHaddock version ([\w.]+)", footer.text())
    if version is None or version[1] != "2.33.0":
        raise ValueError("Unqualified Haddock version")
    edits, targets = _field_edits(document)
    counts["fieldEdits"] += len(edits)
    methods = _method_edits(document)
    edits.extend(methods)
    counts["methodEdits"] += len(methods)
    return edits, targets


def _module_list_edits(document: Document, counts: Counter[str]) -> list[Edit]:
    """Drop the inner duplicate ``module-list`` ID from the index page."""
    lists = [node for node in document.nodes if node.attrs.get("id") == "module-list"]
    if len(lists) != 2:
        return []
    outer, inner = lists
    captions = [node.text() for node in outer.children if node.has("caption")]
    if (
        outer.tag != "div"
        or inner.tag != "div"
        or inner.parent is not outer
        or captions != ["Modules"]
    ):
        raise ValueError("Unqualified duplicate module-list context")
    counts["moduleListEdits"] += 1
    return [_attribute(document, inner, "id", None)]


def _hidden_attribution_edits(
    name: str,
    document: Document,
    pages: Mapping[str, str],
    hidden: Mapping[str, str],
    counts: Counter[str],
) -> list[Edit]:
    """Unlink each hidden module named in a "Defined in" attribution."""
    edits: list[Edit] = []
    for node in document.nodes:
        if node.tag != "a" or "href" not in node.attrs:
            continue
        target = _destination(name, node.attrs["href"])
        if target is None or target[0] in pages or target[0] not in hidden:
            continue
        parent = node.parent
        grandparent = parent.parent if parent is not None else None
        module = hidden[target[0]]
        if (
            target[1]
            or node.attrs["href"] != target[0]
            or node.text() != module
            or parent is None
            or grandparent is None
            or parent.tag != "p"
            or parent.text() != "Defined in " + module
            or parent.children != [node]
            or grandparent.tag != "details"
            or not grandparent.attrs.get("id", "").startswith("i:id:")
        ):
            raise ValueError("Missing hidden-module link outside its Defined-in attribution")
        edits.extend([(node.start, node.start_end, ""), (node.end_start, node.end, "")])
        counts["hiddenAttributions"] += 1
    return edits


def _reexport_link(
    entry: dict[str, Any],
    page: str,
    document: Document,
    documents: Mapping[str, Document],
    public_modules: Collection[str],
) -> Link:
    """Check a search entry that re-exports a module and return the link to validate."""
    export = _one(
        [node for node in document.root.children if node.tag == "a"],
        "native search module reexport",
    )
    exported = _destination(page, export.attrs.get("href", ""))
    targets = [
        module for module in public_modules if exported == (module.replace(".", "-") + ".html", "")
    ]
    module = _one(targets, "public reexport owner")
    expected = "module " + module
    headers = [
        node
        for node in documents[page].nodes
        if node.tag == "p"
        and node.has("src")
        and node.text() == expected
        and [item.attrs.get("href") for item in node.walk() if item.tag == "a"]
        == [export.attrs.get("href")]
    ]
    if entry["name"] != "" or document.root.text() != expected or len(headers) != 1:
        raise ValueError("Native search reexport and public module owner disagree")
    return page, export.attrs["href"]


def _declaration_links(
    entry: dict[str, Any],
    page: str,
    target: Link | None,
    document: Document,
    fields: Mapping[str, FieldTargets],
    counts: Counter[str],
) -> list[Link]:
    """Retarget a declaration entry's field links in place and return its links to validate."""
    if target is None or target[0] != page:
        raise ValueError("Native search module and declaration owner disagree")
    owner = target[1][2:] if target[1].startswith("t:") else None
    binder = _one(
        [node for node in document.root.children if node.tag == "a"][:1],
        "native search declaration anchor",
    )
    if binder.attrs.get("href") != "#" + target[1]:
        raise ValueError("Native search display anchor and declaration owner disagree")
    edits: list[Edit] = []
    for node in document.nodes:
        href = node.attrs.get("href", "")
        if node.tag == "a" and href.startswith("#"):
            anchor = fields.get(target[0], {}).get((owner, href[1:]))
            if anchor:
                edits.append(_attribute(document, node, "href", "#" + anchor))
    entry["display_html"] = _apply(document, edits)
    counts["searchEdits"] += len(edits)
    return [
        (page, node.attrs["href"])
        for node in Document(entry["display_html"]).nodes
        if node.tag == "a" and "href" in node.attrs
    ]


def _search_index(
    text: str,
    documents: Mapping[str, Document],
    public_modules: Collection[str],
    fields: Mapping[str, FieldTargets],
    counts: Counter[str],
) -> tuple[str, list[Link]]:
    """Retarget the native search index and return its text and the links to validate."""
    entries = json.loads(text)
    search_links: list[Link] = []
    for entry in entries:
        if entry["module"] not in public_modules:
            raise ValueError("Unknown native search module")
        page = entry["module"].replace(".", "-") + ".html"
        search_links.append(("doc-index.json", entry["link"]))
        target = _destination("doc-index.json", entry["link"])
        document = Document(entry["display_html"])
        if entry["link"] == "":
            search_links.append(_reexport_link(entry, page, document, documents, public_modules))
        else:
            search_links.extend(_declaration_links(entry, page, target, document, fields, counts))
    return json.dumps(entries, ensure_ascii=False, separators=(",", ":")) + "\n", search_links


def _require_unchanged_listings(
    documents: Mapping[str, Document], prepared: Mapping[str, Document]
) -> None:
    """Require each source page's text and line anchors to survive preparation."""
    for name, document in documents.items():
        if not name.startswith("src/"):
            continue
        before = _one(
            [node for node in document.nodes if node.tag == "pre"], "native source listing"
        )
        after = _one(
            [node for node in prepared[name].nodes if node.tag == "pre"], "prepared source listing"
        )
        if before.text() != after.text() or _line_anchors(before) != _line_anchors(after):
            raise ValueError("Preparation changed source text or line anchors")


def prepare_pages(
    pages: Mapping[str, str], public_modules: Collection[str], hidden_modules: Collection[str]
) -> tuple[dict[str, str], dict[str, int]]:
    """Return checked HTML copies and edit counts; never mutate the input mapping."""
    public = {module.replace(".", "-") + ".html" for module in public_modules}
    hidden = {module.replace(".", "-") + ".html": module for module in hidden_modules}
    if not public <= pages.keys() or public & hidden.keys() or hidden.keys() & pages.keys():
        raise ValueError("Missing or conflicting public native module")
    documents = {name: Document(text) for name, text in pages.items() if name.endswith(".html")}
    result = dict(pages)
    fields: dict[str, FieldTargets] = {}
    counts: Counter[str] = Counter()
    for name, document in documents.items():
        edits: list[Edit] = []
        if name in public:
            changes, fields[name] = _public_page_edits(document, counts)
            edits.extend(changes)
        if name.startswith("src/"):
            changes = _source_edits(document)
            edits.extend(changes)
            counts["sourceEdits"] += len(changes)
        if name == "index.html":
            edits.extend(_module_list_edits(document, counts))
        edits.extend(_hidden_attribution_edits(name, document, pages, hidden, counts))
        result[name] = _apply(document, edits)
    search_links: list[Link] = []
    if "doc-index.json" in result:
        result["doc-index.json"], search_links = _search_index(
            result["doc-index.json"], documents, public_modules, fields, counts
        )
    prepared = {name: Document(text) for name, text in result.items() if name.endswith(".html")}
    _require_unchanged_listings(documents, prepared)
    counts["checkedLocalLinks"] = _validate(result, prepared, search_links)
    return result, dict(counts)


def _line_anchors(listing: Node) -> list[str]:
    return [
        node.attrs["id"] for node in listing.walk() if node.attrs.get("id", "").startswith("line-")
    ]


def cabal_modules(manifest: Path) -> tuple[set[str], set[str]]:
    """Read the library's ``exposed-modules`` and ``other-modules`` from its Cabal file."""
    text = manifest.read_text()
    libraries = re.findall(r"^library\s*\n((?:[ \t].*\n|\n)*)", text, re.MULTILINE)
    library = _one(libraries, "unnamed Cabal library")
    result: list[set[str]] = []
    for field in ["exposed-modules", "other-modules"]:
        values = re.findall(r"^  " + field + r":([^\n]*(?:\n    [^\n]*)*)", library, re.MULTILINE)
        names = _one(values, field).split()
        if not names or any(
            not re.fullmatch(r"[A-Z][\w\']*(?:\.[A-Z][\w\']*)*", name) for name in names
        ):
            raise ValueError("Unqualified Cabal module catalogue")
        result.append(set(names))
    exposed, other = result
    return exposed, other


def _resources(files: Mapping[str, bytes]) -> int:
    if "meta.json" not in files:
        raise ValueError("Missing native browser metadata")
    metadata = json.loads(files["meta.json"])
    if not isinstance(metadata, dict) or metadata.get("haddock_version") != "2.33.0":
        raise ValueError("Unqualified native browser metadata")
    quickjump = metadata.get("quickjump_version")
    if quickjump is not None and (type(quickjump) is not int or quickjump != 1):
        raise ValueError("Unqualified native search metadata")
    if quickjump == 1:
        required = {
            "doc-index.json",
            "haddock-bundle.min.js",
            "quick-jump.min.js",
            "quick-jump.css",
        }
        if not required <= files.keys():
            raise ValueError("Missing enabled native search resource")
    checked = 0

    def resource(page: str, href: str) -> None:
        nonlocal checked
        if href.startswith("data:"):
            return
        target = _destination(page, href)
        if target is not None:
            if target[0] not in files:
                raise ValueError(f"Missing local browser resource: {page}: {href}")
            checked += 1

    attributes = {
        "link": ["href"],
        "script": ["src"],
        "img": ["src"],
        "source": ["src"],
        "video": ["src", "poster"],
        "audio": ["src"],
        "iframe": ["src"],
        "embed": ["src"],
        "object": ["data"],
        "input": ["src"],
    }
    for name, data in files.items():
        if name.endswith(".html"):
            for node in Document(data.decode("utf-8")).nodes:
                if "srcset" in node.attrs:
                    raise ValueError("Unqualified native resource srcset")
                for attr in attributes.get(node.tag, []):
                    if attr in node.attrs:
                        resource(name, node.attrs[attr])
        elif name.endswith(".css"):
            css = data.decode("utf-8")
            urls = list(
                re.finditer(
                    r"""\burl\(\s*(?:"([^"]*)"|'([^']*)'|([^\s)]*))\s*\)""", css, re.IGNORECASE
                )
            )
            if len(urls) != len(re.findall(r"\burl\(", css, re.IGNORECASE)):
                raise ValueError("Unqualified native CSS resource syntax")
            for url in urls:
                resource(name, next(value for value in url.groups() if value is not None))
    return checked


def prepare(raw: Path, output: Path, manifest: Path) -> dict[str, Any]:
    """Write a fresh artifact atomically after validating the complete copy."""
    raw, output = Path(raw).resolve(), Path(output)
    if output.exists() or output.is_symlink():
        raise ValueError("Prepared artifact already exists")
    output = output.resolve()
    if output.is_relative_to(raw) or raw.is_relative_to(output):
        raise ValueError("Raw and prepared artifact directories must be separate")
    files: dict[str, bytes] = {}
    for path in sorted(raw.rglob("*")):
        if path.is_symlink():
            raise ValueError("Native artifact contains a symlink")
        if path.is_file():
            files[path.relative_to(raw).as_posix()] = path.read_bytes()
    if not files or "navigation.json" in files:
        raise ValueError("Expected an unprepared native artifact")
    resources = _resources(files)
    pages = {
        name: data.decode("utf-8")
        for name, data in files.items()
        if name.endswith(".html") or name == "doc-index.json"
    }
    prepared, counts = prepare_pages(pages, *cabal_modules(Path(manifest)))
    counts["checkedLocalResources"] = resources
    changed = {
        name: prepared[name].encode("utf-8") if name in prepared else data
        for name, data in files.items()
    }
    for name, suffix, counter in [
        ("linuwial.css", RESPONSIVE_CSS, "responsiveStyleEdits"),
        ("src/style.css", SOURCE_RESPONSIVE_CSS, "sourceResponsiveStyleEdits"),
        ("src/highlight.js", SOURCE_SCRIPT, "sourceScriptEdits"),
    ]:
        if name in changed:
            changed[name] += suffix
            counts[counter] = 1
    evidence: dict[str, Any] = {
        "schema": "libtmux.haddock-navigation/1",
        "haddock": "2.33.0",
        "limits": ["Raw output retained; no source freshness or external URL qualification"],
        "counts": counts,
        "files": [
            {
                "path": name,
                "rawSha256": hashlib.sha256(data).hexdigest(),
                "preparedSha256": hashlib.sha256(changed[name]).hexdigest(),
            }
            for name, data in files.items()
        ],
    }
    staging = Path(tempfile.mkdtemp(prefix=".haddock-prepared-", dir=output.parent))
    try:
        for name, data in changed.items():
            target = staging / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        (staging / "navigation.json").write_text(json.dumps(evidence, indent=2) + "\n")
        staging.rename(output)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return evidence


def from_plan(plan: Path, manifest: Path) -> Path:
    """Find the one local library artifact configured for this source tree."""
    document = json.loads(Path(plan).read_text())
    if document.get("compiler-id") != "ghc-9.14.1":
        raise ValueError("Unqualified Cabal plan compiler")
    library = _one(
        [
            entry
            for entry in document.get("install-plan", [])
            if entry.get("type") == "configured"
            and entry.get("style") == "local"
            and entry.get("pkg-name") == "libtmux-haskell"
            and entry.get("component-name") == "lib"
        ],
        "configured local library",
    )
    source = library.get("pkg-src", {})
    if (
        source.get("type") != "local"
        or Path(source.get("path", "")).resolve() != Path(manifest).resolve().parent
    ):
        raise ValueError("Configured library source differs from the selected manifest")
    directory = Path(library.get("dist-dir", ""))
    if not directory.is_absolute():
        raise ValueError("Configured library needs an absolute dist-dir")
    return directory / "doc/html/libtmux-haskell"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="New, separate artifact directory")
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--raw", type=Path, help="Fresh Cabal Haddock HTML directory")
    inputs.add_argument("--build-plan", type=Path, help="Cabal plan for the local library")
    parser.add_argument("--manifest", type=Path, default=ROOT / "libtmux-haskell.cabal")
    args = parser.parse_args()
    try:
        raw = args.raw if args.raw is not None else from_plan(args.build_plan, args.manifest)
        evidence = prepare(raw, args.output, args.manifest)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Haddock preparation failed: {error}\n")
    print(json.dumps(evidence["counts"], sort_keys=True))


if __name__ == "__main__":
    main()
