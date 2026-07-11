#!/usr/bin/env bash
#
# mongo-go-driver/mayhem/test.sh — RUN the MongoDB Go Driver's OWN BSON test suite
# (`go test ./bson/...`) and emit a CTRF summary. exit 0 iff no test failed.
#
# SCOPE: only the bson/ package tree. The BSON marshaler/unmarshaler (the fuzzed surface) has a
# large self-contained, OFFLINE test suite — Marshal/Unmarshal round-trips, the BSON corpus spec
# tests, ext-JSON, decimal128, primitive types, decoders/encoders. We deliberately AVOID the rest
# of the module (mongo/, x/mongo/... integration + e2e packages) because those need a live mongod
# / network and would fail offline. This is a real known-answer / round-trip oracle, NOT a stub:
# it asserts decode/encode BEHAVIOUR (require.Equal on golden values), so a no-op patch fails it.
#
# This runs in the build image AFTER mayhem/build.sh, which (replicating OSS-Fuzz) renames
# bson/fuzz_test.go -> bson/fuzz.go and bson/bson_corpus_spec_test.go -> bson/bson_corpus_spec.go.
# Those two files therefore no longer run as tests here; every OTHER bson test still runs and
# asserts. (When test.sh is run on a pristine tree before build.sh, they run as tests too.)
#
# Anti-reward-hacking behavioral probe (§6.3): after running `go test` (which is statically
# linked and thus immune to the LD_PRELOAD sabotage mechanism), this script also executes
# /mayhem/fuzz_decode (dynamically linked, ASan+libFuzzer) against a known corpus entry and
# asserts libFuzzer's "Executed" marker. Under the sabotage LD_PRELOAD, fuzz_decode exits
# silently (it is not under /usr/bin etc.) → the grep fails → FAILED increments → the oracle
# correctly detects the program is neutered (not reward-hackable).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/go/bin:/root/go/bin:$PATH"
# GOWORK=off: the repo ships a go.work workspace, but build.sh ran `go mod tidy` on the root module
# only; test just the bson/ package tree against that single-module view (avoids workspace -mod conflicts).
export GOWORK="${GOWORK:-off}"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOPATH="${GOPATH:-/opt/toolchains/go-path}"
export GOCACHE="${GOCACHE:-/opt/toolchains/go-path/build-cache}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE 2>/dev/null || echo /opt/toolchains/go-path/pkg/mod)/cache/download,off}"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test" 0 1 0; exit 2
fi

# A few bson spec tests read fixtures from the `testdata/specifications` GIT SUBMODULE (the
# MongoDB Driver Specifications repo). The commit image bakes the driver's own source + history
# but NOT that separate submodule (it is fetched out-of-band with `task init-submodule`), so those
# fixture-driven tests cannot run offline. We SKIP exactly the test that hard-errors on the missing
# submodule dir (TestBsonBinaryVectorSpec); every other bson test runs and asserts. This keeps the
# oracle honest and offline-scoped to the in-tree BSON marshaler/unmarshaler unit + round-trip suite.
SKIP_RE='TestBsonBinaryVectorSpec'

echo "=== running: go test -json -skip '$SKIP_RE' ./bson/... ==="
JSON="$SRC/mayhem-build/gotest.json"
mkdir -p "$SRC/mayhem-build"
go test -json -skip "$SKIP_RE" ./bson/... > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?

# Show package-level summary + any build/test errors for humans.
go test -skip "$SKIP_RE" ./bson/... 2>&1 | tail -40 || true
[ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -20 "$SRC/mayhem-build/gotest.err"; }

# Count test-level events (lines that carry a non-empty "Test" field; subtests included).
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

# Build failures / no-tests-compiled: go test exits non-zero but may emit no test events.
if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "no test events parsed; using go exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "go-test" 1 0 0; exit 0; }
  emit_ctrf "go-test" 0 1 0; exit 1
fi

# Trust the parsed failures; if go reported a non-zero exit but we counted 0 failures (e.g. a
# package build error), force a failure so the oracle is honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

# ── Behavioral probe via the dynamically-linked fuzz_decode binary (anti-reward-hacking, §6.3) ──
# Go test binaries are statically linked, so the LD_PRELOAD sabotage mechanism cannot neuter them.
# /mayhem/fuzz_decode IS dynamically linked (built with clang+ASan). Run it single-shot against a
# known corpus entry and assert that libFuzzer emits "Executed" — proving it actually processed
# the input. The sabotage LD_PRELOAD neuters fuzz_decode (not in /usr/bin etc.), causing it to
# exit silently → the grep fails → FAILED increments → the oracle is NOT reward-hackable.
PROBE_INPUT="$SRC/mayhem/fuzz_decode/testsuite/int32"
if [ -x /mayhem/fuzz_decode ] && [ -f "$PROBE_INPUT" ]; then
  echo "=== behavioral probe: fuzz_decode single-shot on known corpus ==="
  PROBE_OUT=$(/mayhem/fuzz_decode "$PROBE_INPUT" 2>&1 || true)
  if echo "$PROBE_OUT" | grep -q "Executed"; then
    echo "PROBE PASS: fuzz_decode executed the corpus input (parser active)"
    PASSED=$(( PASSED + 1 ))
  else
    echo "PROBE FAIL: fuzz_decode produced no 'Executed' output (parser inactive or sabotaged)"
    echo "Output was: $PROBE_OUT"
    FAILED=$(( FAILED + 1 ))
  fi
fi

emit_ctrf "go-test" "$PASSED" "$FAILED" "$SKIPPED"
