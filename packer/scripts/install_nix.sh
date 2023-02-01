#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o xtrace

sh <(curl -L https://nixos.org/nix/install) --daemon
