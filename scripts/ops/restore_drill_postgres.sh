#!/usr/bin/env bash
set -euo pipefail

BACKUP_FILE="${1:-}"
RESTORE_DATABASE_URL="${RESTORE_DATABASE_URL:-}"
DRILL_LOG="${DRILL_LOG:-./backups/restore-drills.log}"

if [[ -z "${BACKUP_FILE}" || -z "${RESTORE_DATABASE_URL}" ]]; then
  echo "usage: RESTORE_DATABASE_URL=postgres://... $0 <backup.sql.gpg>" >&2
  echo "Do not point RESTORE_DATABASE_URL at production unless performing incident recovery." >&2
  exit 64
fi

tmp_sql="$(mktemp -t stockplan-restore.XXXXXX.sql)"
trap 'rm -f "${tmp_sql}"' EXIT

gpg --decrypt "${BACKUP_FILE}" > "${tmp_sql}"
psql "${RESTORE_DATABASE_URL}" -v ON_ERROR_STOP=1 < "${tmp_sql}"

users_count="$(psql "${RESTORE_DATABASE_URL}" -At -c "select count(*) from users")"
subscriptions_count="$(psql "${RESTORE_DATABASE_URL}" -At -c "select count(*) from subscriptions")"

mkdir -p "$(dirname "${DRILL_LOG}")"
{
  echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "backup=${BACKUP_FILE}"
  echo "target=${RESTORE_DATABASE_URL%%\?*}"
  echo "operator=${USER:-unknown}"
  echo "result=success"
  echo "users_count=${users_count}"
  echo "subscriptions_count=${subscriptions_count}"
  echo "---"
} >> "${DRILL_LOG}"

echo "restore drill completed; log appended to ${DRILL_LOG}"
