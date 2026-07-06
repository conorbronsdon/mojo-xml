#!/usr/bin/env python3
"""Canonical XML tree dump via CPython's xml.etree.ElementTree.

Emits one line per element, depth-first (self included), in a deterministic
format a Mojo dumper can reproduce byte-for-byte:

    <depth>|<clark_tag>|<k=v;... sorted>|text=<esc>|tail=<esc>

text/tail None -> empty. Newlines/tabs escaped so lines stay single-line and
diffs stay readable. With --strip, text/tail whitespace is stripped (looser
comparison that ignores indentation-only text nodes).
"""
import sys
import xml.etree.ElementTree as ET


def esc(s, strip):
    if s is None:
        s = ""
    if strip:
        s = s.strip()
    return s.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r")


def attrs(el):
    # ElementTree already stores namespaced attrs in Clark notation.
    return ";".join(f"{k}={v}" for k, v in sorted(el.attrib.items()))


def walk(el, depth, out, strip):
    out.append(f"{depth}|{el.tag}|{attrs(el)}|text={esc(el.text, strip)}|tail={esc(el.tail, strip)}")
    for child in el:
        walk(child, depth + 1, out, strip)


def main():
    strip = "--strip" in sys.argv
    paths = [a for a in sys.argv[1:] if not a.startswith("--")]
    for p in paths:
        root = ET.parse(p).getroot()
        out = []
        walk(root, 0, out, strip)
        sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
