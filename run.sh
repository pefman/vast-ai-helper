#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

./1-launch.sh "$@"
./2-serve.sh
./3-tunnel.sh
