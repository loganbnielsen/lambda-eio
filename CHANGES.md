# Changes

## Unreleased

- `Lambda_runtime` now has an explicit handle (`create`, then operations on
  `t`) instead of repeating `~net ~sw ~base` on every Runtime API call.
- `next_invocation` now rejects missing or malformed
  `Lambda-Runtime-Deadline-Ms` headers instead of silently treating them as
  `0L`.
- Hid `invocation_of_headers`; it is the private parser behind
  `next_invocation`, not part of the caller contract.
- `respond` and `respond_error` now percent-encode `request_id` as one URI
  path segment before posting to the Runtime API.

## 0.1.0

- Initial standalone opam package, extracted from Sun: `Lambda_runtime` (the
  Lambda Runtime API long-poll loop — `next_invocation`/`respond`/
  `respond_error`/`init_error`/`run_loop`, built on `Cohttp_eio.Client`
  directly, no `aws-eio`/SigV4 dependency since the Runtime API is a local
  unsigned HTTP sidecar) and `Lambda_event` (lenient S3/SQS/DynamoDB-Streams
  event envelope parsing).
- Protocol correctness proven at three levels: a local mock Runtime API
  server, AWS's own Runtime Interface Emulator (`test/rie_smoke_test.sh`,
  runs in CI credential-free), and a real deployed AWS Lambda function
  (`examples/echo-lambda/test-e2e.sh` — builds a container image, pushes to
  ECR, deploys, invokes twice for real, tears down; teardown independently
  confirmed, not just a trusted exit code).
- Container images (not zip-based custom runtimes) chosen deliberately: a
  `bootstrap` binary built on a typical dev machine's glibc fails to start on
  Amazon Linux's older, forward-compatible-only glibc. Both Dockerfile stages
  share the same `ubuntu:24.04` tag so the binary always runs against the
  glibc it was built against.
- `run_loop` wraps the handler-and-ack sequence in `Eio.Cancel.protect` so a
  stop signal can only take effect while waiting on `next_invocation`, never
  mid-acknowledgement of an already-completed invocation.
