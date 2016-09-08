#!/bin/bash -ex

mirage clean || true
mirage configure -t xen --no-opam --ip=10.0.0.254 --netmask=255.255.255.0 --gateways=10.0.0.1 --logs=ucn.gatekeeper:info --persist-host=10.0.0.1 --persist-port=10000
mirage build
