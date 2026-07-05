#!/usr/bin/env bash
set -euo pipefail

# Ship encrypted backups off-site to a Hetzner Storage Box via rclone and
# apply remote retention. Requires an rclone SFTP remote (default name:
# "storagebox") configured once with `rclone config`.
#
# Suggested cron on the server (runs backup, then ships it):
#   30 3 * * * cd /opt/stockplan && \
#     GPG_PASSPHRASE_FILE=/root/.stockplan-backup-pass ./scripts/ops/backup_postgres.sh && \
#     ./scripts/ops/backup_retention.sh && \
#     ./scripts/ops/backup_offsite.sh >> /var/log/stockplan-backup.log 2>&1

BACKUP_DIR="${BACKUP_DIR:-./backups}"
RCLONE_REMOTE="${RCLONE_REMOTE:-storagebox}"
REMOTE_PATH="${REMOTE_PATH:-backups/pg}"
REMOTE_RETENTION_DAYS="${REMOTE_RETENTION_DAYS:-30}"
MONTHLY_RETENTION_DAYS="${MONTHLY_RETENTION_DAYS:-365}"

rclone copy "${BACKUP_DIR}" "${RCLONE_REMOTE}:${REMOTE_PATH}" \
  --include 'stockplan_*.sql.gpg*' --transfers 2

# Monthly backups live in a separate folder with longer retention.
rclone move "${RCLONE_REMOTE}:${REMOTE_PATH}" "${RCLONE_REMOTE}:${REMOTE_PATH}-monthly" \
  --include 'stockplan_monthly_*'

rclone delete "${RCLONE_REMOTE}:${REMOTE_PATH}" --min-age "${REMOTE_RETENTION_DAYS}d"
rclone delete "${RCLONE_REMOTE}:${REMOTE_PATH}-monthly" --min-age "${MONTHLY_RETENTION_DAYS}d"

echo "offsite sync complete: ${RCLONE_REMOTE}:${REMOTE_PATH}"
