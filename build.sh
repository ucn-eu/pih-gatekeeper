#!/bin/bash -ex

mirage clean || true
mirage configure -t xen --no-opam --ip=10.0.0.254 --network=10.0.0.0/24 --gateway=10.0.0.1 --logs=*:info,irmin.node:error,irmin.bc:error,irmin.commit:error,git.memory:error --persist-host=10.0.0.1 --persist-port=20000
mirage build
