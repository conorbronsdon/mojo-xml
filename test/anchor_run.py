#!/usr/bin/env python3
"""External-anchor conformance: prove mojo-xml builds the same tree as CPython.

For every document in test/data/xml/, dump the parsed tree two ways —
mojo-xml (test/anchor_dump.mojo) and CPython's xml.etree (test/ref_dump.py) —
in an identical canonical format, and assert they match byte-for-byte. This is
the ground-truth check behind the README's conformance claim.

Usage:
    python3 test/anchor_run.py            # strict (whitespace-exact)
    python3 test/anchor_run.py --strip    # ignore indentation-only text/tail

The Mojo binary is taken from $MOJO, else `mojo` on PATH.
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MOJO = os.environ.get("MOJO", "mojo")
STRIP = "--strip" in sys.argv


def dump_mojo(path, strip):
    cmd = [MOJO, "run", "-I", "src", "test/anchor_dump.mojo", str(path)]
    if strip:
        cmd.append("--strip")
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    # the toolchain prints an unrelated Crashpad line to stderr on some hosts
    if r.returncode != 0:
        raise RuntimeError(f"mojo dump failed for {path}:\n{r.stderr}")
    return r.stdout


def dump_ref(path, strip):
    cmd = [sys.executable, "test/ref_dump.py", str(path)]
    if strip:
        cmd.append("--strip")
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"ref dump failed for {path}:\n{r.stderr}")
    return r.stdout


def main():
    corpus = sorted((ROOT / "test/data/xml").glob("*.xml"))
    if not corpus:
        print("no corpus files found", file=sys.stderr)
        return 1
    mode = "strip" if STRIP else "strict"
    passed = failed = 0
    for path in corpus:
        mojo_out = dump_mojo(path, STRIP)
        ref_out = dump_ref(path, STRIP)
        if mojo_out == ref_out:
            print(f"  ✓ {path.name}")
            passed += 1
        else:
            print(f"  ✗ {path.name}")
            failed += 1
            m = mojo_out.splitlines()
            r = ref_out.splitlines()
            for i in range(max(len(m), len(r))):
                mline = m[i] if i < len(m) else "<none>"
                rline = r[i] if i < len(r) else "<none>"
                if mline != rline:
                    print(f"      mojo: {mline}")
                    print(f"      ref : {rline}")
    print(f"anchor ({mode}): {passed} matched, {failed} differed "
          f"(of {len(corpus)}) vs CPython xml.etree {__import__('xml.etree.ElementTree', fromlist=['VERSION']).VERSION}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
