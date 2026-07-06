# Infra Setup (backend view)

How the backend is built, shipped, and run after the July 2026 migration from
docker-compose-on-a-VPS to **GitOps on k3s**. Full platform detail lives in the
`norviq-infra` repo (`docs/infra-setup.md`); this is the backend-developer slice.

---

## What changed for the backend

### Before
- Push to `main` → GitHub Actions built the image, **SSH'd into the VPS**,
  `git reset --hard`, ran `docker compose run migrate`, then `docker compose up app`.
- The server was a hand-configured pet; TLS was an on-box nginx gateway not in git.
- Config/secrets lived in `/opt/stockplan/.env.production` on the box.

### After
- Push to `main` → CI builds `ghcr.io/financeplanner/norviq-backend:<sha>` and
  **commits that tag** into `norviq-infra` (`apps/api/values-staging.yaml`).
- **ArgoCD** (running on the k3s box) notices the git change and rolls out the new
  image to the `staging` namespace. No SSH, no server-side git.
- **Production** is gated: run the "Promote to Production" workflow in
  `norviq-infra` → it opens a PR moving the staging tag to
  `values-production.yaml` → **merging that PR deploys prod**.
- Migrations run as an ArgoCD **PreSync hook Job** (same image, `migrate --yes`)
  that takes a `pg_dump` first. Failed migration = failed sync = old pods keep
  serving.
- Secrets are **SealedSecrets** in `norviq-infra/secrets/` (the old
  `.env.production` values, encrypted). The app reads them via `envFromSecret`.

### The workflow files
- `.github/workflows/ci.yml` — tests/lint on PRs (unchanged, now a required check).
- `.github/workflows/deploy-staging.yml` — the new build → GHCR → tag-bump flow.
- `.github/workflows/deploy.yml` + `deploy-dev.yml` — **legacy SSH deploys**, kept
  running until the k3s cutover completes, then deleted (migration Phase 5).

---

## What the backend now runs against

| Dependency | Before (compose) | After (k3s) |
|---|---|---|
| Postgres | `db` service, one DB | `postgres.data.svc` — one instance, **two DBs** (`stockplan_production`, `stockplan_staging`) |
| Redis | `redis` service | `redis.data.svc` |
| TLS/ingress | on-box nginx+certbot | Traefik + cert-manager (Let's Encrypt) |
| Metrics `/metrics` | scraped by nobody (orphaned) | scraped by Grafana Alloy → Grafana Cloud |
| Traces (swift-otel) | otel-collector on box | Alloy → Grafana Cloud Tempo (`OBS_TRACES_ENABLED=true`, endpoint `alloy.observability:4317`) |
| Logs | docker logs | pod stdout → Alloy → Grafana Cloud Loki (log JSON to stdout) |

Env split: `DATABASE_HOST/PORT/NAME`, `LOG_*`, `OBS_*`, `PROMETHEUS_ENABLED` are
plain env in the Helm values (`norviq-infra/apps/api/values-*.yaml`); the actual
secrets (`DATABASE_PASSWORD`, `JWT_SECRET`, APNs, OAuth, Resend, Finnhub, FMP,
`USER_PII_ENCRYPTION_*`, …) come from the sealed `api-env` secret.

---

## Running / debugging the backend on the cluster

```bash
export KUBECONFIG=~/.kube/norviq

kubectl -n staging get pods                     # or -n production
kubectl -n staging logs deploy/api -f           # app logs
kubectl -n staging exec deploy/api -- <cmd>     # exec into the app
kubectl -n data exec postgres-0 -- psql -U stockplan_user -d stockplan_staging

# force ArgoCD to re-check after a manual git change
kubectl -n argocd annotate app api-staging argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd get app api-staging -o jsonpath='{.status.sync.status}/{.status.health.status}'
```

### Local dev is unchanged
`docker-compose.dev.yml` / `docker-compose.yml` still work for local development.
The k3s stack is only staging + production.

---

## Migrating to a fresh VPS later (study)

The platform is fully in code. To stand it up on a new box:
`cd norviq-infra/terraform && terraform apply` → cloud-init installs k3s →
`kubectl apply -k cluster/argocd && kubectl apply -f argocd/root.yaml` → the whole
platform (this backend included) converges from git. Restore the DB from the
off-site dump if the data volume was lost.

Full step-by-step and the "gotchas we already fixed" list:
**`norviq-infra/docs/infra-setup.md` §6** and
`norviq-infra/docs/runbook-disaster-recovery.md`.

---

## Key concepts (why it's shaped this way)

- **GitOps**: git is the source of truth; ArgoCD makes the cluster match it. A
  deploy is a commit, a rollback is a `git revert`.
- **Declarative + self-healing**: controllers continuously reconcile desired vs
  actual state, so drift corrects itself.
- **PreSync migration + pre-dump**: schema changes are gated and always recoverable.
- **SealedSecrets**: encrypted secrets safe to commit; only the cluster can decrypt.
- **Single 4 GB node**: you get pod-level self-healing, not machine HA. If the box
  dies, rebuild from code (~1 hr). A deliberate cost/simplicity choice.
