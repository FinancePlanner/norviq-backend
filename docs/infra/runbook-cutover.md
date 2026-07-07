# Runbook: production cutover (blue compose box → green k3s box)

Preconditions (Phase 4 done): staging live on green for ≥1 week; shadow prod
apps deployed against a restored DB copy; dashboards + alerts firing; restore
rehearsed and timed; DNS TTL for `api.norviqa.io`, `norviq.org`, `www.norviq.org`
lowered to 300 s at least 2 days prior.

Window: evening, ~20–30 min (dominated by dump/restore).

1. **Pre-copy TLS certs** from blue so TLS works the second DNS flips:
   ```bash
   scp root@<blue>:/etc/letsencrypt/live/api.norviqa.io/{fullchain.pem,privkey.pem} .
   kubectl -n production create secret tls api-norviqa-io-tls --cert=fullchain.pem --key=privkey.pem
   # repeat for norviq.org into norviq-org-tls
   ```
   (Secret names must match the chart's convention: first ingress host with dots → dashes + `-tls`.)
   cert-manager takes over renewal after cutover.
2. **Stop writes on blue**: `ssh root@<blue> 'cd /opt/stockplan && docker compose -p prod -f docker-compose.production.yml stop app'`
   (nginx keeps serving 503; iOS clients retry.)
3. **Final dump → restore into green**:
   ```bash
   ssh root@<blue> 'cd /opt/stockplan && docker compose -p prod -f docker-compose.production.yml exec -T db pg_dump -Fc -U stockplan_user stockplan_prod' > final.dump
   kubectl -n data cp final.dump postgres-0:/tmp/final.dump
   kubectl -n data exec postgres-0 -- sh -c 'pg_restore --clean --if-exists -U "$POSTGRES_USER" -d stockplan_production /tmp/final.dump && rm /tmp/final.dump'
   ```
4. **Flip DNS**: A/AAAA for `api.norviqa.io`, `norviq.org`, `www.norviq.org` → green primary IP (terraform output `server_ipv4`/`server_ipv6`).
5. **Verify**: Grafana Cloud synthetics green; `curl https://api.norviqa.io/health/ready`; iOS login; web login session; RevenueCat webhook delivery; Sentry quiet.
6. **Keep blue 2 weeks** (app stopped, data intact). Rollback = revert DNS + `docker compose ... start app` (minutes). Note: writes made on green after cutover are lost on rollback unless you re-dump green → blue first — decide before rolling back.
7. **T+2 weeks**: snapshot blue's disk in Hetzner console, delete blue server. Delete remaining legacy workflows: backend `deploy.yml`; web `deploy.yml` + `scripts/deploy/on-server.sh`.
