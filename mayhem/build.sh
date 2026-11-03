#!/usr/bin/env bash
#
# mayhem/build.sh — build darkhttpd's fuzz harnesses (sanitized, DWARF 3) and its functional-test
# binaries (normal flags). Runs inside the commit image as `mayhem` in /mayhem. Offline-safe and
# idempotent: only compiles checked-in sources, so a re-run on a built tree just rebuilds.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
OUT="$SRC"
B="$SRC/mayhem/build"
mkdir -p "$B"

# 1) Functional-test binaries, NORMAL flags (no sanitizers): upstream's unit tests plus a
#    darkhttpd built the way devel/Makefile builds it for the python suites. test.sh only runs these.
for t in test_make_safe_uri test_password_equal test_normalize_path test_parse_field; do
  $CC -O2 -g -DDEBUG $COVERAGE_FLAGS -o "$B/$t" "devel/$t.c" $COVERAGE_FLAGS
done
$CC -O2 -g -DDEBUG -DAPBUF_INIT=1 $COVERAGE_FLAGS -o "$B/darkhttpd" darkhttpd.c $COVERAGE_FLAGS

# 2) Fuzz harnesses. darkhttpd.c is #included into each harness TU, so the project code itself is
#    compiled with $SANITIZER_FLAGS + the fuzzing engine's coverage instrumentation.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$B/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"

# name:source:extra-flags
for spec in \
  "fuzz_make_safe_uri:devel/fuzz_make_safe_uri.c:" \
  "fuzz_parse_request:devel/fuzz_parse_request.c:" \
  "fuzz_socket:mayhem/darkhttpd/fuzz_socket.c:-pthread"; do
  IFS=: read -r name srcf extra <<<"$spec"
  # shellcheck disable=SC2086
  $CC -O1 $SANITIZER_FLAGS $DEBUG_FLAGS $extra $LIB_FUZZING_ENGINE "$srcf" "$B/lsan_off.o" -o "$OUT/$name"
  # shellcheck disable=SC2086
  $CC -O1 $SANITIZER_FLAGS $DEBUG_FLAGS $extra "$srcf" "$B/standalone_main.o" "$B/lsan_off.o" -o "$OUT/$name-standalone"
done
