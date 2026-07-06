# Infra Setup (backend view)

How the backend is built, shipped, and run after the July 2026 migration from
docker-compose-on-a-VPS to **GitOps on k3s**. This is the backend-developer slice;
the **architecture deep-dive for study is §"Architecture, in depth"** near the end.

> **Full infra doc set is mirrored in [`docs/infra/`](infra/)** — the complete
> `norviq-infra` guide + all runbooks (setup, credentials, cutover, rollback,
> restore drill, disaster recovery), copied here so the backend repo is
> self-contained. Source of truth is the `norviq-infra` repo; keep them in sync
> when infra changes.

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

---

## Architecture, in depth (study section)

### The mental-model shift: compose → Kubernetes

If you know docker-compose, map it like this:

| docker-compose | Kubernetes here | What actually differs |
|---|---|---|
| `service:` | **Deployment** (+ ReplicaSet + Pods) | k8s keeps N replicas alive and reschedules them; compose just starts a container |
| `docker compose up` | **ArgoCD sync** | you don't run it — a controller continuously makes the cluster match git |
| `ports:` published | **Service** + **Ingress** | Service = stable internal DNS name; Ingress = hostname→Service routing + TLS |
| `env_file:` | **Secret** (sealed) + explicit `env:` | secrets are encrypted in git, decrypted in-cluster |
| `depends_on` + healthcheck | **readiness/liveness probes** | k8s won't send traffic to a pod until its readiness probe passes |
| named volume | **PersistentVolume/Claim** | pg data is a local PV on the Hetzner disk volume, survives the server |
| `docker compose run migrate` | **PreSync hook Job** | runs before the app rolls, gated, with a pre-dump |
| the host's nginx | **Traefik ingress + cert-manager** | declared in git, TLS auto-issued/renewed |

### Request lifecycle (a user hits `api.norviqa.io`)

```
DNS(api.norviqa.io) → server public IP
  → Traefik (:443, terminates TLS with the cert cert-manager got from Let's Encrypt)
    → matches Ingress rule host=api.norviqa.io → Service "api" (ns: production)
      → Service load-balances to a ready "api" Pod
        → the Vapor process (reads config: plain env from Helm values + secret env from api-env)
          → Postgres (postgres.data.svc:5432) / Redis (redis.data.svc:6379)
```
Everything after DNS is inside the cluster. Service names are DNS
(`<svc>.<namespace>.svc.cluster.local`) resolved by k3s's CoreDNS.

### The GitOps reconcile loop (why "just push" deploys)

```
1. push to main (norviq-backend)
2. GitHub Actions: docker build → push ghcr.io/…/norviq-backend:<sha>
3. GitHub Actions: git clone norviq-infra, `yq` sets image.tag=<sha> in
   apps/api/values-staging.yaml, commit + push        ← the tag is the "desired state"
4. ArgoCD (running in-cluster) notices norviq-infra changed
5. ArgoCD renders the Helm chart with the new tag, diffs vs the live cluster
6. PreSync: runs the migrate Job (pg_dump first, then `migrate --yes`)
7. ArgoCD applies the new Deployment → k8s does a rolling update
   (maxUnavailable:0 → new pod must pass readiness before the old one is killed)
8. done — no SSH ever touched the server
```
The loop is *continuous*: if anything drifts from git (someone edits a live
resource), ArgoCD's `selfHeal` reverts it. Git is the single source of truth.

### Who does what (component responsibilities)

- **k3s** — the Kubernetes API + scheduler + kubelet. Decides which pod runs where
  (only one node here) and keeps them running.
- **Traefik** — the front door. Watches `Ingress` objects, routes hostnames,
  terminates TLS, does HTTP→HTTPS + HTTP/3.
- **cert-manager** — watches Ingresses, requests/renews Let's Encrypt certs via an
  HTTP-01 challenge, stores them as TLS Secrets Traefik uses.
- **ArgoCD** — the GitOps engine. `application-controller` reconciles; `repo-server`
  renders manifests/Helm; `redis` caches. No web UI (RAM) — use `kubectl`.
- **sealed-secrets controller** — holds the private key; turns committed
  `SealedSecret`s into real `Secret`s in-cluster.
- **Alloy** — the telemetry agent. Scrapes `/metrics`, tails pod logs, receives
  OTLP traces from the app, ships all three to Grafana Cloud.
- **CoreDNS** (in k3s) — in-cluster DNS so `postgres.data.svc` resolves.

### Config & secrets resolution (important for the backend)

A pod's env is assembled from two places, and **explicit `env:` wins over
`envFromSecret`** per key:
- Plain, non-secret config (`DATABASE_HOST/PORT/NAME`, `LOG_*`, `OBS_*`,
  `PROMETHEUS_ENABLED`) → set as explicit `env:` in
  `norviq-infra/apps/api/values-{staging,production}.yaml`.
- Secrets (`DATABASE_PASSWORD`, `JWT_SECRET`, APNs, OAuth, Resend, Finnhub, FMP,
  `USER_PII_ENCRYPTION_*`, …) → the sealed `api-env` secret, pulled in via
  `envFromSecret`.
So to change a DB host you edit values (git); to rotate a JWT secret you re-seal
`api-env`. Both are commits.

### Container registry & auth (relevant to going private / GitLab)

- Images live in **GHCR** (`ghcr.io/financeplanner/norviq-backend`). CI pushes with
  the built-in `GITHUB_TOKEN`.
- The cluster pulls with an **`imagePullSecrets`** (`ghcr-pull`, a
  `dockerconfigjson` SealedSecret) — needed once the packages are **private**.
- **Migrating to GitLab later**: this design ports cleanly. Only two things change:
  (1) CI moves to `.gitlab-ci.yml` doing the same build → push → tag-bump, and
  (2) `ghcr-pull` becomes a GitLab **deploy token** dockerconfigjson pointing at
  `registry.gitlab.com`. The Helm chart, ArgoCD, and everything in `norviq-infra`
  stay identical — GitOps is registry- and CI-agnostic. ArgoCD can even watch a
  GitLab repo instead of GitHub with only a `repoURL` change.

### Failure modes to recognize (and what they mean)

| You see | It means | First move |
|---|---|---|
| pod `ImagePullBackOff` | can't pull the image (private + no/bad pull secret) | check `ghcr-pull` exists in the ns / package visibility |
| pod `CreateContainerConfigError` | a referenced Secret/ConfigMap is missing | seal & commit it |
| pod `OOMKilled` (137) | hit its memory limit | raise the limit in values (4 GB budget!) |
| app `Unknown` in ArgoCD | Helm can't render — usually empty `image.tag` | let CI set a tag (push to main) |
| migration Job failed | schema change broke | old pods still serve; fix-forward or restore the pre-dump |
| `502` at the domain | no ready pod behind the Service | `kubectl -n <ns> get pods`, check readiness |

### Scaling / evolution path (when you have paying users)

You are **not** required to scale or to retire the old box on any schedule. Grow
only when a real need appears. Full step-by-step in
[`docs/infra/infra-setup.md` §6b](infra/infra-setup.md).

- **Retire the old box whenever** — the new k3s box runs fine indefinitely; the
  cutover (DNS flip + final DB copy, ~20–30 min, `docs/infra/runbook-cutover.md`)
  is done at your pace. Keep the old box as a warm fallback until then.
- **Vertical first**: bump `server_type` in `terraform/variables.tf`
  (`cpx32` 8 GB, `cpx42` 16 GB) → `terraform apply` (replaces the server, IP
  preserved → treat as a rebuild in a maintenance window). Cheapest headroom.
- **Separate staging node**: once prod load matters, give staging its own box so a
  staging deploy can't disturb prod. GitOps already splits the namespaces.
- **Multi-node HA**: grow k3s to 3 server nodes (embedded etcd) + a Hetzner Load
  Balancer → survives a node failure. First step that changes k3s bootstrap.
- **Managed / replicated Postgres**: the single Postgres pod is the SPOF; move to
  managed PG or CloudNativePG (replicas + failover + PITR). App just repoints
  `DATABASE_HOST` (a values edit) + data migration.
- None of these change the deploy *workflow* — that's the whole point of building
  it this way now on a cheap box. Climb to HA/replicated-DB only when downtime
  actually costs you money.
