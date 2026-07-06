# Changelog

## v0.1.0 — 2026-07-06

First release. General-purpose XML parsing in pure Mojo, mirroring Python's
`xml.etree.ElementTree`.

- `fromstring(text)` parses a full document into a tree of `Element`s
  (`tag`/`attrib`/`text`/`tail`/`children`), with the ElementTree text/tail
  model.
- Scoped namespace resolution to Clark notation (`{uri}local`); default
  namespaces apply to element names, not unprefixed attributes. The reserved
  `xml` prefix (`xml:lang`/`xml:space`) resolves to the
  `{http://www.w3.org/XML/1998/namespace}` URI and serializes back to `xml:`.
- `find` / `find_opt` / `findall` / `findtext` / `iter` over a pragmatic
  ElementTree path subset (`tag`, `a/b/c`, `*`, `.//tag`, `.//a/b`, `./`,
  `{uri}local`).
- `tostring(elem)` serializes back to well-formed XML with escaping and
  root-declared namespaces; `fromstring(tostring(e))` round-trips.
- XML 1.0 §2.11 line-ending normalization (CRLF / lone CR fold to LF) and
  CDATA-type attribute-value whitespace normalization, both matching
  expat/CPython; character references (`&#13;`, `&#9;`) are preserved.
- Strict well-formedness by default (matches ElementTree); malformed input —
  mismatched/stray tags, unclosed elements, undefined entities, multiple
  document elements, junk text outside the root, unbound prefixes — raises
  rather than being liberally recovered.
- Built on the same fuzzed XML pull parser as
  [mojo-feed](https://github.com/conorbronsdon/mojo-feed) (`XmlPullParser`,
  also exported for streaming over large documents).
- Hardening: `MAX_DEPTH = 512` nesting cap rejects pathologically deep
  documents that would otherwise force the owned-copy tree-walking APIs into
  quadratic time.

**Verification:** 104 tests (65 DOM + 39 pull parser). External anchor —
element-for-element byte match against CPython `xml.etree` on a 14-document
general-XML corpus (SVG, Maven POM, sitemap, SOAP, Android layout, config,
Atom, RSS, XHTML, mixed content, CDATA edge cases, multi-namespace, empties,
CRLF/whitespace), in both strict and `--strip` modes. Fuzzing — 6,000 mutated
iterations over 32 seeds (14 corpus + 18 adversarial synthetics), zero crashes,
zero hangs.
