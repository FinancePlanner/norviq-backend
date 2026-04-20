#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "" ]; then
  echo "Usage: $0 <domain> [attempts] [sleep_seconds]"
  echo "Example: $0 api.stockplan.app 30 2"
  exit 1
fi

DOMAIN="$1"
ATTEMPTS="${2:-30}"
SLEEP_SECONDS="${3:-2}"

for _ in $(seq 1 "${ATTEMPTS}"); do
  if curl -fsS -H "Host: ${DOMAIN}" http://127.0.0.1/health/ready >/dev/null; then
    echo "Readiness check passed for ${DOMAIN}"
    exit 0
  fi
  if curl -fsS -H "Host: ${DOMAIN}" http://127.0.0.1/health >/dev/null; then
    echo "Health check passed for ${DOMAIN}"
    exit 0
  fi
  sleep "${SLEEP_SECONDS}"
done

echo "Health check failed for ${DOMAIN} after ${ATTEMPTS} attempts" >&2
exit 1
