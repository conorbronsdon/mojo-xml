# Changelog

## v0.1.0 — 2026-07-06

First release. General-purpose XML parsing in pure Mojo, mirroring Python's
`xml.etree.ElementTree`.

- `fromstring(text)` parses a full document into a tree of `Element`s
  (`tag`/`attrib`/`text`/`tail`/`children`), with the ElementTree text/tail
  model.
- Scoped namespace resolution to Clark notation (`{uri}local`); default
  namespaces apply to element names, not unprefixed attributes.
- `find` / `find_opt` / `findall` / `findtext` / `iter` over a pragmatic
  ElementTree path subset (`tag`, `a/b/c`, `*`, `.//tag`, `.//a/b`, `./`,
  `{uri}local`).
- `tostring(elem)` serializes back to well-formed XML with escaping and
  root-declared namespaces; `fromstring(tostring(e))` round-trips.
- Strict well-formedness by default (matches ElementTree); malformed input
  raises rather than being liberally recovered.
- Built on the same fuzzed XML pull parser as
  [mojo-feed](https://github.com/conorbronsdon/mojo-feed) (`XmlPullParser`,
  also exported for streaming over large documents).
- Hardening: `MAX_DEPTH = 512` nesting cap rejects pathologically deep
  documents that would otherwise force the owned-copy tree-walking APIs into
  quadratic time.

**Verification:** 77 tests (47 DOM + 30 pull parser). External anchor —
element-for-element byte match against CPython `xml.etree` on a 6-document
general-XML corpus (SVG, Maven POM, sitemap, SOAP, Android layout, config).
Fuzzing — 1,500 mutated iterations incl. adversarial synthetics, zero crashes,
zero hangs.
