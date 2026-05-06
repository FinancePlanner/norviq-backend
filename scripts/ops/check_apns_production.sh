#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${1:-${DOMAIN:-}}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.production.yml}"
BASE_URL="${BASE_URL:-http://127.0.0.1:${APP_PORT:-8080}}"
RUN_MIGRATE="${RUN_MIGRATE:-true}"
START_APP="${START_APP:-true}"

if [[ -z "${DOMAIN}" ]]; then
  echo "usage: $0 <domain>" >&2
  echo "set COMPOSE_FILE, BASE_URL, RUN_MIGRATE=false, or START_APP=false to override defaults" >&2
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

check "APNS env vars are injected into production app container" \
  docker compose -f "${COMPOSE_FILE}" run --rm --no-deps --entrypoint sh app -lc '
    missing=0
    for name in APNS_TEAM_ID APNS_KEY_ID APNS_TOPIC APNS_PRIVATE_KEY_P8; do
      eval "value=\${$name:-}"
      if [ -z "$value" ]; then
        echo "missing $name" >&2
        missing=1
      fi
    done
    exit "$missing"
  '

if [[ "${RUN_MIGRATE}" == "true" ]]; then
  check "production migration boot parses APNS credentials" \
    docker compose -f "${COMPOSE_FILE}" run --rm migrate
fi

if [[ "${START_APP}" == "true" ]]; then
  check "production app starts" \
    docker compose -f "${COMPOSE_FILE}" up -d app
fi

check "readiness reports APNS healthy" bash -c "
  body=\$(curl -fsS -H 'Host: ${DOMAIN}' '${BASE_URL}/health/ready')
  printf '%s' \"\$body\" | tr -d '\n' | grep -E '\"apns\":\\{[^}]*\"status\":\"healthy\"' >/dev/null
"

check "recent app logs do not show APNS parse or disabled warnings" bash -c "
  logs=\$(docker compose -f '${COMPOSE_FILE}' logs --tail=160 app 2>&1)
  ! printf '%s' \"\$logs\" | grep -E 'invalidPEMDocument|APNS is disabled|APNS_PRIVATE_KEY_P8 could not be parsed' >/dev/null
"

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} APNS production check(s) failed." >&2
  exit 1
fi

echo "APNS production checks passed for ${DOMAIN}"
