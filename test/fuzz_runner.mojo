"""Fuzz target: parse the file given as argv[1] into a tree and touch it.

Any in-language error is fine (exit 0 with "raised:"); what must never happen
is a crash (segfault) or a hang. Also exercises iter()/tostring() so tree
traversal and serialization are on the fuzzed path, not just parsing.
"""
from std.sys import argv

from xml import fromstring, tostring


def main():
    try:
        var root = fromstring(open(String(argv()[1]), "r").read())
        var n = len(root.iter())
        var s = tostring(root)
        print("elements:", n, "serialized:", s.byte_length())
    except e:
        print("raised:", e)
