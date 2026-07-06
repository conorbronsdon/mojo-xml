"""Mutation fuzzer for mojo-xml: mutate real XML bytes and require the parser
(fromstring) plus iter()/tostring() to terminate without crashing or hanging.
Raising a clean in-language error is a pass; a segfault or a >10s hang is a
failure and the offending input is saved to test/fuzz_failures/.

    <runner-binary> is a compiled test/fuzz_runner.mojo
    python3 test/fuzz_drive.py <runner-binary> [iterations]
"""
import os
import random
import subprocess
import sys

RUNNER = sys.argv[1]
TESTDIR = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(TESTDIR, "data", "xml")
SEEDS = [os.path.join(CORPUS, f) for f in os.listdir(CORPUS) if f.endswith(".xml")]
ITERATIONS = int(sys.argv[2]) if len(sys.argv) > 2 else 1500
WORK = os.path.join(TESTDIR, "fuzz_case.xml")
FAIL_DIR = os.path.join(TESTDIR, "fuzz_failures")

INTERESTING = [b"<", b">", b"&", b"]]>", b"<!--", b"<![CDATA[", b'"', b"'",
               b"&#", b"&#x", b"</", b"/>", b"<?", b"\x00", b"\xff", b"=",
               b"<a>", b"</a>", b"xmlns=", b"xmlns:x=", b"{", b"}",
               b"&amp;", b"&#x110000;", b":", b" ", b"\t"]

# Adversarial synthetic seeds beyond the corpus, one per bug class:
#   deep nesting (stack-overflow bait), wide fan-out, namespace bombs,
#   pathological entity/char-ref expansion, malformed UTF-8, huge attribute
#   counts, oversized single tokens, and comment/CDATA/newline edge cases.
SYNTH = [
    # Deep nesting + wide fan-out (tree-walk quadratic / recursion bait).
    (b"<r>" + b"<a>" * 5000 + b"</a>" * 5000 + b"</r>"),
    (b"<r>" + b"<a/>" * 20000 + b"</r>"),
    # Namespace bombs: many declarations, and one prefix rebound repeatedly.
    (b"<r " + b" ".join(b'xmlns:n%d="u%d"' % (i, i) for i in range(400)) + b"/>"),
    (b"<r>" + b"".join(b'<n:a xmlns:n="u%d">' % i for i in range(300))
        + b"</n:a>" * 300 + b"</r>"),
    # Pathological entity / char-reference expansion.
    (b"<r>" + b"&amp;" * 10000 + b"</r>"),
    (b"<r>" + b"&#38;" * 8000 + b"&#x2764;" * 2000 + b"</r>"),
    (b"<r>" + b"&#x110000;" * 5000 + b"&#xD800;" * 5000 + b"</r>"),  # overflow/surrogate
    (b"<r>" + b"&unknownentity;" * 5000 + b"</r>"),  # unknown -> strict raise
    # Huge attribute count and one enormous attribute value.
    (b"<r " + b" ".join(b'a%d="%d"' % (i, i) for i in range(2000)) + b"/>"),
    (b'<r big="' + b"x" * 100000 + b'"/>'),
    # Malformed UTF-8 sprinkled through markup and text.
    (b"<r a=\"\xff\xfe\x80\">te\xc3\x28xt\xed\xa0\x80</r>"),
    (b"<\xff\xfea>x</\xff\xfea>"),
    # Comment / CDATA / PI edge cases.
    (b"<r><!--" + b"-" * 20000 + b"--><![CDATA[" + b"]" * 20000 + b"]]></r>"),
    (b"<r><![CDATA[]]]]]]]]]]]]]]]]]]]]></r>"),  # many ']' near terminator
    (b"<r>" + b"<!--c-->" * 5000 + b"text</r>"),
    # Newline normalization stress: lots of CR / CRLF / lone-CR runs.
    (b"<r>" + b"\r\n" * 10000 + b"x\r\ry" + b"</r>"),
    (b'<r a="' + b"\r\n\t " * 5000 + b'"/>'),  # attr whitespace normalization
    # Oversized single element name / tag.
    (b"<" + b"a" * 50000 + b">x</" + b"a" * 50000 + b">"),
]

random.seed(20260706)
seeds = [open(s, "rb").read() for s in SEEDS] + SYNTH
crashes, hangs = [], []

for i in range(ITERATIONS):
    data = bytearray(random.choice(seeds))
    for _ in range(random.randint(1, 8)):
        op = random.randrange(5)
        if op == 0 and data:  # byte flip
            data[random.randrange(len(data))] = random.randrange(256)
        elif op == 1 and data:  # truncate
            data = data[: random.randrange(1, len(data) + 1)]
        elif op == 2 and data:  # delete chunk
            a = random.randrange(len(data))
            del data[a:min(len(data), a + random.randrange(1, 64))]
        elif op == 3:  # insert interesting token
            p = random.randrange(len(data) + 1)
            data[p:p] = random.choice(INTERESTING)
        elif op == 4 and data:  # duplicate chunk (grows nesting/fan-out)
            a = random.randrange(len(data))
            b = min(len(data), a + random.randrange(1, 128))
            p = random.randrange(len(data) + 1)
            data[p:p] = data[a:b]
    with open(WORK, "wb") as f:
        f.write(bytes(data))
    try:
        r = subprocess.run([RUNNER, WORK], capture_output=True, timeout=10)
        if r.returncode < 0 or r.returncode == 139:
            crashes.append((i, r.returncode))
            os.makedirs(FAIL_DIR, exist_ok=True)
            open(f"{FAIL_DIR}/crash_{i}.xml", "wb").write(bytes(data))
    except subprocess.TimeoutExpired:
        hangs.append(i)
        os.makedirs(FAIL_DIR, exist_ok=True)
        open(f"{FAIL_DIR}/hang_{i}.xml", "wb").write(bytes(data))

print(f"iterations: {ITERATIONS}")
print(f"seeds: {len(seeds)} ({len(SEEDS)} corpus + {len(SYNTH)} synthetic)")
print(f"crashes (signal): {len(crashes)} {crashes[:10]}")
print(f"hangs (>10s): {len(hangs)} {hangs[:10]}")
sys.exit(1 if (crashes or hangs) else 0)
