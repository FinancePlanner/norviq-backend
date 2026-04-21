#!/usr/bin/env bash
set -euo pipefail

LOOKUP="${1:-}"
DATABASE_URL="${DATABASE_URL:-}"
EXPORT_ROOT="${EXPORT_ROOT:-./exports}"

if [[ -z "${LOOKUP}" || -z "${DATABASE_URL}" ]]; then
  echo "usage: DATABASE_URL=postgres://... $0 <user-email-or-uuid>" >&2
  exit 64
fi

user_id="$(psql "${DATABASE_URL}" -AtX \
  -v lookup="${LOOKUP}" \
  -c "select id from users where id::text = :'lookup' or lower(email) = lower(:'lookup') limit 1")"

if [[ -z "${user_id}" ]]; then
  echo "user not found: ${LOOKUP}" >&2
  exit 1
fi

timestamp="$(date -u +%Y%m%d_%H%M%S)"
out_dir="${EXPORT_ROOT}/user_${user_id}_${timestamp}"
mkdir -p "${out_dir}"

cat > "${out_dir}/README.txt" <<EOF
StockPlan user data export
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
User ID: ${user_id}

Sensitive operational credentials and secrets are excluded:
- password hashes
- refresh tokens
- password reset tokens
- MFA challenges
- OAuth flow secrets
- APNS device tokens
- raw billing webhook payloads
EOF

psql "${DATABASE_URL}" -v user_id="${user_id}" -c "\\copy (
  select row_to_json(t)
  from (
    select id, email, username, bio, avatar_url, banner_avatar_url,
           household_partner_display_name, date_of_birth, is_verified,
           created_at, updated_at
    from users
    where id = :'user_id'
  ) t
) to '${out_dir}/profile.jsonl'"

tables="$(psql "${DATABASE_URL}" -AtX -c "
  select quote_ident(table_name)
  from information_schema.columns
  where table_schema = 'public'
    and column_name = 'user_id'
    and table_name not in (
      'users',
      'refresh_tokens',
      'password_reset_tokens',
      'mfa_challenges',
      'oauth_flows',
      'oauth_identities',
      'push_devices',
      'billing_events'
    )
  order by table_name
")"

while IFS= read -r table_name; do
  [[ -z "${table_name}" ]] && continue
  safe_name="${table_name//\"/}"
  psql "${DATABASE_URL}" -v user_id="${user_id}" -c "\\copy (
    select row_to_json(t)
    from (select * from ${table_name} where user_id = :'user_id') t
  ) to '${out_dir}/${safe_name}.jsonl'"
done <<< "${tables}"

psql "${DATABASE_URL}" -v user_id="${user_id}" -c "\\copy (
  select row_to_json(t)
  from (
    select id, provider_event_id, provider, event_type, user_id, processed_at, created_at
    from billing_events
    where user_id = :'user_id'
  ) t
) to '${out_dir}/billing_events_redacted.jsonl'"

(
  cd "${out_dir}"
  shasum -a 256 ./* > SHA256SUMS
)

echo "created export ${out_dir}"
