"""Canonical XML tree dump, byte-compatible with CPython's `test/ref_dump.py`.

Prints one line per element, depth-first (self included):

    <depth>|<clark_tag>|<k=v;... sorted>|text=<esc>|tail=<esc>

Run: mojo run -I src test/anchor_dump.mojo <file.xml> [--strip]
Compared against `python3 test/ref_dump.py <file.xml> [--strip]` to prove the
tree mojo-xml builds matches CPython's element-for-element.
"""
from std.sys import argv
from xml import fromstring, Element


def _esc(s_in: String, strip: Bool) -> String:
    var s = s_in
    if strip:
        s = String(s.strip())
    # order matters: backslash first
    var out = String()
    for ch in s.codepoint_slices():
        if ch == "\\":
            out += "\\\\"
        elif ch == "\n":
            out += "\\n"
        elif ch == "\t":
            out += "\\t"
        elif ch == "\r":
            out += "\\r"
        else:
            out += ch
    return out


def _attrs(el: Element) raises -> String:
    var keys = List[String]()
    for k in el.attrib.keys():
        keys.append(k)
    # simple insertion sort — corpora are tiny
    for i in range(len(keys)):
        for j in range(i + 1, len(keys)):
            if keys[j] < keys[i]:
                var tmp = keys[i]
                keys[i] = keys[j]
                keys[j] = tmp
    var out = String()
    for i in range(len(keys)):
        if i > 0:
            out += ";"
        out += keys[i] + "=" + el.attrib[keys[i]]
    return out


def _walk(el: Element, depth: Int, mut out: String, strip: Bool) raises:
    out += (
        String(depth)
        + "|"
        + el.tag
        + "|"
        + _attrs(el)
        + "|text="
        + _esc(el.text, strip)
        + "|tail="
        + _esc(el.tail, strip)
        + "\n"
    )
    for child in el.children:
        _walk(child, depth + 1, out, strip)


def main() raises:
    var args = argv()
    var strip = False
    var path = String()
    for i in range(1, len(args)):
        var a = String(args[i])
        if a == "--strip":
            strip = True
        else:
            path = a
    var src = open(path, "r").read()
    var root = fromstring(src^)
    var out = String()
    _walk(root, 0, out, strip)
    print(out, end="")
