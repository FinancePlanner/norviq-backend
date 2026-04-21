#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${1:-${DOMAIN:-}}"
ORIGIN="${2:-${ALLOWED_ORIGINS%%,*}}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.production.yml}"

if [[ -z "${DOMAIN}" ]]; then
  echo "usage: $0 <domain> [allowed-origin]" >&2
  exit 64
fi

failures=0

check() {
  local name="$1"
  shift
  if "$@"; then
    printf "ok - %s\n" "${name}"
  else
    printf "FAIL - %s\n" "${name}" >&2
    failures=$((failures + 1))
  fi
}

curl_local() {
  curl -fsS -H "Host: ${DOMAIN}" "$@"
}

check "liveness endpoint" curl_local "http://127.0.0.1/health/live"
check "readiness endpoint" curl_local "http://127.0.0.1/health/ready"

check "request id response header" bash -c \
  "curl -fsSI -H 'Host: ${DOMAIN}' http://127.0.0.1/health/live | grep -qi '^x-request-id:'"

if [[ -n "${ORIGIN}" ]]; then
  check "production CORS allows configured origin" bash -c \
    "curl -fsSI -H 'Host: ${DOMAIN}' -H 'Origin: ${ORIGIN}' http://127.0.0.1/health/live | grep -qi '^access-control-allow-origin: ${ORIGIN}'"
fi

check "HSTS header" bash -c \
  "curl -fsSI https://${DOMAIN}/health/live | grep -qi '^strict-transport-security:'"
check "X-Content-Type-Options header" bash -c \
  "curl -fsSI https://${DOMAIN}/health/live | grep -qi '^x-content-type-options: nosniff'"
check "X-Frame-Options header" bash -c \
  "curl -fsSI https://${DOMAIN}/health/live | grep -qi '^x-frame-options: DENY'"
check "Referrer-Policy header" bash -c \
  "curl -fsSI https://${DOMAIN}/health/live | grep -qi '^referrer-policy:'"
check "Permissions-Policy header" bash -c \
  "curl -fsSI https://${DOMAIN}/health/live | grep -qi '^permissions-policy:'"

check "postgres is not host-published by compose" bash -c \
  "! docker compose -f '${COMPOSE_FILE}' port db 5432 >/dev/null 2>&1"
check "redis is not host-published by compose" bash -c \
  "! docker compose -f '${COMPOSE_FILE}' port redis 6379 >/dev/null 2>&1"

check "app logs are JSON shaped" bash -c \
  "docker compose -f '${COMPOSE_FILE}' logs --tail=80 app | grep -E '\\{.*\"level\".*\"message\"' >/dev/null"

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} production preflight check(s) failed." >&2
  exit 1
fi

echo "production preflight passed for ${DOMAIN}"
