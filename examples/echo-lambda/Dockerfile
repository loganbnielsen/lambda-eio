# Proves lambda-eio is actually deployable as a real AWS Lambda container
# image, not just runnable against a local Runtime API mock/emulator.
#
# Deliberately NOT built from an AWS base image (public.ecr.aws/lambda/*).
# AWS's container-image Lambda support only requires the image implement the
# Runtime API loop itself — which Lambda_runtime.run_loop already does,
# proven against AWS's own Runtime Interface Emulator in
# test/rie_smoke_test.sh. Using our own base image throughout (the same tag
# in both stages) means the final binary's glibc always matches the image
# it runs in — sidestepping the version mismatch that breaks zip-based
# custom runtimes built on a newer host and deployed to Amazon Linux's older
# glibc.
#
# Build: docker build -t lambda-eio-echo -f examples/echo-lambda/Dockerfile .
# (build context must be the repo root, so this can COPY the whole source tree)

FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
    opam m4 pkg-config build-essential ca-certificates git \
    && rm -rf /var/lib/apt/lists/*
RUN opam init --disable-sandboxing --bare -a -y \
    && opam switch create . ocaml-base-compiler.5.4.1 -y
WORKDIR /src
COPY . .
RUN opam install . --deps-only --with-test -y \
    && eval $(opam env) \
    && dune build test/rie_echo_handler.exe

FROM ubuntu:24.04 AS runtime
COPY --from=build /src/_build/default/test/rie_echo_handler.exe /var/task/bootstrap
WORKDIR /var/task
ENTRYPOINT ["/var/task/bootstrap"]
