#!/usr/bin/env bash
#
# mayhem/build.sh — build perf_data_converter's quipper PerfReader fuzz target + oracle.
#
# perf_data_converter (google/perf_data_converter) ships its own libFuzzer harness in-tree at
# src/quipper/perf_reader_fuzzer.cc (LLVMFuzzerTestOneInput -> PerfReader::ReadFromPointer, no
# file I/O — exactly the byte-buffer-only shape this contract wants) but the project's real build
# system is Bazel + Bzlmod (MODULE.bazel, no WORKSPACE), which resolves googletest/protobuf/absl/
# etc from the Bazel Central Registry over the network on first build. That's incompatible with
# the air-gapped PATCH-tier re-run (SPEC 6.5), and the fuzzer target isn't even wired into a BUILD
# rule upstream (it looks OSS-Fuzz-style: built directly by an external build.sh, not by bazel).
#
# So this compiles quipper directly with clang++ against apt-provided libprotobuf/libgflags/
# libgtest/libelf (installed in mayhem/Dockerfile) instead of going through Bazel at all. quipper's
# own PerfReader library has NO dependency on abseil/boringssl/gflags (those are only pulled in by
# perf_data_converter.cc / perf_data_handler.cc, which sit ABOVE PerfReader and are not part of the
# fuzzed surface), so the fuzz build stays small. The real oracle is upstream's own
# src/quipper/perf_reader_test.cc (44 real TEST() cases with exact-value EXPECT_EQ assertions on
# parsed/re-serialized perf.data structures) — test_utils.cc pulls in perf_parser -> dso -> libelf
# transitively even though perf_reader_test.cc itself doesn't call those APIs, hence libelf-dev.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#   DEBUG_FLAGS         -g -gdwarf-3
#   SRC                 /mayhem (the repo source)
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

# BufferWriter::WriteData (buffer_writer.cc:18) does `memcpy(buffer_ + offset_, src, size)` where
# src can legitimately be nullptr when size==0 (a completely standard zero-length-copy idiom, hit
# constantly while parsing malformed/truncated perf.data records). UBSan's nonnull-attribute check
# flags that because memcpy's 2nd arg is declared nonnull even for a 0-length call, and with
# -fno-sanitize-recover=all it then aborts almost immediately -- fork-mode runs showed the exact
# same PC in the overwhelming majority of "crash" artifacts even though coverage was still growing.
# Relax ONLY this one check; ASan and the rest of UBSan stay halting.
NONNULL_RELAX="-fno-sanitize=nonnull-attribute"

cd "$SRC"

Q="$SRC/src/quipper"
BUILD="$SRC/mayhem-build"
GEN="$BUILD/gen"          # generated protobuf .pb.{h,cc}
FUZZOBJ="$BUILD/fuzz-obj" # sanitized quipper library objects, for the fuzz targets
TESTOBJ="$BUILD/test-obj" # clean (unsanitized) quipper+test objects, for the oracle
rm -rf "$BUILD"
mkdir -p "$GEN" "$FUZZOBJ" "$TESTOBJ"

STD=-std=c++17
INC=(-I "$Q" -I "$GEN" -I "$Q/compat/non_cros")

# ---------------------------------------------------------------------------
# 1) Generate the protobuf C++ bindings ONCE (shared by both the fuzz and test
#    builds). Use apt's protoc against apt's libprotobuf-dev so headers/ABI match exactly
#    (both come from the same Debian package version — no vendoring/version-skew risk).
# ---------------------------------------------------------------------------
protoc --proto_path="$Q" --cpp_out="$GEN" \
  "$Q/perf_data.proto" "$Q/perf_stat.proto" "$Q/perf_parser_options.proto"

PROTO_SRCS=("$GEN/perf_data.pb.cc" "$GEN/perf_stat.pb.cc" "$GEN/perf_parser_options.pb.cc")

# quipper/PerfReader's own source closure (per src/quipper/BUILD's `perf_reader` cc_library deps,
# transitively expanded) — deliberately NOT including dso/address_mapper/huge_page_deducer/
# perf_parser/perf_protobuf_io/run_command, none of which PerfReader needs; keeping the fuzz build
# to exactly the code the harness exercises.
READER_SRCS=(
  "$Q/base/logging.cc"
  "$Q/compat/log_level.cc"
  "$Q/binary_data_utils.cc"
  "$Q/buffer_reader.cc"
  "$Q/buffer_writer.cc"
  "$Q/byte_swap_utils.cc"
  "$Q/data_reader.cc"
  "$Q/data_writer.cc"
  "$Q/file_reader.cc"
  "$Q/file_utils.cc"
  "$Q/perf_buildid.cc"
  "$Q/perf_data_utils.cc"
  "$Q/perf_serializer.cc"
  "$Q/perf_reader.cc"
  "$Q/sample_info_reader.cc"
  "$Q/string_utils.cc"
)

# ---------------------------------------------------------------------------
# 2) FUZZ build: quipper library + harness, ASan+UBSan (or --build-arg override), instrumented for
#    coverage. -fsanitize=fuzzer-no-link is REQUIRED on every LIBRARY translation unit (not just the
#    harness TU) -- $LIB_FUZZING_ENGINE only covers the TU it links into, and $SANITIZER_FLAGS alone
#    carries no coverage flags, so without this the library compiles/runs but records 0 edges.
#    Applied unconditionally, including when $SANITIZER_FLAGS is empty (explicit no-sanitizer build).
# ---------------------------------------------------------------------------
for src in "${PROTO_SRCS[@]}" "${READER_SRCS[@]}"; do
  obj="$FUZZOBJ/$(basename "${src%.*}").o"
  "$CXX" $STD "${INC[@]}" $SANITIZER_FLAGS $NONNULL_RELAX $DEBUG_FLAGS -fsanitize=fuzzer-no-link \
    -Wno-deprecated-declarations -c "$src" -o "$obj"
done
FUZZ_OBJS=("$FUZZOBJ"/*.o)

# libFuzzer-driven target: reads bytes only from the fuzzer (no file I/O, no absolute paths).
"$CXX" $STD "${INC[@]}" $SANITIZER_FLAGS $NONNULL_RELAX $DEBUG_FLAGS -fsanitize=fuzzer-no-link $LIB_FUZZING_ENGINE \
  "$Q/perf_reader_fuzzer.cc" "${FUZZ_OBJS[@]}" -lprotobuf -lcrypto \
  -o /mayhem/perf_reader_fuzzer

# Standalone (non-fuzzer) reproducer: same harness, $STANDALONE_FUZZ_MAIN instead of libFuzzer --
# one input file, runs LLVMFuzzerTestOneInput once, natural crash, no libFuzzer runtime. Compile
# the driver as C first so clang++ doesn't mangle its LLVMFuzzerTestOneInput reference.
"$CC" $SANITIZER_FLAGS $NONNULL_RELAX $DEBUG_FLAGS -fsanitize=fuzzer-no-link -c "$STANDALONE_FUZZ_MAIN" \
  -o "$BUILD/standalone_main.o"
"$CXX" $STD "${INC[@]}" $SANITIZER_FLAGS $NONNULL_RELAX $DEBUG_FLAGS -fsanitize=fuzzer-no-link \
  "$Q/perf_reader_fuzzer.cc" "$BUILD/standalone_main.o" "${FUZZ_OBJS[@]}" -lprotobuf -lcrypto \
  -o /mayhem/perf_reader_fuzzer-standalone

# ---------------------------------------------------------------------------
# 3) TEST/oracle build: quipper (incl. the parser/dso layer the tests exercise) + upstream's own
#    perf_reader_test.cc, built with NORMAL (unsanitized) flags -- a separate, clean build so the
#    functional oracle stays honest and never false-fails on benign UB. Left at a fixed path so
#    mayhem/test.sh only has to RUN it.
# ---------------------------------------------------------------------------
TEST_SRCS=(
  "${PROTO_SRCS[@]}"
  "${READER_SRCS[@]}"
  "$Q/dso.cc"
  "$Q/address_mapper.cc"
  "$Q/huge_page_deducer.cc"
  "$Q/perf_parser.cc"
  "$Q/perf_protobuf_io.cc"
  "$Q/run_command.cc"
  "$Q/test_perf_data.cc"
  "$Q/test_utils.cc"
  "$Q/perf_test_files.cc"
  "$Q/perf_reader_test.cc"
  "$Q/test_runner.cc"
)
for src in "${TEST_SRCS[@]}"; do
  obj="$TESTOBJ/$(basename "${src%.*}").o"
  "$CXX" $STD "${INC[@]}" -O2 $COVERAGE_FLAGS -Wno-deprecated-declarations -c "$src" -o "$obj"
done
"$CXX" $STD $COVERAGE_FLAGS "$TESTOBJ"/*.o \
  -lprotobuf -lcrypto -lgflags -lgtest -lelf -lpthread \
  -o "$BUILD/perf_reader_test"

echo "build.sh: OK -- /mayhem/perf_reader_fuzzer(-standalone), $BUILD/perf_reader_test"
