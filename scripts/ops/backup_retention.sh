#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-./backups}"
DAILY_DAYS="${DAILY_DAYS:-14}"
WEEKLY_DAYS="${WEEKLY_DAYS:-56}"
MONTHLY_DAYS="${MONTHLY_DAYS:-365}"

find "${BACKUP_DIR}" -type f -name 'stockplan_daily_*.sql.gpg*' -mtime "+${DAILY_DAYS}" -print -delete
find "${BACKUP_DIR}" -type f -name 'stockplan_weekly_*.sql.gpg*' -mtime "+${WEEKLY_DAYS}" -print -delete
find "${BACKUP_DIR}" -type f -name 'stockplan_monthly_*.sql.gpg*' -mtime "+${MONTHLY_DAYS}" -print -delete
# Legacy untiered backups (stockplan_<timestamp>.sql.gpg) from before tiered naming
find "${BACKUP_DIR}" -type f -name 'stockplan_2*.sql.gpg*' -mtime "+${DAILY_DAYS}" -print -delete
