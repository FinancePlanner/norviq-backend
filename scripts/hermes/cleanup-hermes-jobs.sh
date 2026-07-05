#!/usr/bin/env bash
# Deletes unused/broken/duplicate Hermes cron jobs per JOBS-AUDIT.md and pauses
# the erroring Obsidian pipeline. Cuts SuperGrok agent runs ~190/day -> ~20/day.
#
# Dry run (prints plan only):
#   ssh root@78.46.192.73 'bash -s' < cleanup-hermes-jobs.sh
# Execute:
#   ssh root@78.46.192.73 'bash -s' < cleanup-hermes-jobs.sh -- --yes
set -euo pipefail
CONFIRM="${1:-}"

python3 - "$CONFIRM" <<'EOF'
import json, subprocess, sys

confirm = len(sys.argv) > 1 and sys.argv[1] in ("--yes", "yes")
raw = json.load(open("/root/.hermes/cron/jobs.json"))
jobs = raw["jobs"] if isinstance(raw, dict) and "jobs" in raw else raw
if isinstance(jobs, dict):
    jobs = list(jobs.values())

BROKEN = {
    "crypto-price-checker", "weekly-portfolio-strategy-review",
    "daily-x-content-email", "weekly-substack-free-email",
    "weekly-substack-paid-email",
}
DUPES = {"go-news-digest", "swift-news-digest", "x-link-ingestor",
         "portfolio-threshold-alerts-hourly"}

plan = []  # (id, name, reason)

mlp = sorted((j for j in jobs if j.get("name") == "multi-link-poller"),
             key=lambda j: str(j.get("last_run_at")))
for j in mlp[:-1]:
    plan.append((j["id"], j.get("name"), "duplicate multi-link-poller"))

for j in jobs:
    name, jid = j.get("name") or j.get("id"), j["id"]
    if any(jid == p[0] for p in plan):
        continue
    if str(j.get("enabled")) != "True":
        plan.append((jid, name, "disabled/unused"))
    elif name in BROKEN:
        plan.append((jid, name, "errors every run"))
    elif name in DUPES:
        plan.append((jid, name, "duplicate / token burner"))
    elif name == "server-health-monitor" and str(j.get("no_agent")) != "True":
        plan.append((jid, name, "agent-mode monitor duplicate"))

print(f"{len(jobs)} jobs total; deleting {len(plan)}, pausing 1:\n")
for jid, name, why in plan:
    print(f"  DELETE {jid}  {name}  [{why}]")
print("  PAUSE  Daily Obsidian Vault Pipeline  [context-length error every run]")

if not confirm:
    print("\nDry run. Re-run with --yes to execute.")
    sys.exit(0)

ok = fail = 0
for jid, name, why in plan:
    r = subprocess.run(["hermes", "cron", "remove", jid], capture_output=True, text=True)
    if r.returncode == 0:
        ok += 1
    else:
        fail += 1
        print(f"FAIL {jid} {name}: {(r.stderr or r.stdout).strip()[:100]}")
r = subprocess.run(["hermes", "cron", "pause", "Daily Obsidian Vault Pipeline"],
                   capture_output=True, text=True)
print(f"\nremoved={ok} failed={fail} "
      f"paused_obsidian={'OK' if r.returncode == 0 else (r.stderr or r.stdout).strip()[:80]}")
EOF
