#!/usr/bin/env bash
# Run all k6 perf scenarios against the local stack and collect summaries.
# Usage: [BASE_URL=...] [VUS=...] [DURATION=...] [TOKEN=...] ./scripts/perf/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
mkdir -p "$OUT_DIR"

BASE_URL="${BASE_URL:-http://localhost:8090}"
export BASE_URL

if ! command -v k6 >/dev/null 2>&1; then
  echo "k6 not installed. Run: brew install k6" >&2
  exit 1
fi

echo "==> Target: $BASE_URL"
echo "==> Waiting for /health ..."
for _ in $(seq 1 30); do
  if curl -fsS "$BASE_URL/health" >/dev/null 2>&1; then break; fi
  sleep 1
done

for scenario in smoke auth_flow api_load; do
  echo ""
  echo "==> Running $scenario"
  k6 run "$SCRIPT_DIR/$scenario.js" || echo "   ($scenario reported threshold failures — inspect $OUT_DIR/$scenario.json)"
done

echo ""
echo "==> Summaries in $OUT_DIR/"
echo "==> Top slow queries:"
docker compose exec -T db psql -U stockplan_user -d stockplan_dev -c \
  "SELECT calls, round(total_exec_time::numeric,1) AS total_ms, round(mean_exec_time::numeric,2) AS mean_ms, left(query,80) AS query FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 15;" \
  2>/dev/null || echo "   (pg_stat_statements unavailable — start with docker-compose.perf.yml)"
