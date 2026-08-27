# echo-lambda — a deployable proof

The smallest possible real deployment of `lambda-eio`: `test/rie_echo_handler.exe`
(also used by `test/rie_smoke_test.sh`) packaged as a container image and run as
an AWS Lambda function.

## Why container image, not zip

A zip-based custom runtime (`provided.al2`/`provided.al2023`) must ship a
`bootstrap` binary linked against a glibc no *newer* than the one on Amazon
Linux's base image — glibc is forward-compatible only. A binary built on a
typical modern dev machine (glibc 2.38+) will fail to even start on Amazon
Linux 2's glibc 2.26 with `GLIBC_2.xx not found`.

Container images sidestep this entirely: AWS Lambda's container support only
requires the image implement the Runtime API loop itself — which
`Lambda_runtime.run_loop` already does (proven against a local mock server in
`test/test_lambda_runtime.ml`, and against AWS's own Runtime Interface
Emulator in `test/rie_smoke_test.sh`). No AWS base image, no runtime-interface-client
library, no glibc-matching concern: this `Dockerfile` builds and runs the
binary in the *same* `ubuntu:24.04` image tag for both stages, so whatever
glibc the binary links against is guaranteed present at runtime.

## Local verification (no AWS account needed)

```bash
examples/echo-lambda/local_test.sh
```

Builds the image, then runs it exactly the way AWS itself documents testing
a container-image Lambda function locally: the `aws-lambda-rie` binary
(cached by `test/rie_smoke_test.sh`, downloaded here too if missing) is
mounted in and set as the container's entrypoint, wrapping `/var/task/bootstrap`
— matching what Lambda's own infrastructure does in production, just without
the ECR/IAM/networking plumbing around it. Posts two invocations at the
container's local invoke endpoint and checks the responses, proving warm-container
reuse works across invocations, not just a single cold start. Runs in CI on
every push (GitHub's `ubuntu-latest` runners have Docker preinstalled).

## Real deployment (needs an AWS account)

```bash
PROFILE=my-admin-profile ./test-e2e.sh
```

Builds the image, pushes it to a fresh ECR repo, creates a scoped execution
role, deploys the function, invokes it twice for real (same echo checks as
`local_test.sh`, against a real cold start + a warm reuse), and tears
everything down afterward — teardown runs even if a check fails. `setup.sh`
and `teardown.sh` also exist standalone if you want to leave the deployment
up between runs (e.g. to poke at it manually) instead of using `test-e2e.sh`'s
build-test-teardown wrapper.

Execution role trust policy (lets the Lambda service assume the role,
created by `setup.sh`):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```

Execution role permissions — the AWS-managed `AWSLambdaBasicExecutionRole`
policy is sufficient (CloudWatch Logs only; this function touches nothing
else). No ECR permissions are needed on the execution role itself — Lambda's
own service role pulls the image at deploy/cold-start time, not the
function's execution role.
