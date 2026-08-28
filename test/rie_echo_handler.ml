(* Not an alcotest case — the "bootstrap" executable rie_smoke_test.sh hands
   to the real AWS Lambda Runtime Interface Emulator (RIE), giving
   protocol-correctness evidence beyond this repo's own mock server in
   test_lambda_runtime.ml. Loops forever; RIE decides when it dies. *)

let () =
  Eio_main.run @@ fun env ->
  match Lambda_runtime.runtime_api_base () with
  | Error msg ->
    Printf.eprintf "rie_echo_handler: %s\n%!" msg;
    exit 1
  | Ok base ->
    Eio.Switch.run @@ fun sw ->
    Lambda_runtime.run_loop ~net:env#net ~sw ~base ~handler:(fun (inv : Lambda_runtime.invocation) ->
        Ok (Printf.sprintf {|{"echoed":%s}|} inv.payload))
