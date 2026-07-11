# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). The base provides debian + clang/llvm + libFuzzer + the
# identities + the build-contract ENV. mongodb/mongo-go-driver is a pure-Go project, so the base
# (C/C++ only — NO Go toolchain) needs Go added here as a USER root step, then the OSS-Fuzz Go
# fuzzing tooling (go-118-fuzz-build) that turns the native Go fuzz harness into a
# libFuzzer-instrumented binary linked with $LIB_FUZZING_ENGINE.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mongo-go-driver-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# NOTE: the OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); the Go fuzz
# binary is built with ASan and links the libFuzzer engine. build.sh handles the Go specifics.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Pin the Go toolchain version AND its tarball sha256 (reproducible fetch).
# The mongo-driver module is `go 1.19`, but its test/dev code needs Go 1.25+.
ARG GO_VERSION=1.25.1
ARG GO_SHA256=7716a0d940a0f6ae8e1f3b3f4f36299dc53e31b16840dbd171254312c41ca12e

# ── Go toolchain @ a FIXED, lockable, $HOME-independent prefix ─────────────────────────────────
# SPEC §6.2 item 8 + §6.5: commit build and PATCH re-run run under different $HOMEs.
# Pinning GOROOT/GOPATH/GOMODCACHE/GOCACHE under /opt/toolchains ensures the module cache
# populated during the first (online) image build is found again when build.sh re-runs offline.
ENV GOROOT=/opt/toolchains/go \
    GOPATH=/opt/toolchains/go-path \
    GOMODCACHE=/opt/toolchains/go-path/pkg/mod \
    GOCACHE=/opt/toolchains/go-path/build-cache \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=mod \
    GOWORK=off \
    PATH=/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/bin:/usr/bin:/bin

# ── Install Go + the OSS-Fuzz Go fuzzing build tools (root step) ──────────────────────────────
# The base image is C/C++-only; replicate OSS-Fuzz base-builder-go's install_go.sh:
#   * official go tarball -> /opt/toolchains/go (PATH'd)  [from go.dev, NOT apt]
#   * go114-fuzz-build (symlinked as `go-fuzz`)  — builds the LEGACY `func Fuzz([]byte) int` harness
#   * go-118-fuzz-build                          — builds the native `func FuzzX(f *testing.F)` harness
#     (this is what mongo-go-driver's OSS-Fuzz target uses: bson.FuzzDecode, compile_native_go_fuzzer)
USER root
RUN install -d /opt/toolchains/go-path \
    && wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tgz \
    && echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c - \
    && tar -C /opt/toolchains -xzf /tmp/go.tgz && rm /tmp/go.tgz \
    && go version \
    && go install github.com/mdempsky/go114-fuzz-build@latest \
    && ln -sf "$(go env GOPATH)/bin/go114-fuzz-build" "$(go env GOPATH)/bin/go-fuzz" \
    && go install github.com/AdamKorcz/go-118-fuzz-build@latest \
    && ls -la "$(go env GOPATH)/bin" \
    && chmod -R a+rX /opt/toolchains/go \
    && chown -R 2000:2000 /opt/toolchains/go-path \
    && go clean -cache 2>/dev/null || true

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $GOMODCACHE (online, first build) and builds the libFuzzer target(s).
RUN bash mayhem/build.sh

# Run the BSON test suite at build time (a failing suite fails the image build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
