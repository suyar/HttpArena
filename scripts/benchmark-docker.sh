#!/usr/bin/env bash
# benchmark-docker.sh — same as benchmark.sh but every load generator
# (gcannon, h2load, h2load-h3, wrk) runs from a Docker image instead of the
# host's installed binary.
#
# Required images are auto-built from docker/*.Dockerfile on first use.
# Override per-image with: GCANNON_IMAGE, H2LOAD_IMAGE, H2LOAD_H3_IMAGE, WRK_IMAGE.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export LOADGEN_DOCKER=true
export GCANNON_MODE=docker

exec "$SCRIPT_DIR/benchmark.sh" "$@"
