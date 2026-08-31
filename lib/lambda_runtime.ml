type invocation = {
  request_id : string;
  deadline_ms : int64;
  invoked_function_arn : string;
  trace_id : string option;
  payload : string;
}

type t = {
  net : [`Generic] Eio.Net.ty Eio.Std.r;
  base : string;
}

let create ~net ~base =
  { net = (net :> [`Generic] Eio.Net.ty Eio.Std.r); base }

let ( let* ) = Result.bind

type error =
  | Missing_runtime_api
  | Http_error of int * string
  | Malformed_response of string
  | Network_error of string

let error_to_string = function
  | Missing_runtime_api ->
    "AWS_LAMBDA_RUNTIME_API is not set — not running in a Lambda execution environment (or a local Runtime \
     Interface Emulator)"
  | Http_error (status, body) -> Printf.sprintf "runtime API returned HTTP %d: %s" status body
  | Malformed_response msg -> msg
  | Network_error msg -> msg

let runtime_api_base () =
  match Sys.getenv_opt "AWS_LAMBDA_RUNTIME_API" with
  | Some base -> Ok base
  | None -> Error Missing_runtime_api

let max_response_body_bytes = 64 * 1024
(* The Runtime API's own JSON acknowledgement bodies are tiny; this isn't the
   6MB Lambda payload limit, which applies to next_invocation's body, read
   separately below with its own, larger bound. *)

let max_invocation_payload_bytes = 6 * 1024 * 1024

let read_body ~max_size body = Eio.Buf_read.(parse_exn take_all) body ~max_size

let truncate s =
  let max_len = 500 in
  if String.length s <= max_len then s
  else String.sub s 0 max_len ^ "... (truncated)"

let client net = Cohttp_eio.Client.make ~https:None net

(* Kept pure and separate from the network call so it's directly
   unit-testable with a synthetic Http.Header.t. *)
let invocation_of_headers ~headers ~payload =
  match Http.Header.get headers "Lambda-Runtime-Aws-Request-Id" with
  | None -> Error (Malformed_response "invocation/next response missing Lambda-Runtime-Aws-Request-Id header")
  | Some request_id ->
    let* deadline_ms =
      match Http.Header.get headers "Lambda-Runtime-Deadline-Ms" with
      | Some s -> (
        match Int64.of_string_opt s with
        | Some deadline -> Ok deadline
        | None -> Error (Malformed_response "invocation/next response has malformed Lambda-Runtime-Deadline-Ms header"))
      | None -> Error (Malformed_response "invocation/next response missing Lambda-Runtime-Deadline-Ms header")
    in
    let invoked_function_arn = Option.value (Http.Header.get headers "Lambda-Runtime-Invoked-Function-Arn") ~default:"" in
    let trace_id = Http.Header.get headers "Lambda-Runtime-Trace-Id" in
    Ok { request_id; deadline_ms; invoked_function_arn; trace_id; payload }

(* Cancellation and runtime-fatal exceptions are always re-raised, never
   converted to Error — they have to unwind correctly, not get reported as
   ordinary Lambda Runtime API failures. *)
let next_invocation t =
  let uri = Uri.of_string (Printf.sprintf "http://%s/2018-06-01/runtime/invocation/next" t.base) in
  match
    Eio.Switch.run (fun sw ->
      let resp, body = Cohttp_eio.Client.get (client t.net) ~sw uri in
      let status = Http.Response.status resp |> Http.Status.to_int in
      let payload = read_body ~max_size:max_invocation_payload_bytes body in
      (status, resp, payload))
  with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception ((Out_of_memory | Stack_overflow | Sys.Break) as exn) -> raise exn
  | exception exn -> Error (Network_error ("next_invocation: " ^ Printexc.to_string exn))
  | status, _, payload when status < 200 || status >= 300 ->
    Error (Http_error (status, truncate payload))
  | _, resp, payload -> invocation_of_headers ~headers:(Http.Response.headers resp) ~payload

let post ~net ~sw ~uri ~headers ~body =
  match
    let resp, resp_body = Cohttp_eio.Client.post (client net) ~sw ~headers:(Http.Header.of_list headers) ~body:(Cohttp_eio.Body.of_string body) uri in
    let status = Http.Response.status resp |> Http.Status.to_int in
    let resp_body = read_body ~max_size:max_response_body_bytes resp_body in
    (status, resp_body)
  with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception ((Out_of_memory | Stack_overflow | Sys.Break) as exn) -> raise exn
  | exception exn -> Error (Network_error (Printexc.to_string exn))
  | status, resp_body ->
    if status >= 200 && status < 300 then Ok ()
    else Error (Http_error (status, truncate resp_body))

let respond t ~request_id ~body =
  let request_id = Uri.pct_encode ~component:`Path request_id in
  let uri = Uri.of_string (Printf.sprintf "http://%s/2018-06-01/runtime/invocation/%s/response" t.base request_id) in
  Eio.Switch.run (fun sw ->
    post ~net:t.net ~sw ~uri ~headers:[] ~body)

let error_body ~error_message ~error_type =
  Yojson.Safe.to_string (`Assoc [ ("errorMessage", `String error_message); ("errorType", `String error_type) ])

let respond_error t ~request_id ~error_message ~error_type =
  let request_id = Uri.pct_encode ~component:`Path request_id in
  let uri = Uri.of_string (Printf.sprintf "http://%s/2018-06-01/runtime/invocation/%s/error" t.base request_id) in
  Eio.Switch.run (fun sw ->
    post ~net:t.net ~sw ~uri ~headers:[ ("Lambda-Runtime-Function-Error-Type", "Unhandled") ]
      ~body:(error_body ~error_message ~error_type))

let init_error t ~error_message ~error_type =
  let uri = Uri.of_string (Printf.sprintf "http://%s/2018-06-01/runtime/init/error" t.base) in
  Eio.Switch.run (fun sw ->
    post ~net:t.net ~sw ~uri ~headers:[ ("Lambda-Runtime-Function-Error-Type", "Unhandled") ]
      ~body:(error_body ~error_message ~error_type))

(* Cancellation must interrupt the wait for a new invocation, never abandon
   the ack for one already received — once next_invocation returns Ok, Lambda
   expects a response/error POST no matter what. next_invocation stays
   outside the protected region in run_loop below; see there for what is
   and isn't protected within it. *)
let default_on_error msg = Printf.eprintf "lambda-eio: %s\n%!" msg

(* A persistently failing next_invocation (the Runtime API sidecar itself
   unreachable, not a one-off failure) is effectively unrecoverable from
   inside the function — retrying immediately in a tight loop would just
   busy-spin for however long the outage lasts. A short fixed pause is
   enough to stop that; not real backoff tuning, since there's no rate
   limit to respect here and nothing this loop can do to fix the
   underlying problem faster by waiting longer. *)
let next_invocation_retry_delay = 0.5

let run_loop t ~clock ?(on_error = default_on_error) ~handler () =
  let report_invocation_error invocation msg =
    Eio.Cancel.protect (fun () ->
      respond_error t ~request_id:invocation.request_id ~error_message:msg
        ~error_type:"HandlerError"
      |> Result.map_error (fun post_err -> "respond_error failed: " ^ error_to_string post_err))
  in
  let rec loop () =
    (match next_invocation t with
     | Error err ->
       (* Transient failures must not kill the loop — a warm execution
          environment is expected to keep calling next_invocation for its
          entire lifetime. *)
       on_error ("next_invocation failed: " ^ error_to_string err);
       Eio.Time.sleep clock next_invocation_retry_delay
     | Ok invocation ->
       (* Only the handler-and-ack sequence itself is protected from
          cancellation — once next_invocation returns Ok, Lambda expects a
          response/error POST no matter what. on_error is deliberately
          called after protect returns, not inside it: on_error is
          caller-supplied and may do its own I/O (push to a logging
          backend), and a caller-supplied hook blocking inside protect
          would make it uninterruptible by cancellation too, defeating
          graceful shutdown for reasons that have nothing to do with the
          ack guarantee protect exists for. *)
       let result =
         try handler invocation with
         | Eio.Cancel.Cancelled _ as exn ->
           (match report_invocation_error invocation (Printexc.to_string exn) with
            | Ok () -> ()
            | Error msg -> on_error msg);
           raise exn
         | (Out_of_memory | Stack_overflow | Sys.Break) as exn -> raise exn
         | exn -> Error (Printexc.to_string exn)
       in
       let post_result =
         match result with
         | Ok body ->
           Eio.Cancel.protect (fun () ->
             respond t ~request_id:invocation.request_id ~body
             |> Result.map_error (fun err -> "respond failed: " ^ error_to_string err))
         | Error msg -> report_invocation_error invocation msg
       in
       (match post_result with
        | Ok () -> ()
        | Error msg -> on_error msg));
    loop ()
  in
  loop ()
