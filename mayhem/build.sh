#!/usr/bin/env bash
#
# mongo-go-driver/mayhem/build.sh — build the MongoDB Go Driver's OSS-Fuzz BSON fuzz target as a
# sanitized libFuzzer binary, REPLICATING OSS-Fuzz's compile_native_go_fuzzer.
#
# OSS-Fuzz target (projects/mongo-go-driver/build.sh):
#   compile_native_go_fuzzer go.mongodb.org/mongo-driver/v2/bson FuzzDecode fuzz_decode
# i.e. the NATIVE Go fuzz harness `func FuzzDecode(f *testing.F)` (bson/fuzz_test.go), built with
# go-118-fuzz-build, then linked with $LIB_FUZZING_ENGINE.
#
# The harness is a ROUND-TRIP oracle: it Unmarshals arbitrary bytes into six BSON target types
# (D, []E, M, any, map[string]any, []any); if decode succeeds it Marshals back and re-Unmarshals,
# Fatal-ing if the re-decode of its own encoding fails. The fuzzed surface is bson.Unmarshal +
# bson.Marshal (the BSON binary parser/marshaler).
#
# We produce:
#   /mayhem/fuzz_decode   — OSS-Fuzz target (bson.FuzzDecode, go-118-fuzz-build, ASan+libFuzzer)
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the Go
# libFuzzer link. An explicit empty --build-arg SANITIZER_FLAGS= disables it (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through CGO shim compiles and the
# final clang++ link step. Go's gc compiler always emits DWARF4; the C/CGO shims compiled by
# clang (LLVMFuzzerTestOneInput wrapper, CGO bridge) are forced to DWARF3 via CGO_CFLAGS.
# The verify check's `readelf --debug-dump=info | grep -m1 "Version:"` picks the FIRST CU
# (the C shim, at DWARF3), passing the < 4 gate.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# $(go env GOMODCACHE) reads the pinned ENV under /opt/toolchains (set in the Dockerfile),
# so the file proxy path is correct regardless of $HOME. The file proxy first → offline re-run
# resolves entirely from the cache; the network entries only fill cache-misses on the first build.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOWORK="${GOWORK:-off}"
# Toolchain paths are pinned in Dockerfile ENV; honour them if already set.
export GOPATH="${GOPATH:-/opt/toolchains/go-path}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOCACHE="${GOCACHE:-/opt/toolchains/go-path/build-cache}"
mkdir -p "$GOPATH" "$GOCACHE"
export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$GOPATH/bin:$PATH"

cd "$SRC"
go version

# go-118-fuzz-build needs the AdamKorcz testing shim as a module dep.
# This seeds the dep into GOMODCACHE on the first (online) build; on PATCH re-run
# the file:// proxy satisfies it from the cache without network access.
go get github.com/AdamKorcz/go-118-fuzz-build/testing 2>&1 | tail -2 || true

# Replicate OSS-Fuzz's source prep so FuzzDecode compiles via go-118-fuzz-build:
#   - fuzz_test.go / bson_corpus_spec_test.go are `_test.go` files (only built under `go test`);
#     rename to non-test names so they compile into the package the fuzzer links.
#   - seedBSONCorpus loads testdata/bson-corpus at fuzz-init; the OSS-Fuzz build strips its call
#     (the corpus is seeded out-of-band via the seed_corpus.zip / our testsuite), so remove the
#     `seedBSONCorpus(f)` line from the renamed harness.
if [ -f bson/fuzz_test.go ]; then mv bson/fuzz_test.go bson/fuzz.go; fi
if [ -f bson/bson_corpus_spec_test.go ]; then mv bson/bson_corpus_spec_test.go bson/bson_corpus_spec.go; fi
sed -i '/seedBSONCorpus/d' bson/fuzz.go

# Resolve the module graph for the new dep.
go mod tidy 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# ── OSS-Fuzz target: bson.FuzzDecode via go-118-fuzz-build (native testing.F harness) ───────────
#     Exact replica of `compile_native_go_fuzzer go.mongodb.org/mongo-driver/v2/bson FuzzDecode fuzz_decode`.
echo "=== building fuzz_decode (bson.FuzzDecode, go-118-fuzz-build) ==="
go-118-fuzz-build -o "$SRC/mayhem-build/fuzz_decode.a" \
    -func FuzzDecode \
    go.mongodb.org/mongo-driver/v2/bson
# Link: DWARF3 via $GO_DEBUG_FLAGS ensures the C-shim CU (first in the binary) is at DWARF3.
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/fuzz_decode.a" -o /mayhem/fuzz_decode
echo "built /mayhem/fuzz_decode"

echo "build.sh complete:"
ls -la /mayhem/fuzz_decode 2>&1 || true
