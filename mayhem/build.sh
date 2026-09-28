#!/usr/bin/env bash
#
# mayhem/build.sh — build perf_data_converter's `perf_to_profile` CLI (backport target
# perf-to-profile-buggy-mhh-run-15) + the quipper functional-test oracle.
#
# `perf_to_profile` is the real upstream CLI (src/perf_to_profile.cc): reads a perf.data file named
# by `-i`, converts it to a pprof Profile proto via StringToProfiles(), and writes it with `-o`. The
# original mayhemheroes run fuzzed the plain `bazel build src:perf_to_profile` binary as a raw
# file-input target (`perf_to_profile -i @@ -o /dev/null`, no compile-time coverage instrumentation
# at all — Mayhem's own engine instruments/executes the ELF). The project's real build system is
# Bazel + WORKSPACE (http_archive deps resolved from the network on first build) — incompatible with
# the air-gapped PATCH-tier re-run (SPEC 6.5). So, same as the live `mayhem` branch's quipper fuzzer,
# this compiles perf_to_profile's full dependency closure directly with clang++ against apt-provided
# libprotobuf/libelf/zlib (installed in mayhem/Dockerfile) instead of going through Bazel.
# perf_to_profile's own closure (src/BUILD `perf_to_profile` -> perf_to_profile_lib ->
# perf_data_converter -> {perf_data_handler, builder, quipper/{perf_reader,perf_parser}}) has NO
# dependency on abseil/boringssl/gflags/gtest -- gflags/gtest are pulled in only by quipper's own
# test_utils.cc (oracle-only), so the fuzz build stays small.
#
# The functional oracle stays upstream's own src/quipper/perf_reader_test.cc (44 real TEST() cases
# with exact-value EXPECT_EQ assertions on parsed/re-serialized perf.data structures), built with
# NORMAL (unsanitized) flags -- independent of which target is fuzzed.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract -- use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#   DEBUG_FLAGS         -g -gdwarf-3
#   SRC                 /mayhem (the repo source)
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS COVERAGE_FLAGS

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
FUZZOBJ="$BUILD/fuzz-obj" # sanitized objects, for perf_to_profile
TESTOBJ="$BUILD/test-obj" # clean (unsanitized) quipper+test objects, for the oracle
rm -rf "$BUILD"
mkdir -p "$FUZZOBJ" "$TESTOBJ"

STD=-std=c++17
# -I "$SRC" resolves the project's own "src/..."-rooted includes (perf_data_handler.h,
# perf_data_converter.h, builder.h, intervalmap.h, ...); -I "$Q" resolves quipper's in-package
# includes ("compat/proto.h", "dso.h", ...); -I "$Q/compat/non_cros" supplies the open-source
# (non-ChromeOS) compat shims quipper's own headers pull in.
INC=(-I "$SRC" -I "$Q" -I "$Q/compat/non_cros")

# ---------------------------------------------------------------------------
# 1) Generate the protobuf C++ bindings ONCE (shared by both the fuzz and test builds), IN PLACE
#    next to their .proto (mirrors upstream's own Bazel genfile layout) so both the bare
#    ("perf_data.pb.h", used by quipper/compat/proto.h) and the fully-qualified
#    ("src/quipper/perf_data.pb.h", "src/profile.pb.h", used by perf_data_handler.h/builder.h/...)
#    include spellings resolve off the SAME generated files. Use apt's protoc against apt's
#    libprotobuf-dev so headers/ABI match exactly (no vendoring/version-skew risk).
# ---------------------------------------------------------------------------
protoc --proto_path="$Q" --cpp_out="$Q" \
  "$Q/perf_data.proto" "$Q/perf_stat.proto" "$Q/perf_parser_options.proto"
protoc --proto_path="$SRC" --cpp_out="$SRC" "$SRC/src/profile.proto"

PROTO_SRCS=("$Q/perf_data.pb.cc" "$Q/perf_stat.pb.cc" "$Q/perf_parser_options.pb.cc" "$SRC/src/profile.pb.cc")

# perf_to_profile's full source closure (src/BUILD `perf_to_profile` -> perf_to_profile_lib ->
# perf_data_converter -> {perf_data_handler, builder} + quipper's perf_reader/perf_parser stack,
# transitively expanded).
PERF_TO_PROFILE_SRCS=(
  "$Q/base/logging.cc"
  "$Q/compat/log_level.cc"
  "$Q/binary_data_utils.cc"
  "$Q/buffer_reader.cc"
  "$Q/buffer_writer.cc"
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
  "$Q/dso.cc"
  "$Q/address_mapper.cc"
  "$Q/huge_page_deducer.cc"
  "$Q/perf_parser.cc"
  "$SRC/src/perf_data_handler.cc"
  "$SRC/src/perf_data_converter.cc"
  "$SRC/src/builder.cc"
  "$SRC/src/perf_to_profile_lib.cc"
  "$SRC/mayhem/lsan_off.cc"
)

# ---------------------------------------------------------------------------
# 2) FUZZ TARGET `perf_to_profile`: sanitized (ASan+UBSan, halting) + DWARF, plain clang++ -- NO
#    compile-time AFL/SanCov instrumentation. This is a raw file-input CLI (argv `-i <file>`), not a
#    libFuzzer harness; Mayhem drives coverage on the plain sanitized ELF with its own engine. Each
#    input runs in a fresh forked process (Mayhem invokes the binary once per input), so
#    perf_to_profile's global/static state resets every run. mayhem/lsan_off.cc bakes
#    __lsan_is_turned_off() so LeakSanitizer never flags non-relevant leaks (SPEC 6 item 15).
# ---------------------------------------------------------------------------
for src in "${PROTO_SRCS[@]}" "${PERF_TO_PROFILE_SRCS[@]}"; do
  obj="$FUZZOBJ/$(basename "${src%.*}").o"
  "$CXX" $STD "${INC[@]}" $SANITIZER_FLAGS $NONNULL_RELAX $DEBUG_FLAGS \
    -Wno-deprecated-declarations -c "$src" -o "$obj"
done

"$CXX" $STD "${INC[@]}" $SANITIZER_FLAGS $NONNULL_RELAX $DEBUG_FLAGS \
  "$SRC/src/perf_to_profile.cc" "$FUZZOBJ"/*.o -lprotobuf -lz -lcrypto -lelf \
  -o /mayhem/perf_to_profile

# ---------------------------------------------------------------------------
# 3) TEST/oracle build: quipper (incl. the parser/dso layer the tests exercise) + upstream's own
#    perf_reader_test.cc, built with NORMAL (unsanitized) flags -- a separate, clean build so the
#    functional oracle stays honest and never false-fails on benign UB. Left at a fixed path so
#    mayhem/test.sh only has to RUN it. test_utils.cc pulls in perf_parser -> dso -> libelf
#    transitively even though perf_reader_test.cc itself doesn't call those APIs, hence libelf-dev.
# ---------------------------------------------------------------------------
READER_SRCS=(
  "$Q/base/logging.cc"
  "$Q/compat/log_level.cc"
  "$Q/binary_data_utils.cc"
  "$Q/buffer_reader.cc"
  "$Q/buffer_writer.cc"
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

echo "build.sh: OK -- /mayhem/perf_to_profile, $BUILD/perf_reader_test"
