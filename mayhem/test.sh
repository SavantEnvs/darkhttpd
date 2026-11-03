#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

B="$SRC/mayhem/build"
DEVEL="$SRC/devel"
PORT=12346
ADDR=127.0.0.1
passed=0; failed=0
W="$(mktemp -d)"; trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT
cd "$W"
mkdir -p tmp.httpd.tests/'(' tmp.httpd.tests/forbidden tmp.httpd.tests/unreadable
chmod 0 tmp.httpd.tests/forbidden; chmod 0100 tmp.httpd.tests/unreadable

for f in test_make_safe_uri test_password_equal test_normalize_path test_parse_field darkhttpd; do
  [ -x "$B/$f" ] || { echo "missing $B/$f — mayhem/build.sh must build it" >&2; emit_ctrf darkhttpd-devel 0 1; exit 1; }
done

# Unit tests print PASS/FAIL per case. Require a clean exit, no FAIL, and a known answer line.
unit() { # name expected-line
  local out; out="$("$B/$1" 2>&1)"; local rc=$?
  if [ $rc -eq 0 ] && ! grep -Eq 'FAIL' <<<"$out" && grep -Fq -- "$2" <<<"$out" && [ "$(grep -c PASS <<<"$out")" -ge 4 ]; then
    passed=$((passed+1)); echo "ok   $1"
  else
    failed=$((failed+1)); echo "FAIL $1 (rc=$rc)"; echo "$out" | head -20
  fi
}
unit test_make_safe_uri '"/abc/../def/.././../" is unsafe'
unit test_normalize_path 'PASS'
unit test_password_equal 'PASS'
unit test_parse_field 'PASS: "right.com"'

# Python suites against a live server, as devel/run-tests does. Each suite is one unittest module.
suite() { # script server-args...
  local script="$1"; shift
  "$B/darkhttpd" tmp.httpd.tests --port $PORT --addr $ADDR "$@" >>server.out 2>>server.err &
  local pid=$!
  local n=0
  until (exec 3<>/dev/tcp/$ADDR/$PORT) 2>/dev/null; do
    n=$((n+1)); [ $n -gt 100 ] && break; sleep 0.05
  done
  local out rc
  out="$(python3 "$DEVEL/$script" 2>&1)"; rc=$?
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  local ran; ran="$(sed -n 's/^Ran \([0-9]*\) test.*/\1/p' <<<"$out")"
  if [ $rc -eq 0 ] && [ -n "$ran" ] && [ "$ran" -gt 0 ] && grep -q '^OK' <<<"$out"; then
    passed=$((passed+ran)); echo "ok   $script ($ran tests)"
  else
    failed=$((failed+1)); echo "FAIL $script (rc=$rc)"; echo "$out" | tail -25
  fi
}
rm -f test_logging.log test_xff.log
suite test.py --log test.out.log
suite test_log.py --log test_logging.log
suite test_log_xff.py --log test_xff.log --trusted-ip $ADDR
suite test_forward.py --forward example.com http://www.example.com --forward secure.example.com https://www.example.com/secure
suite test_forward_all.py --forward example.com http://www.example.com --forward-all http://catchall.example.com
suite test_server_id.py --no-server-id
{
  echo "test/type1 a1"; echo "test/this-gets-replaced  ap2"; echo "# this is a comment"
  printf "test/type3\\tapp3\r\n"; echo "test/type2  AP2"
} > tmp.httpd.tests/mimemap
suite test_mimemap.py --mimetypes tmp.httpd.tests/mimemap --default-mimetype test/default
suite test_no_listing.py --no-listing
suite test_timeout.py --timeout 1
suite test_auth.py --auth myuser:mypass
suite test_custom_headers.py --header 'X-Header-A: First Value' --header 'X-Header-B: Second Value' --forward example.com http://www.example.com
suite test_forward_https.py --forward-https

# Server stderr must stay empty, as in upstream's run-tests.
if [ -s server.err ]; then failed=$((failed+1)); echo "FAIL server stderr not empty"; cat server.err | head; else passed=$((passed+1)); echo "ok   server stderr empty"; fi

emit_ctrf darkhttpd-devel "$passed" "$failed"
