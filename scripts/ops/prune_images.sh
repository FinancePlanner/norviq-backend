#!/usr/bin/env bash
set -euo pipefail

UNTIL="${1:-168h}"

echo "Pruning docker images older than ${UNTIL}"
docker image prune -af --filter "until=${UNTIL}"
