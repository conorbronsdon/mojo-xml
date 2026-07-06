<div align="center">

# mojo-xml

**General-purpose XML parsing in pure Mojo — an `xml.etree.ElementTree`-shaped API. No Python dependencies, no FFI.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)
[![Mojo](https://img.shields.io/badge/Mojo-1.0.0b3%2B_nightly-orange?style=flat-square)](https://mojolang.org)
[![Podcast](https://img.shields.io/badge/Podcast-Chain_of_Thought-purple?style=flat-square)](https://chainofthought.show)
[![X](https://img.shields.io/badge/X-@ConorBronsdon-black?style=flat-square&logo=x)](https://x.com/ConorBronsdon)

</div>

As of mid-2026 the Mojo ecosystem has JSON, TOML, CSV, and YAML parsers, and a
feed parser ([mojo-feed](https://github.com/conorbronsdon/mojo-feed)) — but no
general-purpose XML library. mojo-xml fills that gap: parse any XML document
into a tree of `Element`s and walk it with the API Python developers already
know from `xml.etree.ElementTree`. It's built on the same fuzzed pull parser
that powers mojo-feed, with a proper scoped-namespace DOM layer on top.

## What it does

- **Parse to a tree**: `fromstring(text)` returns the root `Element`; every
  element carries `tag`, `attrib`, `text`, `tail`, and `children` — the exact
  ElementTree model, including the `text`/`tail` split that trips up most
  hand-rolled parsers (`<a>t0<b/>t1</a>` → `a.text="t0"`, `b.tail="t1"`).
- **Namespaces, resolved properly**: prefixes and default `xmlns` resolve to
  Clark notation (`<a:foo xmlns:a="http://x">` → tag `{http://x}foo`), with a
  *scoped* xmlns stack so nested prefix redefinition is honored. Default
  namespaces apply to element names but not unprefixed attributes, per the XML
  namespaces spec.
- **Query**: `find` / `find_opt` / `findall` / `findtext` / `iter` with a
  pragmatic ElementTree path subset — `tag`, `a/b/c`, `*`, `.//tag`,
  `.//a/b`, leading `./`, and Clark-notation `{uri}local`.
- **Serialize**: `tostring(elem)` writes well-formed XML back out, escaping
  text and attribute values and declaring collected namespaces on the root.
  `fromstring(tostring(e))` round-trips to a structurally-equal tree.
- **Entities, CDATA, comments, PIs, DOCTYPE, and encoding normalization**
  (UTF-16/BOM/Latin-1/Windows-1252) — inherited from the underlying pull parser.
- **Strict by default**: like ElementTree, `fromstring` rejects malformed input
  — mismatched or stray end tags, unclosed elements, undefined entities,
  multiple document elements (junk after the root), non-whitespace text outside
  the root, and unbound namespace prefixes — rather than silently recovering.
  (The reserved `xml:` prefix is implicitly bound and needs no declaration.)

## What it deliberately does NOT do (yet)

- **Full XPath.** `find`/`findall` support the common ElementTree path subset
  above, not predicates, axes, or functions.
- **DTD / schema validation.** Well-formedness is checked; validation against a
  DTD or XSD is out of scope for v0.1.
- **Streaming for unbounded input.** `fromstring` builds a full in-memory tree.
  For event-at-a-time processing over huge documents, drop down to the
  `XmlPullParser` (also exported) — the same pull API mojo-feed uses.

## Install

With [pixi](https://pixi.prefix.dev):

```bash
pixi run test
pixi run demo
```

Or with uv:

```bash
uv venv
uv pip install mojo --index https://whl.modular.com/nightly/simple/ --prerelease allow
.venv/bin/mojo run -I src test/test_etree.mojo
```

Requires a Mojo nightly (`>=1.0.0b3`).

## Usage

```mojo
from xml import fromstring, tostring, Element

def main() raises:
    var root = fromstring(String(
        "<catalog><book id='b1'><title>Mojo</title></book></catalog>"
    ))
    print(root.tag)                        # catalog
    var book = root.find("book")           # first <book>
    print(book.get("id"))                  # b1
    print(book.findtext("title"))          # Mojo

    for t in root.iter("title"):           # every <title> at any depth
        print(t.text)

    print(tostring(root))                  # serialize back to XML
```

Namespaced documents resolve to Clark notation:

```mojo
var svg = fromstring(open("logo.svg", "r").read())
# svg.tag == "{http://www.w3.org/2000/svg}svg"
for rect in svg.iter("{http://www.w3.org/2000/svg}rect"):
    print(rect.get("width"), rect.get("height"))
```

`find` raises if there's no match; `find_opt` returns an `Optional[Element]`:

```mojo
var maybe = root.find_opt("missing")
if maybe:
    print(maybe.value().tag)
```

## Conformance & robustness

**Byte-for-byte against CPython.** `test/anchor_run.py` parses a corpus of real
general-XML documents (an SVG, a Maven `pom.xml`, a sitemap, a SOAP envelope,
an Android layout, and an entity-heavy config file) two ways — with mojo-xml and
with Python's own `xml.etree.ElementTree` — and dumps each tree in an identical
canonical format. **All 6 match element-for-element** in strict, whitespace-exact
mode: Clark-notation namespaces, sorted attributes, the `text`/`tail` model, and
entity decoding are identical to CPython.

```bash
pixi run test                              # 47 DOM tests + 30 pull-parser tests
python3 test/anchor_run.py --strip  # optional: env MOJO=<mojo binary>
```

**Tests.** 77 total: `test/test_etree.mojo` (47 — parsing, text/tail, entities,
CDATA, namespaces, find/findall/findtext/iter, mutation, serialization and
escaping, malformed-input error cases) and `test/test_pull.mojo` (30 — the
underlying tokenizer).

**Fuzzing.** `test/fuzz_drive.py` mutates the corpus plus four adversarial
synthetics (deep nesting, wide fan-out, a namespace bomb, and an entity flood):
1,500 iterations with **zero crashes and zero hangs** — malformed input either
parses or raises a clean error. Hostile input is bounded: element nesting is
capped (`MAX_DEPTH = 512`) so a pathologically deep document raises instead of
driving the tree-walking APIs into quadratic time.

## Design notes & limitations worth knowing

- **`iter` and `tostring` return owned copies**, not references (Mojo's
  ownership model). Cost is linear in the visited subtree for any real document;
  the `MAX_DEPTH` cap bounds the worst case on adversarial deep chains.
- **`SubElement(parent, tag)` returns a snapshot copy**, not a live reference
  into `parent.children`. To build a rich child, construct it fully, then
  `parent.append(child^)`.
- **Serialization order** of attributes and generated namespace prefixes
  follows `Dict` insertion order; round-trip *structural* equality holds
  regardless of order.
- **Namespace scoping** is lexical (pushed/popped as elements open and close) —
  stronger than the document-flat resolution the feed parser uses.

## Part of a pure-Mojo library suite

Pure-Mojo libraries that mirror familiar Python stdlib and PyPI APIs, filling
gaps in the native Mojo ecosystem:

- [mojo-feed](https://github.com/conorbronsdon/mojo-feed) — RSS/Atom/JSON Feed
  parsing (Python's `feedparser`); shares this library's pull parser
- [mojo-captions](https://github.com/conorbronsdon/mojo-captions) — SRT and
  WebVTT subtitle/transcript parsing (no Python stdlib parallel)
- [mojo-html](https://github.com/conorbronsdon/mojo-html) — HTML parsing and
  article extraction (Python's `readability`)
- [mojo-markdown](https://github.com/conorbronsdon/mojo-markdown) —
  CommonMark markdown parsing (Python's `markdown`)
- [mojo-unicodedata](https://github.com/conorbronsdon/mojo-unicodedata) —
  Unicode normalization and case folding (Python's `unicodedata`)
- [mojo-url](https://github.com/conorbronsdon/mojo-url) — URL parsing and
  encoding (Python's `urllib.parse`)
- [mojo-diff](https://github.com/conorbronsdon/mojo-diff) — text diffing
  (Python's `difflib`)
- [mojo-template](https://github.com/conorbronsdon/mojo-template) — a
  Jinja-flavored template engine (Python's `jinja2`)
- [mojo-tar](https://github.com/conorbronsdon/mojo-tar) — tar archive
  reading and writing (Python's `tarfile`)
- [mojo-redis](https://github.com/conorbronsdon/mojo-redis) — a Redis
  client (Python's `redis-py`)

## Contributing

Issues and PRs welcome — especially real-world XML that parses differently from
`xml.etree` (attach the document or a snippet) and path-matching gaps. Run
`pixi run test` and `python3 test/anchor_run.py` before sending a PR.

## About

Built by [Conor Bronsdon](https://conorbronsdon.com) — host of
[Chain of Thought](https://chainofthought.show), a podcast about AI agents,
infrastructure, and engineering. Find me on [X](https://x.com/ConorBronsdon) or
[LinkedIn](https://www.linkedin.com/in/conorbronsdon).

---

## Disclaimer

*All views, opinions, and statements expressed on this account/in this repo are solely my own and are made in my personal capacity. They do not reflect, and should not be construed as reflecting, the views, positions, or policies of Modular. This account is not affiliated with, authorized by, or endorsed by my employer in any way.*

## License

Licensed under the [MIT License](LICENSE).
