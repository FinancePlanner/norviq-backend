#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
EMAIL="${EMAIL:-}"
PASSWORD="${PASSWORD:-}"
REGISTER_FIRST=false
OUTPUT_MODE="token" # token|header|json

usage() {
  cat <<'USAGE' >&2
Usage:
  scripts/get_access_token.sh -e <email> -p <password> [--base-url <url>] [--register] [--header|--json]

Environment variables (optional):
  BASE_URL, EMAIL, PASSWORD

Examples:
  TOKEN=$(scripts/get_access_token.sh -e user@example.com -p 'password123')
  curl -H "Authorization: Bearer $(scripts/get_access_token.sh -e user@example.com -p 'password123')" http://localhost:8080/stocks
  scripts/get_access_token.sh -e user@example.com -p 'password123' --header
USAGE
}

have() { command -v "$1" >/dev/null 2>&1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--base-url) BASE_URL="$2"; shift 2 ;;
    -e|--email) EMAIL="$2"; shift 2 ;;
    -p|--password) PASSWORD="$2"; shift 2 ;;
    -r|--register) REGISTER_FIRST=true; shift ;;
    -H|--header) OUTPUT_MODE="header"; shift ;;
    --json) OUTPUT_MODE="json"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "${EMAIL}" || -z "${PASSWORD}" ]]; then
  echo "Missing EMAIL/PASSWORD." >&2
  usage
  exit 2
fi

build_payload() {
  if have python3; then
    EMAIL="$EMAIL" PASSWORD="$PASSWORD" python3 - <<'PY'
import json, os
print(json.dumps({"email": os.environ["EMAIL"], "password": os.environ["PASSWORD"]}))
PY
    return 0
  fi

  if have jq; then
    jq -n --arg email "$EMAIL" --arg password "$PASSWORD" '{email:$email,password:$password}'
    return 0
  fi

  echo "Need either python3 or jq installed to build JSON payload." >&2
  return 1
}

extract_token() {
  local body="$1"

  if have jq; then
    printf '%s' "$body" | jq -er '.token'
    return 0
  fi

  if have python3; then
    printf '%s' "$body" | python3 - <<'PY'
import json, sys
data = json.load(sys.stdin)
token = data.get("token")
if not token:
  raise SystemExit(2)
print(token)
PY
    return 0
  fi

  echo "Need either jq or python3 installed to parse JSON response." >&2
  return 1
}

post_json() {
  local url="$1"
  local payload="$2"

  local body_file
  body_file="$(mktemp)"
  local code
  code="$(curl -sS -o "$body_file" -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -X POST \
    --data-binary "$payload" \
    "$url" || true)"

  local body
  body="$(cat "$body_file")"
  rm -f "$body_file"

  printf '%s\n' "$code"
  printf '%s' "$body"
}

payload="$(build_payload)"

if [[ "$REGISTER_FIRST" == "true" ]]; then
  register_resp="$(post_json "${BASE_URL%/}/auth/register" "$payload")"
  register_code="${register_resp%%$'\n'*}"
  register_body="${register_resp#*$'\n'}"
  if [[ "$register_code" != "200" && "$register_code" != "409" ]]; then
    echo "Register failed (${register_code}). Body:" >&2
    echo "$register_body" >&2
    exit 1
  fi
fi

login_resp="$(post_json "${BASE_URL%/}/auth/login" "$payload")"
login_code="${login_resp%%$'\n'*}"
login_body="${login_resp#*$'\n'}"
if [[ "$login_code" != "200" ]]; then
  echo "Login failed (${login_code}). Body:" >&2
  echo "$login_body" >&2
  exit 1
fi

case "$OUTPUT_MODE" in
  json) printf '%s\n' "$login_body" ;;
  header) printf 'Authorization: Bearer %s\n' "$(extract_token "$login_body")" ;;
  *) printf '%s\n' "$(extract_token "$login_body")" ;;
esac
