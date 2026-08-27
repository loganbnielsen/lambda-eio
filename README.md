# lambda-eio

An Eio-native client for the [AWS Lambda Runtime API](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html)
long-poll loop, plus event-envelope parsing for common trigger shapes (S3, SQS,
DynamoDB Streams). Not an AWS SDK, and no dependency on `aws-eio`/SigV4 — the
Runtime API is a local, unsigned HTTP sidecar (`AWS_LAMBDA_RUNTIME_API` points at
a loopback address the Lambda execution environment itself provides), not a
signed AWS API call, so this talks to it with `Cohttp_eio.Client` directly.

Originally developed inside the [Sun](https://github.com/loganbnielsen/sun)
platform as the runtime layer behind `sun-fn`'s `Lambda` trigger, and extracted
here to be usable by any Eio-based OCaml Lambda function, not just Sun's.

**Caution:** protocol correctness is tested end to end against both a local mock
Runtime API server (plain HTTP, so no TLS/SNI blocker to work around) and, since
0.1.0, against AWS's own [Runtime Interface Emulator](https://github.com/aws/aws-lambda-runtime-interface-emulator)
— see `test/rie_smoke_test.sh`. It has not yet been run inside a real Lambda
execution environment on AWS itself. Treat 0.1.0 accordingly until someone
reports a real deployed invocation working.

## Build

```bash
eval $(opam env)
dune build
```

## Test

```bash
dune runtest
```

No external infrastructure required — the wire-protocol tests spin up a local
mock Runtime API server (no network). A separate, credential-free protocol
conformance check against the real AWS Runtime Interface Emulator (RIE) is
run with:

```bash
dune build
test/rie_smoke_test.sh
```

This downloads (and caches under `~/.cache/aws-lambda-rie`) the `aws-lambda-rie`
binary, runs it with `test/rie_echo_handler.exe` as the bootstrap — a tiny
executable that loops via `Lambda_runtime.run_loop`, echoing each invocation's
payload back — and posts two invocations at RIE's local invoke endpoint,
checking the responses. No AWS account or credentials are involved: RIE is a
self-contained local emulator of the real Runtime API, not a connection to
AWS. This runs in CI on every push.

## Deploying

`examples/echo-lambda/` is a real, working deployment of this package as a
container-image AWS Lambda function — a `Dockerfile`, a local verification
script (also credential-free, runs in CI), and the exact `aws ecr`/`aws lambda`
commands for a real deployment. See its README for why container images
(not zip-based custom runtimes) are the right packaging here. `terraform/`
provisions the ECR repo and the (assume-role-only, no long-lived keys) IAM
roles that deployment needs — see its header comment for usage.

## Overview

Every Lambda execution environment sets `AWS_LAMBDA_RUNTIME_API` to a `host:port`
implementing the Runtime API:

1. `GET {base}/invocation/next` — blocks (a real long-poll: this can take
   minutes) until the next event arrives. Response headers carry
   `Lambda-Runtime-Aws-Request-Id`, `Lambda-Runtime-Deadline-Ms`,
   `Lambda-Runtime-Invoked-Function-Arn`; body is the raw JSON event payload.
2. Handler runs.
3. `POST {base}/invocation/{request_id}/response` on success, or
   `POST {base}/invocation/{request_id}/error` on failure — the process then
   loops back to step 1. A Lambda execution environment is reused across many
   invocations while "warm"; this loop runs for the process's entire lifetime,
   not once.
4. `POST {base}/init/error` instead, if initialization itself fails before the
   loop ever starts.

## Public API

### `Lambda_runtime`

```ocaml
type invocation = {
  request_id : string;
  deadline_ms : int64;
  invoked_function_arn : string;
  trace_id : string option;
  payload : string;  (** raw JSON event body — {!Lambda_event} parses common shapes *)
}

val runtime_api_base : unit -> (string, string) result
(** Reads [AWS_LAMBDA_RUNTIME_API]; [Error] if unset — calling this outside a real
    Lambda execution environment (or a local Runtime Interface Emulator) is a
    configuration error, not something to default around. *)

val next_invocation : net:_ Eio.Net.t -> sw:Eio.Switch.t -> base:string -> (invocation, string) result
val respond : net:_ Eio.Net.t -> sw:Eio.Switch.t -> base:string -> request_id:string -> body:string -> (unit, string) result
val respond_error :
  net:_ Eio.Net.t -> sw:Eio.Switch.t -> base:string -> request_id:string ->
  error_message:string -> error_type:string -> (unit, string) result
val init_error :
  net:_ Eio.Net.t -> sw:Eio.Switch.t -> base:string ->
  error_message:string -> error_type:string -> (unit, string) result

val run_loop :
  net:_ Eio.Net.t -> sw:Eio.Switch.t -> base:string ->
  handler:(invocation -> (string, string) result) -> unit
(** Loops forever: [next_invocation], run [handler], [respond]/[respond_error].
    A handler exception is caught and reported via [respond_error] rather than
    crashing the loop — one bad invocation must not kill the whole warm
    execution environment for every future invocation. Cancellation only takes
    effect while waiting on [next_invocation]; once an invocation is received,
    the handler-and-ack sequence always runs to completion. *)
```

### `Lambda_event`

Real AWS event envelope shapes, parsed leniently (extra fields ignored):

```ocaml
type s3_record = { bucket : string; key : string; event_name : string }
val s3_records_of_json : Yojson.Safe.t -> (s3_record list, string) result

type sqs_record = { message_id : string; body : string }
val sqs_records_of_json : Yojson.Safe.t -> (sqs_record list, string) result

type dynamodb_stream_record = {
  event_name : string;
  keys : Yojson.Safe.t;
  new_image : Yojson.Safe.t option;
  old_image : Yojson.Safe.t option;
}
val dynamodb_stream_records_of_json : Yojson.Safe.t -> (dynamodb_stream_record list, string) result
```

## Out of Scope (v1)

- A general event-processing function shape — the payload is opaque to
  `run_loop`'s handler contract; callers who want it parsed use `Lambda_event`
  themselves.
- Lambda fronting a request/response service (API Gateway integration) — a
  different integration point.
- Streaming responses, the Lambda Extensions API, provisioned-concurrency init
  hooks.
- Any event shape beyond S3/SQS/DynamoDB Streams (Kinesis, EventBridge, Cognito
  triggers, etc.) — add as needed, not speculatively.
