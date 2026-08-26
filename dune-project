(lang dune 3.0)
(name lambda-eio)
(version 0.1.0)
(generate_opam_files true)

(package
 (name lambda-eio)
 (synopsis "Eio-native AWS Lambda Runtime API client and event parsing")
 (description "\
An implementation of the AWS Lambda Runtime API long-poll loop
(invocation/next, invocation/{id}/response, invocation/{id}/error, init/error)
against AWS_LAMBDA_RUNTIME_API, built on Eio and Cohttp_eio. Plain, unsigned
local HTTP — no SigV4/aws-eio dependency, since the Runtime API is a loopback
sidecar the Lambda execution environment provides, not a signed AWS API call.
Also parses S3/SQS/DynamoDB-Streams event envelopes into typed records.")
 (maintainers "lbendtlynielsen@gmail.com")
 (authors "lbendtly")
 (license "MIT")
 (homepage "https://github.com/loganbnielsen/lambda-eio")
 (bug_reports "https://github.com/loganbnielsen/lambda-eio/issues")
 (source (github loganbnielsen/lambda-eio))
 (depends
  (ocaml (>= 5.4.0))
  (eio (>= 1.3))
  (cohttp-eio (>= 6.2.0))
  (uri (>= 4.4.0))
  (yojson (>= 3.0.0))
  (eio_main (and (>= 1.3) :with-test))
  (alcotest :with-test)
  (odoc :with-doc)))
