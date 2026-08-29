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
      f (Lambda_runtime.create ~net:env#net ~sw ~base:(Printf.sprintf "127.0.0.1:%d" port)))

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
      | Error msg -> Alcotest.fail msg
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
      | Error msg -> Alcotest.fail msg)

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
      | Error msg -> Alcotest.fail msg)

let test_post_error_status_is_reported () =
  Eio_main.run @@ fun env ->
  let callback _conn _req _body = Cohttp_eio.Server.respond_string ~status:`Bad_request ~body:"" () in
  with_mock_runtime_api env ~callback (fun runtime ->
      Alcotest.(check bool) "a non-2xx response from the Runtime API itself is surfaced as an error" true
        (match Lambda_runtime.respond runtime ~request_id:"req-3" ~body:"{}" with
         | Error _ -> true
         | Ok () -> false))

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
      | Error msg -> Alcotest.fail msg)

(* No automated test for Cancelled re-raising in next_invocation/post: a test
   built on Eio.Fiber.first racing a cancellation can't distinguish correct
   re-raising from a bug, since the loser's Cancelled gets swallowed by
   cleanup either way. Verified by inspection instead. *)

let () =
  Alcotest.run "lambda_runtime"
    [ ( "wire protocol (real local mock server)",
        [ Alcotest.test_case "next_invocation" `Quick test_next_invocation_real_call;
          Alcotest.test_case "respond" `Quick test_respond_posts_to_the_right_path_with_the_right_body;
          Alcotest.test_case "respond_error" `Quick test_respond_error_posts_error_shape_and_header;
          Alcotest.test_case "non-2xx from the Runtime API is reported" `Quick test_post_error_status_is_reported;
          Alcotest.test_case "next_invocation rejects non-2xx" `Quick test_next_invocation_rejects_non_2xx;
          Alcotest.test_case "next_invocation rejects missing request id" `Quick
            test_next_invocation_rejects_missing_request_id;
          Alcotest.test_case "next_invocation rejects malformed deadline" `Quick
            test_next_invocation_rejects_malformed_deadline;
          Alcotest.test_case "init_error" `Quick test_init_error_posts_to_the_right_path;
        ] );
    ]
