#!/usr/bin/env bash
#
# mayhem/test.sh — RUN perf_data_converter's own quipper functional test suite (already built by
# mayhem/build.sh at $SRC/mayhem-build/perf_reader_test). This is upstream's REAL
# src/quipper/perf_reader_test.cc (44 gtest TEST() cases with EXPECT_EQ assertions on exact parsed/
# re-serialized perf.data field values — not just "didn't crash"), built with normal (unsanitized)
# flags and dynamically linked (checked below), so LD_PRELOAD sabotage (_exit(0) on every non-system
# exec) makes it fail loudly instead of silently passing.
#
# Some fixtures live under src/quipper/testdata/ and are addressed with a path RELATIVE to that
# directory (upstream's own non-bazel convention, see GetTestInputFilePath() in test_utils.cc), so
# this cd's into src/quipper before running the binary.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BIN="$SRC/mayhem-build/perf_reader_test"
if [ ! -x "$BIN" ]; then
  echo "test.sh: $BIN missing -- mayhem/build.sh should have produced it" >&2
  emit_ctrf "cmake-gtest" 0 1 0
  exit $?
fi

# Regression guard: the oracle binary must be DYNAMICALLY linked, or LD_PRELOAD-based sabotage
# detection cannot touch it and the anti-reward-hack check silently degrades (SPEC 6.3).
if ! file "$BIN" | grep -q 'dynamically linked'; then
  echo "test.sh: $BIN is not dynamically linked -- oracle would be unsabotageable" >&2
  emit_ctrf "cmake-gtest" 0 1 0
  exit $?
fi

cd "$SRC/src/quipper"   # GetTestInputFilePath() resolves testdata/* relative to this directory

OUT="$(mktemp)"
"$BIN" --gtest_print_time=0 >"$OUT" 2>&1
rc=$?
cat "$OUT"

# Parse gtest's own summary line: "[==========] N tests from M test suites ran."
# and "[  PASSED  ] P tests." / "[  FAILED  ] F tests, listed below:" -- these come from the
# process's own stdout, so a neutered ( _exit(0) before running any TEST()) binary prints NOTHING
# here and this parse yields 0/0, which is a FAILURE below (never a silent pass).
total="$(grep -oE '^\[==========\] [0-9]+ tests? from' "$OUT" | grep -oE '[0-9]+' | head -1)"
passed="$(grep -oE '^\[  PASSED  \] [0-9]+ tests?' "$OUT" | grep -oE '[0-9]+' | head -1)"
failed="$(grep -oE '^\[  FAILED  \] [0-9]+ tests?' "$OUT" | grep -oE '[0-9]+' | head -1)"
total="${total:-0}" ; passed="${passed:-0}" ; failed="${failed:-0}"
rm -f "$OUT"

if [ "$total" -eq 0 ] || { [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; }; then
  # Binary exited non-zero (crash/abort/killed-by-sabotage-shim) without a clean gtest summary, or
  # printed no summary at all (e.g. sabotaged _exit(0) before any TEST() ran) -- an unconditional
  # failure, never a skip.
  echo "test.sh: perf_reader_test produced no usable gtest summary (rc=$rc, total=$total)" >&2
  emit_ctrf "cmake-gtest" 0 1 0
  exit $?
fi

emit_ctrf "cmake-gtest" "$passed" "$failed" $(( total - passed - failed > 0 ? total - passed - failed : 0 ))
