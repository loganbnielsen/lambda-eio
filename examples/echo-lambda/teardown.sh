#!/usr/bin/env bash
# Tears down everything setup.sh creates. Best-effort (|| true throughout) —
# safe to re-run if a previous teardown partially failed.
set -uo pipefail
cd "$(dirname "$0")/../.."

PROFILE="${PROFILE:-sts-smoke-test-provisioner}"
REGION="${REGION:-us-east-1}"
REPO_NAME="${REPO_NAME:-lambda-eio-echo}"
FUNCTION_NAME="${FUNCTION_NAME:-lambda-eio-echo}"
ROLE_NAME="${ROLE_NAME:-lambda-eio-echo-execution}"

echo "==> Deleting function ${FUNCTION_NAME}..."
aws lambda delete-function --function-name "$FUNCTION_NAME" --region "$REGION" --profile "$PROFILE" || true

echo "==> Detaching policy and deleting role ${ROLE_NAME}..."
aws iam detach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
  --profile "$PROFILE" || true
aws iam delete-role --role-name "$ROLE_NAME" --profile "$PROFILE" || true

echo "==> Deleting ECR repository ${REPO_NAME}..."
aws ecr delete-repository --repository-name "$REPO_NAME" --region "$REGION" --profile "$PROFILE" --force || true

echo "==> Teardown complete."
