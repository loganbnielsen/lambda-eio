#!/usr/bin/env bash
# Builds the echo-lambda container image, pushes it to ECR, creates the
# execution role, and deploys it as a real Lambda function in YOUR OWN AWS
# account. Meant for anyone trying this package out locally, not tied to any
# specific account.
#
# Run with an AWS CLI profile that can push to ECR, manage IAM roles, and
# manage Lambda functions — override via env vars:
#   PROFILE=my-admin-profile ./setup.sh
#
# Not idempotent — re-running against an already-existing function/repo/role
# will fail; run teardown.sh first if you need to recreate it.
set -euo pipefail
cd "$(dirname "$0")/../.."  # repo root — Dockerfile's build context must be the repo root

PROFILE="${PROFILE:-sts-smoke-test-provisioner}"
REGION="${REGION:-us-east-1}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)}"
REPO_NAME="${REPO_NAME:-lambda-eio-echo}"
FUNCTION_NAME="${FUNCTION_NAME:-lambda-eio-echo}"
ROLE_NAME="${ROLE_NAME:-lambda-eio-echo-execution}"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE_URI="${REGISTRY}/${REPO_NAME}:latest"

echo "==> Building image..."
docker build --provenance=false -t "$REPO_NAME" -f examples/echo-lambda/Dockerfile .

echo "==> Creating ECR repository ${REPO_NAME}..."
aws ecr create-repository --repository-name "$REPO_NAME" --region "$REGION" --profile "$PROFILE" > /dev/null

echo "==> Pushing image to ${IMAGE_URI}..."
aws ecr get-login-password --region "$REGION" --profile "$PROFILE" \
  | docker login --username AWS --password-stdin "$REGISTRY"
docker tag "$REPO_NAME:latest" "$IMAGE_URI"
docker push "$IMAGE_URI"

echo "==> Allowing Lambda to read the image..."
repo_policy="$(mktemp)"
cat > "$repo_policy" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "LambdaECRImageRetrievalPolicy",
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"],
    "Condition": {
      "ArnLike": {
        "aws:sourceARN": "arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"
      }
    }
  }]
}
EOF
aws ecr set-repository-policy \
  --repository-name "$REPO_NAME" \
  --policy-text "file://${repo_policy}" \
  --region "$REGION" --profile "$PROFILE" > /dev/null
rm -f "$repo_policy"

echo "==> Creating execution role ${ROLE_NAME}..."
trust_policy="$(mktemp)"
cat > "$trust_policy" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF
aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document "file://${trust_policy}" \
  --profile "$PROFILE" > /dev/null
rm -f "$trust_policy"
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
  --profile "$PROFILE"

echo "==> Creating function ${FUNCTION_NAME}..."
role_arn="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
# ponytail: IAM role creation isn't immediately consistent across regions —
# create-function can fail for ~10-20s after attach-role-policy claiming the
# role can't be assumed yet. Retry instead of a fixed sleep guess.
attempt=0
delay=2
deadline=$((SECONDS + 300))
create_error="$(mktemp)"
until aws lambda create-function \
  --function-name "$FUNCTION_NAME" \
  --package-type Image \
  --code ImageUri="$IMAGE_URI" \
  --role "$role_arn" \
  --timeout 10 \
  --region "$REGION" --profile "$PROFILE" > /dev/null 2> "$create_error"
do
  attempt=$((attempt + 1))
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "error: create-function still failing after ${attempt} attempts / 5m (IAM role propagation?)" >&2
    cat "$create_error" >&2
    rm -f "$create_error"
    exit 1
  fi
  echo "    role not yet assumable, retrying in ${delay}s (attempt ${attempt})..."
  sleep "$delay"
  if [ "$delay" -lt 16 ]; then delay=$((delay * 2)); fi
done
rm -f "$create_error"

echo "==> Waiting for function to become Active..."
aws lambda wait function-active --function-name "$FUNCTION_NAME" --region "$REGION" --profile "$PROFILE"

echo "==> Setup complete. FUNCTION_NAME=${FUNCTION_NAME}"
