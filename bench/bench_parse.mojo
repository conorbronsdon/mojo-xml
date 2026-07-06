"""Throughput benchmark for `fromstring` over the conformance corpus.

Reports wall-clock per parse and MB/s. Run compiled for meaningful numbers:
`mojo build -I src bench/bench_parse.mojo -o bench_parse && ./bench_parse`
(or `pixi run bench`). The corpus is the same set of documents the CPython
byte-match anchor uses, so the benchmark measures the real parse path.
"""
from std.time import perf_counter_ns

from xml import fromstring


def bench(path: String, iterations: Int) raises:
    var source = open(path, "r").read()
    var size_mb = Float64(source.byte_length()) / (1024.0 * 1024.0)
    # Warmup + correctness anchor: count elements once, require stability.
    var warm = fromstring(source.copy())
    var n = len(warm.iter())
    var start = perf_counter_ns()
    for _ in range(iterations):
        var root = fromstring(source.copy())
        if len(root.iter()) != n:
            raise Error("inconsistent parse")
    var elapsed_ns = perf_counter_ns() - start
    var per_parse_ms = Float64(elapsed_ns) / Float64(iterations) / 1e6
    var mb_per_s = size_mb / (per_parse_ms / 1000.0)
    print(path)
    print(t"  {source.byte_length()} bytes, {n} elements:")
    print(t"  {per_parse_ms} ms/parse, {mb_per_s} MB/s")


def main() raises:
    bench("test/data/xml/pom.xml", 2000)
    bench("test/data/xml/soap.xml", 2000)
    bench("test/data/xml/rss.xml", 2000)
    bench("test/data/xml/svg.xml", 2000)
    bench("test/data/xml/multins.xml", 2000)
