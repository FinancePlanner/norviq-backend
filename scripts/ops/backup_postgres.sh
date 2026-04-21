#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.production.yml}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
DATABASE_USERNAME="${DATABASE_USERNAME:-stockplan_user}"
DATABASE_NAME="${DATABASE_NAME:-stockplan_prod}"

mkdir -p "${BACKUP_DIR}"
timestamp="$(date -u +%Y%m%d_%H%M%S)"
plain_path="${BACKUP_DIR}/stockplan_${timestamp}.sql"
encrypted_path="${plain_path}.gpg"

docker compose -f "${COMPOSE_FILE}" exec -T db \
  pg_dump -U "${DATABASE_USERNAME}" "${DATABASE_NAME}" > "${plain_path}"

gpg --symmetric --cipher-algo AES256 "${plain_path}"
shasum -a 256 "${encrypted_path}" > "${encrypted_path}.sha256"
rm -f "${plain_path}"

echo "created ${encrypted_path}"
echo "created ${encrypted_path}.sha256"
