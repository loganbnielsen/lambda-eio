(** The Lambda Runtime API long-poll loop. No dependency on [aws-eio] — the
    Runtime API is a local, unsigned HTTP sidecar
    ([AWS_LAMBDA_RUNTIME_API] points at a loopback address the Lambda
    execution environment provides), not a signed AWS API call. Uses
    [Cohttp_eio.Client] directly, matching [obs-loki-eio]/
    [obs-prometheus-eio]'s own precedent for plain HTTP where there's no
    SigV4 wire-byte-encoding concern. *)

type invocation = {
  request_id : string;
  deadline_ms : int64;
  invoked_function_arn : string;
  trace_id : string option;
  payload : string;  (** raw JSON event body — {!Lambda_event} parses common shapes *)
}

type t

val create : net:_ Eio.Net.t -> base:string -> t

(** Runtime API transport/contract failure — distinct from a handler's own
    application error, which stays a plain [string] (see [run_loop]'s
    [handler] below): it's free-form text Lambda forwards verbatim as
    [errorMessage], not something this package's callers branch on. *)
type error =
  | Missing_runtime_api
      (** [AWS_LAMBDA_RUNTIME_API] is unset — not running in a real Lambda
          execution environment (or a local Runtime Interface Emulator). *)
  | Http_error of int * string
      (** The Runtime API responded with a non-2xx status; carries the
          status and a truncated response body. *)
  | Malformed_response of string
      (** [next_invocation]'s response was missing or had a malformed
          required header. *)
  | Network_error of string
      (** Connection failure, or any other transport-level exception. *)

val error_to_string : error -> string

val runtime_api_base : unit -> (string, error) result
(** Reads [AWS_LAMBDA_RUNTIME_API]. [Error Missing_runtime_api] if unset —
    calling this outside a real Lambda execution environment (or a local
    Runtime Interface Emulator) is a configuration error, not something to
    default around. *)

val next_invocation : t -> (invocation, error) result
(** [GET {base}/2018-06-01/runtime/invocation/next]. A real long-poll — this
    can block for minutes waiting for the next event. *)

val respond : t -> request_id:string -> body:string -> (unit, error) result
(** [POST {base}/2018-06-01/runtime/invocation/{request_id}/response].
    [request_id] is encoded as one URI path segment before sending. *)

val respond_error :
  t -> request_id:string -> error_message:string -> error_type:string -> (unit, error) result
(** [POST {base}/2018-06-01/runtime/invocation/{request_id}/error].
    [request_id] is encoded as one URI path segment before sending. *)

val init_error :
  t -> error_message:string -> error_type:string -> (unit, error) result
(** [POST {base}/2018-06-01/runtime/init/error] — for a failure before the
    loop below ever starts, distinct from a per-invocation error. *)

val run_loop
  :  t
  -> clock:_ Eio.Time.clock
  -> ?on_error:(string -> unit)
  -> handler:(invocation -> (string, string) result)
  -> unit
  -> unit
(** Loops forever: [next_invocation], run [handler], [respond]/
    [respond_error]. A handler exception is caught and reported via
    [respond_error] rather than propagating — one bad invocation must not
    crash the whole warm execution environment for every future invocation.
    A transient [next_invocation] failure, or a failed [respond]/
    [respond_error]/[next_invocation] POST, is not fatal and does not stop
    the loop — it's reported to [on_error] instead (default: one line to
    stderr), and (for a [next_invocation] failure specifically) followed by
    a short pause on [clock] before retrying, so a persistently unreachable
    Runtime API sidecar doesn't turn this into a busy-spin. These are
    exactly the operational signals ("the Runtime API sidecar is flaky,"
    "we couldn't even report a handler error back to Lambda") an operator
    needs during an incident; pass [on_error] to route them into your own
    logging/observability backend instead of bare stderr. [on_error] is
    always called outside the protected response sequence, so it's safe for
    it to block or do its own I/O — it can be interrupted by cancellation
    like any other code. [handler] is also cancellable. Only the
    [respond]/[respond_error] POST after a handler result is protected, so an
    accepted invocation gets an ack once the handler has produced an outcome;
    if the handler itself is cancelled, [run_loop] makes a protected
    best-effort [respond_error] and then re-raises cancellation. *)
