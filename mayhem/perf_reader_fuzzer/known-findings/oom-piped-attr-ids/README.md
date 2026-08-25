# OOM: unbounded allocation from an attacker-controlled count field (piped perf.data)

**Found by:** `mayhem/perf_reader_fuzzer` (`quipper::PerfReader::ReadFromPointer`), fork-mode
smoke run (`-fork=4 -rss_limit_mb=2560`) during integration, seeded from the shipped corpus.

**Repro:** `repro` (38 bytes) — a minimal piped-format perf.data stream (`PERFILE2` piped magic +
header size 0x10, followed by a single malformed event record). Run:

```
/mayhem/perf_reader_fuzzer-standalone mayhem/perf_reader_fuzzer/known-findings/oom-piped-attr-ids/repro
```

under a bounded RSS (e.g. `ulimit -v` or libFuzzer's `-rss_limit_mb`) to observe the OOM; it does
not crash under an unbounded run, it just allocates far more memory than the 38-byte input
justifies.

**Cause (best-effort, not fully root-caused):** several of the piped-record read paths in
`src/quipper/perf_reader.cc` size a `std::vector`/array directly from a count field taken from the
event payload before validating it against the number of bytes actually remaining in the input
(e.g. `ids->resize(num_ids)` at `perf_reader.cc:998`, `ids.resize(nr_ids)` at `perf_reader.cc:1581`,
and the `new T[count]` allocations in `sample_info_reader.cc`/`perf_serializer.cc` follow the same
pattern). A crafted small input with a large count field therefore drives a multi-GB allocation
attempt. Some sibling paths in the same file DO clamp their count (see
`PerfReaderTest.CheckNumSiblingsForCPUTopology`, which rejects `num_thread_siblings > 1000`) — this
finding is a sibling code path that doesn't have the same bound.

**Impact:** denial of service (OOM) on untrusted `perf.data` input; not a memory-corruption bug.

**Suggested upstream fix:** validate every attacker-controlled count/size field against
`remaining_bytes_in_input / sizeof(element)` (the same style of check `CorrectlyReadsPerfEventAttrSize`
and `CheckNumSiblingsForCPUTopology` already apply elsewhere in this file) before calling
`resize()`/`new T[count]`.

Not wired into `mayhem/perf_reader_fuzzer/testsuite/` (seeds are replayed every run; an OOM
reproducer there would burn RSS budget on every future run instead of exercising the parser).
