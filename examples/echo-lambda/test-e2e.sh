#!/usr/bin/env bash
# Runs the live Lambda smoke test end to end: build+push+deploy -> invoke a
# real deployed function -> teardown. Teardown always runs, even if the test
# fails. Same PASS/FAIL checks as local_test.sh's RIE run, but against a real
# AWS Lambda invocation instead of a local emulator.
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${PROFILE:-sts-smoke-test-provisioner}"
REGION="${REGION:-us-east-1}"
FUNCTION_NAME="${FUNCTION_NAME:-lambda-eio-echo}"

export PROFILE REGION FUNCTION_NAME

cleanup() {
  echo "==> Tearing down..."
  ./teardown.sh
}
trap cleanup EXIT

echo "==> Provisioning (build, push, deploy)..."
./setup.sh

fail=0
check() {
  local desc="$1" payload="$2" expected="$3" out got
  out="$(mktemp)"
  aws lambda invoke --function-name "$FUNCTION_NAME" \
    --cli-binary-format raw-in-base64-out \
    --payload "$payload" \
    --region "$REGION" --profile "$PROFILE" \
    "$out" > /dev/null
  got="$(cat "$out")"
  rm -f "$out"
  if [ "$got" = "$expected" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc — expected $expected, got $got"
    fail=1
  fi
}

echo "==> Invoking real Lambda function ${FUNCTION_NAME}..."
check "first invocation echoes payload" '{"hello":"world"}' '{"echoed":{"hello":"world"}}'
check "second invocation on the same warm container" '{"second":"call"}' '{"echoed":{"second":"call"}}'

if [ "$fail" != 0 ]; then
  echo "--- recent logs ---" >&2
  aws logs tail "/aws/lambda/${FUNCTION_NAME}" --since 5m --region "$REGION" --profile "$PROFILE" || true
  exit 1
fi

echo "All live Lambda checks passed."
