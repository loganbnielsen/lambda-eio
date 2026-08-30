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

val create : net:_ Eio.Net.t -> sw:Eio.Switch.t -> base:string -> t

val runtime_api_base : unit -> (string, string) result
(** Reads [AWS_LAMBDA_RUNTIME_API]. [Error] if unset — calling this outside a
    real Lambda execution environment (or a local Runtime Interface
    Emulator) is a configuration error, not something to default around. *)

val next_invocation : t -> (invocation, string) result
(** [GET {base}/2018-06-01/runtime/invocation/next]. A real long-poll — this
    can block for minutes waiting for the next event. *)

val respond : t -> request_id:string -> body:string -> (unit, string) result
(** [POST {base}/2018-06-01/runtime/invocation/{request_id}/response].
    [request_id] is encoded as one URI path segment before sending. *)

val respond_error :
  t -> request_id:string -> error_message:string -> error_type:string -> (unit, string) result
(** [POST {base}/2018-06-01/runtime/invocation/{request_id}/error].
    [request_id] is encoded as one URI path segment before sending. *)

val init_error :
  t -> error_message:string -> error_type:string -> (unit, string) result
(** [POST {base}/2018-06-01/runtime/init/error] — for a failure before the
    loop below ever starts, distinct from a per-invocation error. *)

val run_loop
  :  t
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
    stderr). These are exactly the operational signals ("the Runtime API
    sidecar is flaky," "we couldn't even report a handler error back to
    Lambda") an operator needs during an incident; pass [on_error] to route
    them into your own logging/observability backend instead of bare
    stderr. [on_error] is always called outside the protected
    handler-and-ack sequence, so it's safe for it to block or do its own
    I/O — it can be interrupted by cancellation like any other code, unlike
    [handler] and the [respond]/[respond_error] POST themselves, which are
    protected so an accepted invocation always gets an ack even under
    external cancellation. *)
