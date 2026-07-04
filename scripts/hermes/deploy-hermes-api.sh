#!/usr/bin/env bash
# Deploys the hardened Hermes finance API to the VPS and locks it to the
# Tailscale interface with a bearer token.
#
# Run from a machine with SSH key access to the VPS:
#   ./deploy-hermes-api.sh [root@78.46.192.73]
#
# Prerequisites on the VPS: `tailscale up --hostname=hermes-vps` already
# authenticated (run it once, follow the login URL).
set -euo pipefail

HOST="${1:-root@78.46.192.73}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_SCRIPT=/root/.hermes/financial-pipeline/scripts/finance_api_server.py

echo "==> Checking Tailscale on ${HOST}"
TAILNET_IP="$(ssh "${HOST}" 'tailscale ip -4 2>/dev/null | head -1' || true)"
if [[ -z "${TAILNET_IP}" ]]; then
  echo "ERROR: VPS is not joined to a tailnet yet. On the VPS run:"
  echo "  tailscale up --hostname=hermes-vps"
  echo "then authenticate via the printed URL and re-run this script."
  exit 1
fi
echo "    tailnet IP: ${TAILNET_IP}"

echo "==> Generating API token (stored only on the VPS + printed once here)"
TOKEN="$(openssl rand -hex 32)"

echo "==> Uploading finance_api_server.py"
scp -q "${SCRIPT_DIR}/finance_api_server.py" "${HOST}:${REMOTE_SCRIPT}"
ssh "${HOST}" "python3 -m py_compile ${REMOTE_SCRIPT}"

echo "==> Writing systemd override (tailnet bind + token) and restarting"
ssh "${HOST}" "mkdir -p /etc/systemd/system/finance-api.service.d && cat > /etc/systemd/system/finance-api.service.d/override.conf <<EOF
[Service]
Environment=FINANCE_API_TOKEN=${TOKEN}
ExecStart=
ExecStart=/usr/bin/python3 -u ${REMOTE_SCRIPT} --db /root/.hermes/financial-pipeline/data/finance.sqlite --host ${TAILNET_IP} --port 8780
EOF
systemctl daemon-reload && systemctl restart finance-api.service && sleep 1 && systemctl is-active finance-api.service"

echo "==> Verifying from the VPS"
ssh "${HOST}" "curl -s http://${TAILNET_IP}:8780/healthz | head -c 200; echo
curl -s -o /dev/null -w 'no-token status: %{http_code}\n' http://${TAILNET_IP}:8780/finance/summary
curl -s -o /dev/null -w 'with-token status: %{http_code}\n' -H 'Authorization: Bearer ${TOKEN}' http://${TAILNET_IP}:8780/finance/summary"

cat <<SUMMARY

Done. Backend configuration (put in StockPlanBackend .env / .env.production):

  HERMES_BASE_URL=http://${TAILNET_IP}:8780
  HERMES_API_TOKEN=${TOKEN}

The old 127.0.0.1 bind is gone; the API now answers only on the tailnet.
SUMMARY
