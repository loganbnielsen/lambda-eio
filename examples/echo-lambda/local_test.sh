#!/usr/bin/env bash
# Proves the container-image deployment path works, using AWS's own
# documented local-testing recipe for container-image Lambda functions:
# run the image with the cached aws-lambda-rie binary (see
# ../../test/rie_smoke_test.sh, which downloads and caches it) mounted in as
# the entrypoint, wrapping our bootstrap exactly as real Lambda's own
# infrastructure would. No AWS account or credentials involved.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image_tag="lambda-eio-echo-local-test"
container_name="lambda-eio-echo-local-test"
port=9001

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

cleanup() { docker rm -f "$container_name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "Building $image_tag..."
docker build -t "$image_tag" -f "$repo_root/examples/echo-lambda/Dockerfile" "$repo_root"

cleanup
docker run -d --name "$container_name" \
  -v "$rie_bin:/aws-lambda-rie" \
  -p "$port:8080" \
  --entrypoint /aws-lambda-rie \
  "$image_tag" \
  /var/task/bootstrap >/dev/null

ready=false
for _ in $(seq 1 30); do
  if curl -s -o /dev/null "http://localhost:$port/2015-03-31/functions/function/invocations"; then
    ready=true
    break
  fi
  sleep 0.5
done
if [ "$ready" != true ]; then
  echo "error: container never became ready; logs follow:" >&2
  docker logs "$container_name" >&2
  exit 1
fi

fail=0
check() {
  local desc="$1" payload="$2" expected="$3" got
  got="$(curl -s -X POST "http://localhost:$port/2015-03-31/functions/function/invocations" -d "$payload")"
  if [ "$got" = "$expected" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc — expected $expected, got $got"
    fail=1
  fi
}

check "first invocation echoes payload" '{"hello":"world"}' '{"echoed":{"hello":"world"}}'
check "second invocation on the same warm container" '{"second":"call"}' '{"echoed":{"second":"call"}}'

if [ "$fail" != 0 ]; then
  echo "--- container logs ---" >&2
  docker logs "$container_name" >&2
  exit 1
fi

echo "All container deployment checks passed."
