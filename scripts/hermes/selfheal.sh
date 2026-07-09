#!/usr/bin/env bash
# Hermes finance-pipeline self-heal — idempotent reconciler.
#
# Lives on the PERSISTENT volume (/root/.hermes/financial-pipeline/selfheal.sh,
# bind-mounted from /mnt/volume-fsn1-1/hermes-data), so it survives an OS-disk
# rebuild. cloud-init's hermes-rebuild-bootstrap calls it with one line:
#
#   /root/.hermes/financial-pipeline/selfheal.sh >> /var/log/hermes-selfheal.log 2>&1 || true
#
# Fixes the three gaps that a clean rebuild leaves behind:
#   1. Tailscale not installed / not joined  -> install + `tailscale up` (authkey from volume)
#   2. finance-api bound to 127.0.0.1        -> rebind to the tailnet IP
#   3. custom sentiment cron jobs re-seeded away -> re-register if missing
#
# Safe to run by hand anytime — every step checks state before acting.
set -uo pipefail

PIPELINE=/root/.hermes/financial-pipeline
REBUILD=/root/.hermes/rebuild
AUTHKEY_FILE="${REBUILD}/tailscale-authkey.txt"
STATE_LIVE=/var/lib/tailscale/tailscaled.state
STATE_BACKUP="${REBUILD}/tailscaled.state"
TOKEN_FILE="${REBUILD}/finance-api-token.txt"
TOKEN_PERSISTENT="${REBUILD}/finance-api-token.persistent"
TS_HOSTNAME=hermes-vps
log() { echo "[selfheal $(date -u +%H:%M:%S)] $*"; }

# 1. Tailscale ---------------------------------------------------------------
if ! command -v tailscale >/dev/null 2>&1; then
  log "installing tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# Bring up only if not already connected. Prefer restoring the persisted node
# identity from the volume so the SAME tailnet IP survives a rebuild; fall back
# to the authkey (which mints a NEW node/IP) only if that fails.
if ! tailscale status >/dev/null 2>&1; then
  if [ -s "${STATE_BACKUP}" ]; then
    log "restoring persisted tailscale node identity from volume"
    systemctl stop tailscaled 2>/dev/null || true
    install -D -m600 "${STATE_BACKUP}" "${STATE_LIVE}"
    systemctl start tailscaled 2>/dev/null || true
    sleep 3
  fi
  if ! tailscale status >/dev/null 2>&1; then
    if [ -s "${AUTHKEY_FILE}" ]; then
      log "restore did not connect; tailscale up via authkey (new node/IP)"
      tailscale up --authkey="$(tr -d '\n\r' < "${AUTHKEY_FILE}")" --hostname="${TS_HOSTNAME}" || log "tailscale up failed"
    else
      log "WARN no authkey at ${AUTHKEY_FILE}; run 'tailscale up' manually"
    fi
  else
    log "reconnected as persisted node"
  fi
fi
TSIP="$(tailscale ip -4 2>/dev/null | head -1)"
if [ -z "${TSIP}" ]; then
  log "ERROR no tailnet IP; aborting bind + backend note"
  exit 1
fi
log "tailnet IP ${TSIP}"

# Persist current node identity to the volume for the next rebuild. Requires
# key expiry to be DISABLED for this node in the Tailscale admin console, else
# the saved identity expires and a rebuild falls back to a new IP.
if [ -s "${STATE_LIVE}" ]; then
  install -D -m600 "${STATE_LIVE}" "${STATE_BACKUP}" && log "backed up tailscale state to volume"
fi

# 2. finance-api: stable token + tailnet bind -------------------------------
# A rebuild regenerates the finance-api token, which breaks the backend. Pin a
# STABLE token on the volume (seeded once from the current token) and force the
# service to use it via the systemd override, so the backend's HERMES_API_TOKEN
# never has to change again.
if [ ! -s "${TOKEN_PERSISTENT}" ] && [ -s "${TOKEN_FILE}" ]; then
  install -m600 "${TOKEN_FILE}" "${TOKEN_PERSISTENT}"
  log "seeded persistent finance-api token from current"
fi
TOKEN="$(tr -d '\n\r' < "${TOKEN_PERSISTENT}" 2>/dev/null || true)"
# Keep the reference copy in sync so any tooling reading it gets the stable one.
[ -n "${TOKEN}" ] && printf '%s' "${TOKEN}" > "${TOKEN_FILE}" && chmod 600 "${TOKEN_FILE}"

OVERRIDE_DIR=/etc/systemd/system/finance-api.service.d
CURRENT_BIND="$(ss -tlnp 2>/dev/null | grep -oE '[0-9.]+:8780' | cut -d: -f1 | head -1)"
SVC_TOKEN="$(systemctl show finance-api.service -p Environment --value 2>/dev/null | tr ' ' '\n' | grep '^FINANCE_API_TOKEN=' | cut -d= -f2-)"
NEED_RESTART=0
[ "${CURRENT_BIND}" != "${TSIP}" ] && NEED_RESTART=1
[ -n "${TOKEN}" ] && [ "${SVC_TOKEN}" != "${TOKEN}" ] && NEED_RESTART=1
if [ "${NEED_RESTART}" = 1 ]; then
  log "reconciling finance-api (bind ${CURRENT_BIND:-none}->${TSIP}, token drift=$([ "${SVC_TOKEN}" != "${TOKEN}" ] && echo yes || echo no))"
  mkdir -p "${OVERRIDE_DIR}"
  cat > "${OVERRIDE_DIR}/override.conf" <<EOF
[Service]
Environment=FINANCE_API_TOKEN=${TOKEN}
ExecStart=
ExecStart=/usr/bin/python3 -u ${PIPELINE}/scripts/finance_api_server.py --db ${PIPELINE}/data/finance.sqlite --host ${TSIP} --port 8780
EOF
  chmod 600 "${OVERRIDE_DIR}/override.conf"
  systemctl daemon-reload
  systemctl restart finance-api.service
else
  log "finance-api already bound to ${TSIP} with stable token"
fi

# 3. Sentiment cron jobs -----------------------------------------------------
# hermes-agent reinstall re-seeds jobs.json with defaults, dropping our custom
# jobs. Re-add each only if absent. Prompts kept verbatim with the scraper.
ensure_job() {
  local name="$1" schedule="$2" prompt="$3"
  if hermes cron list 2>/dev/null | grep -q "${name}"; then
    log "cron ${name} present"
  else
    log "creating cron ${name}"
    hermes cron create "${schedule}" "${prompt}" --name "${name}" --deliver local >/dev/null 2>&1 \
      && log "cron ${name} created" || log "cron ${name} create FAILED"
  fi
}

TICKER_PROMPT="Read the JSON config ${PIPELINE}/scraper_config.json. For EACH symbol in its tickers array: search X for substantive posts from the last 7 days about \$SYMBOL (the stock) that contain an actual investment thesis, analysis, or strong opinion from credible accounts. Exclude giveaways, bots, engagement bait, price-screenshot-only posts, and spam. Collect at most 10 posts per symbol; verbatim text max 500 chars. Write ONE file ${PIPELINE}/inbox/tickers-TIMESTAMP.json (TIMESTAMP = current unix seconds) with exactly this shape: {\"tickers\":[{\"symbol\":\"AMD\",\"author\":\"display name\",\"author_handle\":\"handle without @\",\"url\":\"https://x.com/HANDLE/status/ID\",\"text\":\"verbatim post text\",\"sentiment\":\"bullish|bearish|neutral\",\"sentiment_score\":0.0,\"confidence\":0.0,\"posted_at\":\"ISO 8601\"}]}. Every post object MUST include its symbol field. sentiment_score in [-1,1], confidence in [0,1]. Only include posts you actually found via X search with real status URLs - never invent posts or URLs. If nothing substantive for a symbol, include no posts for it. Then run in terminal: python3 ${PIPELINE}/scripts/ticker_sentiment_scraper.py --mode ingest-file --file THE_FILE_YOU_WROTE and report only the final ingest-file done log line."

TOPIC_PROMPT="Search X and recent news for the most substantive recent posts/articles (last 7 days, personal-finance angle) for EACH of these topics: Housing (housing market, mortgage rates, rent prices), Savings (savings rates, HYSA, emergency funds), Insurance (premiums and coverage trends), Retirement (401k, IRA, pensions, social security), NetWorth (wealth tracking, FIRE), Taxes (income tax, deductions, planning changes), Debt (credit cards, loans, rates, payoff), Crypto (BTC/ETH market moves, regulation), Stocks (market outlook, earnings), Expenses (cost of living, inflation, budgets). At most 10 items per topic. Write ONE file ${PIPELINE}/inbox/topics-TIMESTAMP.json (TIMESTAMP = current unix seconds) with exactly this shape: {\"topics\":[{\"topic\":\"Housing\",\"title\":\"short headline\",\"summary\":\"1-2 sentence factual summary\",\"url\":\"source link\",\"author\":\"author or outlet\",\"sentiment\":\"positive|neutral|negative\",\"sentiment_score\":0.0,\"published_at\":\"ISO 8601\"}]}. Every item MUST include its topic field, spelled exactly as listed. sentiment reflects tone for a persons finances; sentiment_score in [-1,1]. Only include items you actually found via search with real URLs - never invent items. Then run in terminal: python3 ${PIPELINE}/scripts/ticker_sentiment_scraper.py --mode ingest-file --file THE_FILE_YOU_WROTE and report only the final ingest-file done log line."

if command -v hermes >/dev/null 2>&1; then
  ensure_job hermes-ticker-sentiment "every 45m" "${TICKER_PROMPT}"
  ensure_job hermes-topic-sentiment "0 6 * * *" "${TOPIC_PROMPT}"
else
  log "WARN hermes CLI not found; skipping cron restore"
fi

# 4. Leave the tailnet IP where the operator can read it --------------------
echo "${TSIP}" > "${REBUILD}/current-tailnet-ip.txt" 2>/dev/null || true
log "done. Backend HERMES_BASE_URL should be http://${TSIP}:8780"
log "if the tailnet IP changed, update /opt/stockplan/.env.production on the backend host and recreate prod-app."
