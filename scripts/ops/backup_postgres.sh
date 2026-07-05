#!/usr/bin/env bash
set -euo pipefail

# Encrypted Postgres backup.
# Tier is derived from the date so the tiers in backup_retention.sh apply:
#   1st of month -> monthly, Sunday -> weekly, otherwise -> daily
# For cron, set GPG_PASSPHRASE_FILE to a root-only file with the passphrase;
# without it gpg prompts interactively.

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.production.yml}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
DATABASE_USERNAME="${DATABASE_USERNAME:-stockplan_user}"
DATABASE_NAME="${DATABASE_NAME:-stockplan_prod}"
GPG_PASSPHRASE_FILE="${GPG_PASSPHRASE_FILE:-}"

day_of_month="$(date -u +%d)"
day_of_week="$(date -u +%u)"
if [[ "${day_of_month}" == "01" ]]; then
  tier="monthly"
elif [[ "${day_of_week}" == "7" ]]; then
  tier="weekly"
else
  tier="daily"
fi

mkdir -p "${BACKUP_DIR}"
timestamp="$(date -u +%Y%m%d_%H%M%S)"
plain_path="${BACKUP_DIR}/stockplan_${tier}_${timestamp}.sql"
encrypted_path="${plain_path}.gpg"

docker compose -f "${COMPOSE_FILE}" exec -T db \
  pg_dump -U "${DATABASE_USERNAME}" "${DATABASE_NAME}" > "${plain_path}"

if [[ -n "${GPG_PASSPHRASE_FILE}" ]]; then
  gpg --batch --yes --pinentry-mode loopback \
    --passphrase-file "${GPG_PASSPHRASE_FILE}" \
    --symmetric --cipher-algo AES256 "${plain_path}"
else
  gpg --symmetric --cipher-algo AES256 "${plain_path}"
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "${encrypted_path}" > "${encrypted_path}.sha256"
else
  shasum -a 256 "${encrypted_path}" > "${encrypted_path}.sha256"
fi
rm -f "${plain_path}"

echo "created ${encrypted_path}"
echo "created ${encrypted_path}.sha256"
