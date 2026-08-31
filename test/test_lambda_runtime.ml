let contains haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

(* Mock Runtime API server — plain HTTP, no TLS/SNI blocker here (unlike
   s3-eio/dynamo-eio's aws-eio-backed tests), so this exercises the real
   wire path end to end. *)
let with_mock_runtime_api env ~callback f =
  Eio.Switch.run @@ fun sw ->
  let server = Cohttp_eio.Server.make ~callback () in
  let socket = Eio.Net.listen ~backlog:5 ~sw env#net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with `Tcp (_, port) -> port | _ -> failwith "unexpected address family" in
  let stop, stop_r = Eio.Promise.create () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Cohttp_eio.Server.run ~stop ~on_error:(fun _ -> ()) socket server;
      `Stop_daemon);
  Fun.protect ~finally:(fun () -> Eio.Promise.resolve stop_r ()) (fun () ->
      f (Lambda_runtime.create ~net:env#net ~base:(Printf.sprintf "127.0.0.1:%d" port)))

let test_next_invocation_real_call () =
  Eio_main.run @@ fun env ->
  let callback _conn (req : Http.Request.t) _body =
    Alcotest.(check string) "path" "/2018-06-01/runtime/invocation/next" (Http.Request.resource req);
    let headers =
      Http.Header.of_list
        [ ("Lambda-Runtime-Aws-Request-Id", "req-abc"); ("Lambda-Runtime-Deadline-Ms", "123") ]
    in
    Cohttp_eio.Server.respond_string ~status:`OK ~headers ~body:{|{"hello":"world"}|} ()
  in
  with_mock_runtime_api env ~callback (fun runtime ->
      match Lambda_runtime.next_invocation runtime with
      | Error err -> Alcotest.fail (Lambda_runtime.error_to_string err)
      | Ok { request_id; payload; _ } ->
        Alcotest.(check string) "request_id" "req-abc" request_id;
        Alcotest.(check string) "payload" {|{"hello":"world"}|} payload)

let test_respond_posts_to_the_right_path_with_the_right_body () =
  Eio_main.run @@ fun env ->
  let callback _conn (req : Http.Request.t) body =
    Alcotest.(check string) "method" "POST" (Http.Request.meth req |> Http.Method.to_string);
    Alcotest.(check string) "path" "/2018-06-01/runtime/invocation/req%2F1%3Fx/response"
      (Http.Request.resource req);
    let received = Eio.Buf_read.(parse_exn take_all) body ~max_size:1024 in
    Alcotest.(check string) "body" {|{"result":"ok"}|} received;
    Cohttp_eio.Server.respond_string ~status:`Accepted ~body:"" ()
  in
  with_mock_runtime_api env ~callback (fun runtime ->
      match Lambda_runtime.respond runtime ~request_id:"req/1?x" ~body:{|{"result":"ok"}|} with
      | Ok () -> ()
      | Error err -> Alcotest.fail (Lambda_runtime.error_to_string err))

let test_respond_error_posts_error_shape_and_header () =
  Eio_main.run @@ fun env ->
  let callback _conn (req : Http.Request.t) body =
    Alcotest.(check string) "path" "/2018-06-01/runtime/invocation/req%2F2%25x/error"
      (Http.Request.resource req);
    Alcotest.(check (option string)) "Lambda-Runtime-Function-Error-Type header" (Some "Unhandled")
      (Http.Header.get (Http.Request.headers req) "Lambda-Runtime-Function-Error-Type");
    let received = Eio.Buf_read.(parse_exn take_all) body ~max_size:1024 in
    (match Yojson.Safe.from_string received with
     | `Assoc fields ->
       Alcotest.(check bool) "errorMessage present" true (List.mem_assoc "errorMessage" fields);
       Alcotest.(check bool) "errorType present" true (List.mem_assoc "errorType" fields)
     | _ -> Alcotest.fail "expected a JSON object");
    Cohttp_eio.Server.respond_string ~status:`Accepted ~body:"" ()
  in
  with_mock_runtime_api env ~callback (fun runtime ->
      match
        Lambda_runtime.respond_error runtime ~request_id:"req/2%x" ~error_message:"boom"
          ~error_type:"RuntimeError"
      with
      | Ok () -> ()
      | Error err -> Alcotest.fail (Lambda_runtime.error_to_string err))

let test_post_error_status_is_reported () =
  Eio_main.run @@ fun env ->
  let callback _conn _req _body = Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"" () in
  with_mock_runtime_api env ~callback (fun runtime ->
      Alcotest.(check bool) "a non-2xx response from the Runtime API itself is surfaced as an error" true
        (match Lambda_runtime.respond runtime ~request_id:"req-3" ~body:"{}" with
         | Error _ -> true
         | Ok () -> false))

(* Regression test: a non-2xx response body used to be read (to drain the
   connection) and then discarded, reporting only the status code — exactly
   the diagnostic detail an operator needs when the Runtime API sidecar
   itself is misbehaving. *)
let test_post_error_includes_response_body () =
  Eio_main.run @@ fun env ->
  let callback _conn _req _body =
    Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"stale Lambda-Runtime-Aws-Request-Id" ()
  in
  with_mock_runtime_api env ~callback (fun runtime ->
      match Lambda_runtime.respond runtime ~request_id:"req-3" ~body:"{}" with
      | Ok () -> Alcotest.fail "expected a non-2xx status to be an Error"
      | Error (Lambda_runtime.Http_error (400, body)) ->
        Alcotest.(check bool) "error body includes the response body" true
          (contains body "stale Lambda-Runtime-Aws-Request-Id")
      | Error err ->
        Alcotest.failf "expected Http_error 400, got: %s" (Lambda_runtime.error_to_string err))

(* A broken/misconfigured Runtime API endpoint could return a non-2xx status
   while still carrying a stale Lambda-Runtime-Aws-Request-Id header (e.g.
   from a caching proxy); next_invocation must reject on status, not just on
   header presence. *)
let test_next_invocation_rejects_non_2xx () =
  Eio_main.run @@ fun env ->
  let callback _conn (req : Http.Request.t) _body =
    let headers = Http.Header.of_list [ ("Lambda-Runtime-Aws-Request-Id", "stale-req") ] in
    ignore req;
    Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~headers ~body:"" ()
  in
  with_mock_runtime_api env ~callback (fun runtime ->
      Alcotest.(check bool) "a non-2xx invocation/next response is rejected" true
        (match Lambda_runtime.next_invocation runtime with
         | Error _ -> true
         | Ok _ -> false))

let test_next_invocation_rejects_missing_request_id () =
  Eio_main.run @@ fun env ->
  let callback _conn _req _body =
    Cohttp_eio.Server.respond_string ~status:`OK ~body:"{}" ()
  in
  with_mock_runtime_api env ~callback (fun runtime ->
      Alcotest.(check bool) "missing request id is rejected" true
        (match Lambda_runtime.next_invocation runtime with Error _ -> true | Ok _ -> false))

let test_next_invocation_rejects_malformed_deadline () =
  Eio_main.run @@ fun env ->
  let callback _conn _req _body =
    let headers =
      Http.Header.of_list
        [ ("Lambda-Runtime-Aws-Request-Id", "req-1");
          ("Lambda-Runtime-Deadline-Ms", "not-an-int64");
        ]
    in
    Cohttp_eio.Server.respond_string ~status:`OK ~headers ~body:"{}" ()
  in
  with_mock_runtime_api env ~callback (fun runtime ->
      Alcotest.(check bool) "malformed deadline is rejected" true
        (match Lambda_runtime.next_invocation runtime with Error _ -> true | Ok _ -> false))

let test_next_invocation_rejects_missing_deadline () =
  Eio_main.run @@ fun env ->
  let callback _conn _req _body =
    let headers =
      Http.Header.of_list [ ("Lambda-Runtime-Aws-Request-Id", "req-1") ]
    in
    Cohttp_eio.Server.respond_string ~status:`OK ~headers ~body:"{}" ()
  in
  with_mock_runtime_api env ~callback (fun runtime ->
      Alcotest.(check bool) "missing deadline is rejected" true
        (match Lambda_runtime.next_invocation runtime with Error _ -> true | Ok _ -> false))

let test_init_error_posts_to_the_right_path () =
  Eio_main.run @@ fun env ->
  let callback _conn (req : Http.Request.t) body =
    Alcotest.(check string) "path" "/2018-06-01/runtime/init/error" (Http.Request.resource req);
    Alcotest.(check (option string)) "Lambda-Runtime-Function-Error-Type header" (Some "Unhandled")
      (Http.Header.get (Http.Request.headers req) "Lambda-Runtime-Function-Error-Type");
    ignore (Eio.Buf_read.(parse_exn take_all) body ~max_size:1024);
    Cohttp_eio.Server.respond_string ~status:`Accepted ~body:"" ()
  in
  with_mock_runtime_api env ~callback (fun runtime ->
      match
        Lambda_runtime.init_error runtime ~error_message:"bad config" ~error_type:"ConfigError"
      with
      | Ok () -> ()
      | Error err -> Alcotest.fail (Lambda_runtime.error_to_string err))

(* No automated test for Cancelled re-raising in next_invocation/post: a test
   built on Eio.Fiber.first racing a cancellation can't distinguish correct
   re-raising from a bug, since the loser's Cancelled gets swallowed by
   cleanup either way. Verified by inspection instead. *)

(* Regression test for on_error being called outside Eio.Cancel.protect:
   this ISN'T subject to the "Cancelled always gets swallowed" limitation
   above — it doesn't inspect the exception outcome at all, only elapsed
   wall-clock time, which differs sharply between the two cases. on_error
   blocks in a long sleep; a racing fiber requests cancellation almost
   immediately. If on_error is (bug-wise) still shielded by protect, the
   sleep runs to completion before the pending cancellation is ever
   delivered — the whole test takes ~2s. If on_error is correctly outside
   protect, the sleep is interrupted right away — the test finishes in a
   fraction of a second. *)
let test_on_error_runs_outside_the_protected_ack_sequence () =
  Eio_main.run @@ fun env ->
  let callback _conn (req : Http.Request.t) body =
    ignore (Eio.Buf_read.(parse_exn take_all) body ~max_size:1024);
    if Http.Request.resource req = "/2018-06-01/runtime/invocation/next" then
      let headers =
        Http.Header.of_list
          [ ("Lambda-Runtime-Aws-Request-Id", "req-on-error-1");
            ("Lambda-Runtime-Deadline-Ms", "9999999999999");
          ]
      in
      Cohttp_eio.Server.respond_string ~status:`OK ~headers ~body:"{}" ()
    else
      (* The /response POST — fail it so on_error fires. *)
      Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"" ()
  in
  with_mock_runtime_api env ~callback (fun runtime ->
      let on_error_called = ref false in
      let on_error _msg =
        on_error_called := true;
        Eio.Time.sleep env#clock 2.0
      in
      let t0 = Eio.Time.now env#clock in
      Eio.Fiber.first
        (fun () -> Lambda_runtime.run_loop runtime ~clock:env#clock ~on_error ~handler:(fun _ -> Ok "{}") ())
        (fun () -> Eio.Time.sleep env#clock 0.1);
      let elapsed = Eio.Time.now env#clock -. t0 in
      Alcotest.(check bool) "on_error was invoked" true !on_error_called;
      Alcotest.(check bool)
        "on_error's sleep was interrupted by cancellation, not run to completion"
        true (elapsed < 1.0))

let test_handler_runs_outside_the_protected_ack_sequence () =
  Eio_main.run @@ fun env ->
  let error_seen = ref false in
  let callback _conn (req : Http.Request.t) body =
    ignore (Eio.Buf_read.(parse_exn take_all) body ~max_size:1024);
    match Http.Request.resource req with
    | "/2018-06-01/runtime/invocation/next" ->
      let headers =
        Http.Header.of_list
          [ ("Lambda-Runtime-Aws-Request-Id", "req-handler-cancelled");
            ("Lambda-Runtime-Deadline-Ms", "9999999999999");
          ]
      in
      Cohttp_eio.Server.respond_string ~status:`OK ~headers ~body:"{}" ()
    | "/2018-06-01/runtime/invocation/req-handler-cancelled/error" ->
      error_seen := true;
      Cohttp_eio.Server.respond_string ~status:`Accepted ~body:"" ()
    | path ->
      Alcotest.failf "unexpected Runtime API path: %s" path
  in
  with_mock_runtime_api env ~callback (fun runtime ->
      let t0 = Eio.Time.now env#clock in
      Eio.Fiber.first
        (fun () ->
          Lambda_runtime.run_loop runtime ~clock:env#clock
            ~on_error:(fun msg -> Alcotest.fail msg)
            ~handler:(fun _ ->
              Eio.Time.sleep env#clock 2.0;
              Ok "{}")
            ())
        (fun () -> Eio.Time.sleep env#clock 0.1);
      let elapsed = Eio.Time.now env#clock -. t0 in
      Alcotest.(check bool)
        "handler sleep was interrupted by cancellation"
        true (elapsed < 1.0);
      Alcotest.(check bool)
        "cancelled invocation was reported to Runtime API"
        true !error_seen)

(* Regression test: a persistently failing next_invocation used to retry
   with no delay at all — a busy-spin issuing as many requests per second
   as the CPU allows for the duration of the outage. Runs run_loop for a
   bounded window against a server that always fails /invocation/next, and
   counts how many times it was actually hit — with the fixed backoff this
   should be a handful of attempts over the window, not hundreds. *)
let test_next_invocation_failure_backs_off () =
  Eio_main.run @@ fun env ->
  let hits = ref 0 in
  let callback _conn _req body =
    ignore (Eio.Buf_read.(parse_exn take_all) body ~max_size:1024);
    incr hits;
    Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body:"" ()
  in
  with_mock_runtime_api env ~callback (fun runtime ->
      Eio.Fiber.first
        (fun () ->
          Lambda_runtime.run_loop runtime ~clock:env#clock
            ~on_error:(fun _ -> ())
            ~handler:(fun _ -> Ok "{}") ())
        (fun () -> Eio.Time.sleep env#clock 1.2);
      (* ~1.2s window / 0.5s backoff ~= 2-3 attempts; hundreds would mean
         no backoff at all. *)
      Alcotest.(check bool)
        (Printf.sprintf "backed off instead of busy-spinning (%d attempts in 1.2s)" !hits)
        true (!hits > 0 && !hits <= 6))

let () =
  Alcotest.run "lambda_runtime"
    [ ( "wire protocol (real local mock server)",
        [ Alcotest.test_case "next_invocation" `Quick test_next_invocation_real_call;
          Alcotest.test_case "respond" `Quick test_respond_posts_to_the_right_path_with_the_right_body;
          Alcotest.test_case "respond_error" `Quick test_respond_error_posts_error_shape_and_header;
          Alcotest.test_case "non-2xx from the Runtime API is reported" `Quick test_post_error_status_is_reported;
          Alcotest.test_case "non-2xx error includes the response body" `Quick
            test_post_error_includes_response_body;
          Alcotest.test_case "next_invocation rejects non-2xx" `Quick test_next_invocation_rejects_non_2xx;
          Alcotest.test_case "next_invocation rejects missing request id" `Quick
            test_next_invocation_rejects_missing_request_id;
          Alcotest.test_case "next_invocation rejects malformed deadline" `Quick
            test_next_invocation_rejects_malformed_deadline;
          Alcotest.test_case "next_invocation rejects missing deadline" `Quick
            test_next_invocation_rejects_missing_deadline;
          Alcotest.test_case "init_error" `Quick test_init_error_posts_to_the_right_path;
          Alcotest.test_case "on_error runs outside the protected ack sequence" `Quick
            test_on_error_runs_outside_the_protected_ack_sequence;
          Alcotest.test_case "handler runs outside the protected ack sequence" `Quick
            test_handler_runs_outside_the_protected_ack_sequence;
          Alcotest.test_case "next_invocation failure backs off instead of busy-spinning" `Quick
            test_next_invocation_failure_backs_off;
        ] );
    ]
