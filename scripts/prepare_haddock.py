"""Prepare a separate, link-checked copy of Haddock 2.33.0 HTML.

Raw artifacts remain authoritative. This compatibility step changes only
navigation tags and adds explicit destinations for ambiguous native names.
It neither changes the compiled interface nor establishes source freshness.
"""

import argparse
from collections import Counter, defaultdict
import hashlib
from html import escape
from html.parser import HTMLParser
import json
from pathlib import Path
import posixpath
import re
import shutil
import tempfile
from urllib.parse import unquote, urlsplit

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"}


class Node:
    def __init__(self, tag, attrs, start, start_end, parent=None):
        self.tag, self.attrs, self.parent = tag, dict(attrs), parent
        self.start, self.start_end = start, start_end
        self.end_start, self.end = start_end, start_end
        self.children = []
        self.data = []

    def has(self, name):
        return name in self.attrs.get("class", "").split()

    def ancestors(self):
        parent = self.parent
        while parent is not None:
            yield parent
            parent = parent.parent

    def walk(self):
        yield self
        for child in self.children:
            yield from child.walk()

    def text(self):
        return "".join(self.data)


class Document(HTMLParser):
    def __init__(self, text):
        super().__init__(convert_charrefs=True)
        self.source = text
        self.lines = [0]
        self.lines.extend(match.end() for match in re.finditer("\n", text))
        self.root = Node("", (), 0, 0)
        self.stack = [self.root]
        self.nodes = []
        self.feed(text)
        self.close()
        if len(self.stack) != 1:
            raise ValueError("Unclosed native HTML element")

    def position(self):
        line, column = self.getpos()
        return self.lines[line - 1] + column

    def handle_starttag(self, tag, attrs):
        if len(attrs) != len(dict(attrs)):
            raise ValueError("Duplicate native HTML attribute")
        start = self.position()
        node = Node(tag, attrs, start, start + len(self.get_starttag_text()), self.stack[-1])
        self.stack[-1].children.append(node)
        self.nodes.append(node)
        if tag not in VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID:
            self.stack.pop()

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if self.stack[-1].tag != tag:
            raise ValueError(f"Unexpected native HTML closing tag: {tag}")
        node = self.stack.pop()
        node.end_start = self.position()
        node.end = self.source.index(">", node.end_start) + 1

    def handle_data(self, data):
        for node in self.stack:
            node.data.append(data)


def _one(items, description):
    if len(items) != 1:
        raise ValueError(f"Expected one {description}; found {len(items)}")
    return items[0]


def _attribute(document, node, name, value):
    raw = document.source[node.start:node.start_end]
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


def _apply(document, edits):
    result, previous = [], 0
    for start, end, replacement in sorted(edits, key=lambda edit: (edit[0], edit[1])):
        if start < previous:
            raise ValueError("Overlapping native navigation edits")
        result.extend([document.source[previous:start], replacement])
        previous = end
    result.append(document.source[previous:])
    return "".join(result)


def _insert_choices(document, entries, heading, source=False):
    layout = [node for node in document.nodes if node.tag == 'div'
              and not any(parent.tag == 'pre' for parent in node.ancestors())]
    content = [node for node in layout if node.attrs.get("id") == "content"]
    footer = [node for node in layout if node.attrs.get("id") == "footer"]
    body = [node for node in document.nodes if node.tag == "body"]
    position = (_one(body, 'source body').end_start if source else
                content[0].end_start if len(content) == 1 else
                footer[0].start if len(footer) == 1 else _one(body, "body").end_start)
    rendered = '<section class="subs"><h2>' + escape(heading) + '</h2><dl>'
    for anchor, links in entries:
        label = anchor.removeprefix('v:')
        rendered += f'<dt id="{escape(anchor, quote=True)}"><code>{escape(label)}</code></dt><dd>'
        rendered += ', '.join(f'<a href="#{escape(target, quote=True)}">{escape(label)}</a>'
                              for target, label in links)
        rendered += '</dd>'
    return position, position, rendered + '</dl></section>'


def _field_edits(document):
    fields = defaultdict(list)
    for block in (node for node in document.nodes if node.has("top")):
        headers = [node for node in block.children if node.tag == "p" and node.has("src")]
        if len(headers) != 1:
            continue
        owners = [node.attrs["id"][2:] for node in headers[0].walk()
                  if node.has("def") and node.attrs.get("id", "").startswith("t:")]
        for field in (node for node in block.walk() if node.tag == "dfn" and node.has("src")):
            if not any(node.has("fields") for node in field.ancestors()):
                continue
            owner = _one(owners, "record owner")
            binder = _one([node for node in field.walk() if node.has("def")], "field binder")
            anchor = binder.attrs.get("id", "")
            if not anchor.startswith("v:") or binder.text() != anchor[2:]:
                raise ValueError("Unqualified native field binder")
            fields[anchor].append((owner, binder))
    edits, targets, choices = [], {}, []
    ids = Counter(node.attrs["id"] for node in document.nodes if "id" in node.attrs)
    for anchor, binders in fields.items():
        if len(binders) == 1:
            continue
        if ids[anchor] != len(binders) or len({owner for owner, _ in binders}) != len(binders):
            raise ValueError(f"Unexpected duplicate field anchor: {anchor}")
        links = []
        for owner, binder in binders:
            target = f"v:{owner}.{anchor[2:]}"
            if ids[target]:
                raise ValueError(f"Existing owner-qualified anchor: {target}")
            targets[owner, anchor] = target
            edits.append(_attribute(document, binder, "id", target))
            links.append((target, f"{owner}.{anchor[2:]}"))
        choices.append((anchor, links))
    for short in (node for node in document.nodes if node.has("short") and node.has("src")):
        owners = [node.attrs["href"][3:] for node in short.children
                  if node.tag == "a" and node.attrs.get("href", "").startswith("#t:")]
        if len(owners) != 1:
            continue
        for node in short.walk():
            target = targets.get((owners[0], node.attrs.get("href", "").removeprefix("#")))
            if node.tag == "a" and target is not None:
                edits.append(_attribute(document, node, "href", "#" + target))
    if choices:
        edits.append(_insert_choices(document, choices, "Record field destinations"))
    return edits, targets


def _method_edits(document):
    edits = []
    for methods in (node for node in document.nodes if node.has("methods")):
        instance = next((node for node in methods.ancestors()
                         if node.tag == "details" and node.attrs.get("id", "").startswith("i:id:")), None)
        if instance is None:
            raise ValueError("Instance method has no native instance owner")
        for signature in (node for node in methods.children if node.tag == "p" and node.has("src")):
            binder = _one([node for node in signature.children[:1] if node.tag == "a"],
                          "leading instance method binder")
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


def _source_edits(document):
    identifiers, line = defaultdict(list), None
    for node in document.nodes:
        anchor = node.attrs.get("id")
        if anchor is None:
            continue
        if re.fullmatch(r"line-[1-9][0-9]*", anchor):
            line = anchor
        identifiers[anchor].append((line, node))
    edits, choices = [], []
    for anchor, nodes in identifiers.items():
        if len(nodes) == 1:
            continue
        if (anchor.startswith("line-") or any(line is None for line, _ in nodes)
                or any(not any(parent.tag == 'pre' for parent in node.ancestors()) for _, node in nodes)):
            raise ValueError(f"Unexpected duplicate source anchor: {anchor}")
        lines = list(dict.fromkeys(line for line, _ in nodes))
        for _, node in nodes[1:] if len(lines) == 1 else nodes:
            edits.append(_attribute(document, node, "id", None))
        if len(lines) > 1:
            choices.append((anchor, [(line, line.replace("-", " ")) for line in lines]))
    if choices:
        edits.append(_insert_choices(document, choices, "Source identifier destinations", source=True))
    return edits


def _destination(page, href):
    parsed = urlsplit(href)
    if parsed.scheme or parsed.netloc:
        if parsed.scheme not in {"https", "http", "mailto"}:
            raise ValueError(f"Unsupported native link scheme: {parsed.scheme}")
        return None
    if parsed.query:
        raise ValueError("Unqualified local native query link")
    target = posixpath.normpath(posixpath.join(posixpath.dirname(page), unquote(parsed.path))) if parsed.path else page
    if target.startswith(("../", "/")):
        raise ValueError("Native link escapes the artifact")
    return target, parsed.fragment


def _validate(pages, documents, search_links):
    ids = {}
    for page, document in documents.items():
        counts = Counter(node.attrs["id"] for node in document.nodes if "id" in node.attrs)
        if any(count != 1 for count in counts.values()):
            raise ValueError(f"Unexpected duplicate HTML ID in {page}")
        ids[page] = counts
    checked = 0
    links = [(page, node.attrs['href']) for page, document in documents.items()
             for node in document.nodes if node.tag == 'a' and 'href' in node.attrs]
    for page, href in links + search_links:
        target = _destination(page, href)
        if target is None:
            continue
        path, anchor = target
        if path not in pages:
            raise ValueError(f"Missing native page: {page}: {href}")
        # HTML tries the literal fragment before its percent-decoded form.
        if anchor and (path not in ids or not any(value in ids[path] for value in [anchor, unquote(anchor)])):
            raise ValueError(f"Missing native anchor: {page}: {href}")
        checked += 1
    return checked


def prepare_pages(pages, public_modules, hidden_modules):
    """Return checked HTML copies and edit counts; never mutate the input mapping."""
    public = {module.replace(".", "-") + ".html" for module in public_modules}
    hidden = {module.replace(".", "-") + ".html": module for module in hidden_modules}
    if not public <= pages.keys() or public & hidden.keys() or hidden.keys() & pages.keys():
        raise ValueError("Missing or conflicting public native module")
    documents = {name: Document(text) for name, text in pages.items() if name.endswith('.html')}
    result, fields, counts = dict(pages), {}, Counter()
    for name, document in documents.items():
        edits = []
        if name in public:
            footer = _one([node for node in document.nodes if node.attrs.get('id') == 'footer'], 'Haddock footer')
            version = re.search(r'\bHaddock version ([\w.]+)', footer.text())
            if version is None or version[1] != '2.33.0':
                raise ValueError("Unqualified Haddock version")
            changes, fields[name] = _field_edits(document)
            edits.extend(changes)
            counts['fieldEdits'] += len(changes)
            changes = _method_edits(document)
            edits.extend(changes)
            counts['methodEdits'] += len(changes)
        if name.startswith('src/'):
            changes = _source_edits(document)
            edits.extend(changes)
            counts['sourceEdits'] += len(changes)
        if name == 'index.html':
            lists = [node for node in document.nodes if node.attrs.get('id') == 'module-list']
            if len(lists) == 2:
                outer, inner = lists
                captions = [node.text() for node in outer.children if node.has('caption')]
                if outer.tag != 'div' or inner.tag != 'div' or inner.parent is not outer or captions != ['Modules']:
                    raise ValueError('Unqualified duplicate module-list context')
                edits.append(_attribute(document, inner, 'id', None))
                counts['moduleListEdits'] += 1
        for node in document.nodes:
            if node.tag != 'a' or 'href' not in node.attrs:
                continue
            target = _destination(name, node.attrs['href'])
            if target is None or target[0] in pages or target[0] not in hidden:
                continue
            parent = node.parent
            module = hidden[target[0]]
            if (target[1] or node.attrs['href'] != target[0] or node.text() != module
                    or parent.tag != 'p' or parent.text() != 'Defined in ' + module
                    or parent.children != [node] or parent.parent.tag != 'details'
                    or not parent.parent.attrs.get('id', '').startswith('i:id:')):
                raise ValueError("Missing hidden-module link outside its Defined-in attribution")
            edits.extend([(node.start, node.start_end, ''), (node.end_start, node.end, '')])
            counts['hiddenAttributions'] += 1
        result[name] = _apply(document, edits)
    search_links = []
    if 'doc-index.json' in result:
        entries = json.loads(result['doc-index.json'])
        for entry in entries:
            if entry['module'] not in public_modules:
                raise ValueError('Unknown native search module')
            page = entry['module'].replace('.', '-') + '.html'
            search_links.append(('doc-index.json', entry['link']))
            target = _destination('doc-index.json', entry['link'])
            document = Document(entry['display_html'])
            if entry['link'] == '':
                export = _one([node for node in document.root.children if node.tag == 'a'],
                              'native search module reexport')
                exported = _destination(page, export.attrs.get('href', ''))
                targets = [module for module in public_modules
                           if exported == (module.replace('.', '-') + '.html', '')]
                module = _one(targets, 'public reexport owner')
                expected = 'module ' + module
                headers = [node for node in documents[page].nodes if node.tag == 'p' and node.has('src')
                           and node.text() == expected
                           and [item.attrs.get('href') for item in node.walk() if item.tag == 'a'] == [export.attrs.get('href')]]
                if entry['name'] != '' or document.root.text() != expected or len(headers) != 1:
                    raise ValueError('Native search reexport and public module owner disagree')
                search_links.append((page, export.attrs['href']))
                continue
            if target is None or target[0] != page:
                raise ValueError('Native search module and declaration owner disagree')
            owner = target[1][2:] if target and target[1].startswith('t:') else None
            binder = _one([node for node in document.root.children if node.tag == 'a'][:1],
                          'native search declaration anchor')
            if binder.attrs.get('href') != '#' + target[1]:
                raise ValueError('Native search display anchor and declaration owner disagree')
            edits = []
            for node in document.nodes:
                href = node.attrs.get('href', '')
                if node.tag == 'a' and href.startswith('#'):
                    anchor = fields.get(target[0], {}).get((owner, href[1:]))
                    if anchor:
                        edits.append(_attribute(document, node, 'href', '#' + anchor))
            entry['display_html'] = _apply(document, edits)
            counts['searchEdits'] += len(edits)
            search_links.extend((page, node.attrs['href'])
                                for node in Document(entry['display_html']).nodes
                                if node.tag == 'a' and 'href' in node.attrs)
        result['doc-index.json'] = json.dumps(entries, ensure_ascii=False, separators=(',', ':')) + '\n'
    prepared = {name: Document(text) for name, text in result.items() if name.endswith('.html')}
    for name, document in documents.items():
        if not name.startswith('src/'):
            continue
        before = _one([node for node in document.nodes if node.tag == 'pre'], 'native source listing')
        after = _one([node for node in prepared[name].nodes if node.tag == 'pre'], 'prepared source listing')
        lines = lambda listing: [node.attrs['id'] for node in listing.walk()
                                 if node.attrs.get('id', '').startswith('line-')]
        if before.text() != after.text() or lines(before) != lines(after):
            raise ValueError('Preparation changed source text or line anchors')
    counts['checkedLocalLinks'] = _validate(result, prepared, search_links)
    return result, dict(counts)


def _modules(manifest):
    text = manifest.read_text()
    libraries = re.findall(r'^library\s*\n((?:[ \t].*\n|\n)*)', text, re.MULTILINE)
    library = _one(libraries, 'unnamed Cabal library')
    result = []
    for field in ['exposed-modules', 'other-modules']:
        values = re.findall(r'^  ' + field + r':([^\n]*(?:\n    [^\n]*)*)', library, re.MULTILINE)
        names = _one(values, field).split()
        if not names or any(not re.fullmatch(r'[A-Z][\w\']*(?:\.[A-Z][\w\']*)*', name) for name in names):
            raise ValueError('Unqualified Cabal module catalogue')
        result.append(set(names))
    return result


def _resources(files):
    if 'meta.json' not in files:
        raise ValueError('Missing native browser metadata')
    metadata = json.loads(files['meta.json'])
    if not isinstance(metadata, dict) or metadata.get('haddock_version') != '2.33.0':
        raise ValueError('Unqualified native browser metadata')
    quickjump = metadata.get('quickjump_version')
    if quickjump is not None and (type(quickjump) is not int or quickjump != 1):
        raise ValueError('Unqualified native search metadata')
    if quickjump == 1:
        required = {'doc-index.json', 'haddock-bundle.min.js', 'quick-jump.min.js', 'quick-jump.css'}
        if not required <= files.keys():
            raise ValueError('Missing enabled native search resource')
    checked = 0

    def resource(page, href):
        nonlocal checked
        if href.startswith('data:'):
            return
        target = _destination(page, href)
        if target is not None:
            if target[0] not in files:
                raise ValueError(f'Missing local browser resource: {page}: {href}')
            checked += 1

    attributes = {'link': ['href'], 'script': ['src'], 'img': ['src'], 'source': ['src'],
                  'video': ['src', 'poster'], 'audio': ['src'], 'iframe': ['src'],
                  'embed': ['src'], 'object': ['data'], 'input': ['src']}
    for name, data in files.items():
        if name.endswith('.html'):
            for node in Document(data.decode('utf-8')).nodes:
                if 'srcset' in node.attrs:
                    raise ValueError('Unqualified native resource srcset')
                for attr in attributes.get(node.tag, []):
                    if attr in node.attrs:
                        resource(name, node.attrs[attr])
        elif name.endswith('.css'):
            css = data.decode('utf-8')
            urls = list(re.finditer(r'''\burl\(\s*(?:"([^"]*)"|'([^']*)'|([^\s)]*))\s*\)''', css, re.IGNORECASE))
            if len(urls) != len(re.findall(r'\burl\(', css, re.IGNORECASE)):
                raise ValueError('Unqualified native CSS resource syntax')
            for url in urls:
                resource(name, next(value for value in url.groups() if value is not None))
    return checked


def prepare(raw, output, manifest):
    """Write a fresh artifact atomically after validating the complete copy."""
    raw, output = Path(raw).resolve(), Path(output)
    if output.exists() or output.is_symlink():
        raise ValueError('Prepared artifact already exists')
    output = output.resolve()
    if output.is_relative_to(raw) or raw.is_relative_to(output):
        raise ValueError('Raw and prepared artifact directories must be separate')
    files = {}
    for path in sorted(raw.rglob('*')):
        if path.is_symlink():
            raise ValueError('Native artifact contains a symlink')
        if path.is_file():
            files[path.relative_to(raw).as_posix()] = path.read_bytes()
    if not files or 'navigation.json' in files:
        raise ValueError('Expected an unprepared native artifact')
    resources = _resources(files)
    pages = {name: data.decode('utf-8') for name, data in files.items()
             if name.endswith('.html') or name == 'doc-index.json'}
    prepared, counts = prepare_pages(pages, *_modules(Path(manifest)))
    counts['checkedLocalResources'] = resources
    changed = {name: prepared[name].encode('utf-8') if name in prepared else data
               for name, data in files.items()}
    evidence = {'schema': 'libtmux.haddock-navigation/1', 'haddock': '2.33.0',
                'limits': ['Raw output retained; no source freshness or external URL qualification'],
                'counts': counts,
                'files': [{'path': name, 'rawSha256': hashlib.sha256(data).hexdigest(),
                           'preparedSha256': hashlib.sha256(changed[name]).hexdigest()}
                          for name, data in files.items()]}
    staging = Path(tempfile.mkdtemp(prefix='.haddock-prepared-', dir=output.parent))
    try:
        for name, data in changed.items():
            target = staging / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        (staging / 'navigation.json').write_text(json.dumps(evidence, indent=2) + '\n')
        staging.rename(output)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return evidence


def from_plan(plan, manifest):
    """Find the one local library artifact configured for this source tree."""
    plan = json.loads(Path(plan).read_text())
    if plan.get('compiler-id') != 'ghc-9.14.1':
        raise ValueError('Unqualified Cabal plan compiler')
    library = _one([entry for entry in plan.get('install-plan', [])
                    if entry.get('type') == 'configured' and entry.get('style') == 'local'
                    and entry.get('pkg-name') == 'libtmux-haskell'
                    and entry.get('component-name') == 'lib'], 'configured local library')
    source = library.get('pkg-src', {})
    if source.get('type') != 'local' or Path(source.get('path', '')).resolve() != Path(manifest).resolve().parent:
        raise ValueError('Configured library source differs from the selected manifest')
    directory = Path(library.get('dist-dir', ''))
    if not directory.is_absolute():
        raise ValueError('Configured library needs an absolute dist-dir')
    return directory / 'doc/html/libtmux-haskell'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='New, separate artifact directory')
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument('--raw', type=Path, help='Fresh Cabal Haddock HTML directory')
    inputs.add_argument('--build-plan', type=Path, help='Cabal plan for the local library')
    parser.add_argument('--manifest', type=Path, default=Path(__file__).resolve().parents[1] / 'libtmux-haskell.cabal')
    args = parser.parse_args()
    try:
        raw = args.raw if args.raw is not None else from_plan(args.build_plan, args.manifest)
        evidence = prepare(raw, args.output, args.manifest)
    except (OSError, ValueError) as error:
        parser.exit(1, f'Haddock preparation failed: {error}\n')
    print(json.dumps(evidence['counts'], sort_keys=True))


if __name__ == '__main__':
    main()
