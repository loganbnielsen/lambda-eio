#!/usr/bin/env bash
# Protocol-conformance smoke test against the real AWS Lambda Runtime
# Interface Emulator (RIE) — not this repo's own mock server. Needs no AWS
# account/credentials: RIE is a local process that speaks the exact Runtime
# API a real Lambda execution environment does.
#
# Usage: test/rie_smoke_test.sh   (run from the repo root, after `dune build`)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
handler="$repo_root/_build/default/test/rie_echo_handler.exe"

if [ ! -x "$handler" ]; then
  echo "error: $handler not built — run 'dune build' first" >&2
  exit 1
fi

arch="$(uname -m)"
case "$arch" in
  x86_64) rie_asset="aws-lambda-rie-x86_64" ;;
  aarch64|arm64) rie_asset="aws-lambda-rie-arm64" ;;
  *) echo "error: unsupported architecture $arch" >&2; exit 1 ;;
esac

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/aws-lambda-rie"
rie_version="v1.36"
rie_bin="$cache_dir/aws-lambda-rie-$rie_version-$arch"

mkdir -p "$cache_dir"
if [ ! -x "$rie_bin" ]; then
  echo "Downloading aws-lambda-rie $rie_version ($arch)..."
  curl -sL -o "$rie_bin" \
    "https://github.com/aws/aws-lambda-runtime-interface-emulator/releases/download/$rie_version/$rie_asset"
  chmod +x "$rie_bin"
fi

rie_pid=""
cleanup() {
  if [ -n "$rie_pid" ]; then
    kill "$rie_pid" 2>/dev/null || true
    wait "$rie_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

log_file="$(mktemp)"
"$rie_bin" "$handler" > "$log_file" 2>&1 &
rie_pid=$!

ready=false
for _ in $(seq 1 30); do
  if curl -s -o /dev/null "http://localhost:8080/2015-03-31/functions/function/invocations"; then
    ready=true
    break
  fi
  sleep 0.5
done
if [ "$ready" != true ]; then
  echo "error: RIE never became ready; log follows:" >&2
  cat "$log_file" >&2
  exit 1
fi

fail=0

check() {
  local desc="$1" payload="$2" expected="$3"
  local got
  got="$(curl -s -X POST "http://localhost:8080/2015-03-31/functions/function/invocations" -d "$payload")"
  if [ "$got" = "$expected" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc — expected $expected, got $got"
    fail=1
  fi
}

check "first invocation echoes payload" '{"hello":"world"}' '{"echoed":{"hello":"world"}}'
check "second invocation on the same warm process" '{"second":"call"}' '{"echoed":{"second":"call"}}'

if [ "$fail" != 0 ]; then
  echo "--- RIE log ---" >&2
  cat "$log_file" >&2
  exit 1
fi

echo "All RIE smoke checks passed."
