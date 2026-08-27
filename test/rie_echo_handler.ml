(* Not an alcotest case — this is the "bootstrap" executable rie_smoke_test.sh
   hands to the real AWS Lambda Runtime Interface Emulator (RIE). RIE
   implements the actual Runtime API AWS Lambda itself speaks, so running
   Lambda_runtime.run_loop against it (rather than only against this repo's
   own hand-rolled Cohttp_eio.Server mock in test_lambda_runtime.ml) is real
   evidence this package's client is protocol-correct, not just consistent
   with its own author's understanding of the protocol. Loops forever, like
   any real Lambda bootstrap — RIE, not this process, decides when it dies. *)

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
