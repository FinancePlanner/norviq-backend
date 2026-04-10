#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "" ]; then
  echo "Usage: $0 <app_image>"
  echo "Example: $0 ghcr.io/owner/StockPlanBackend:<previous_sha>"
  exit 1
fi

APP_IMAGE="$1"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.production.yml}"
ENV_FILE="${ENV_FILE:-.env}"

echo "Pulling rollback image: ${APP_IMAGE}"
docker pull "${APP_IMAGE}"

if [ -f "${ENV_FILE}" ]; then
  if grep -q '^APP_IMAGE=' "${ENV_FILE}"; then
    sed -i "s|^APP_IMAGE=.*|APP_IMAGE=${APP_IMAGE}|" "${ENV_FILE}"
  else
    echo "APP_IMAGE=${APP_IMAGE}" >> "${ENV_FILE}"
  fi
fi

export APP_IMAGE
docker compose -f "${COMPOSE_FILE}" up -d --no-deps app

DOMAIN_VALUE=""
if [ -f "${ENV_FILE}" ]; then
  DOMAIN_VALUE="$(grep '^DOMAIN=' "${ENV_FILE}" | tail -1 | cut -d '=' -f2- || true)"
fi

if [ -z "${DOMAIN_VALUE}" ]; then
  DOMAIN_VALUE="localhost"
fi

"$(dirname "$0")/check_health.sh" "${DOMAIN_VALUE}"
echo "Rollback completed to image ${APP_IMAGE}"
