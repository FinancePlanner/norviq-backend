# Infra Setup & Study Guide

Everything about the July 2026 platform migration: what changed, what's running,
how to operate it, and how to rebuild it from zero on a new VPS. Written to be
read later as a learning reference, not just a runbook.

---

## 1. What changed (the architectural shift)

### Before (compose on a pet VPS)
- One Hetzner box, hand-configured.
- `docker compose` for app + Postgres + Redis + an on-box observability stack
  (Prometheus/Grafana/Jaeger/otel-collector).
- Deploys: GitHub Actions built an image, **SSH'd into the box**, `git reset --hard`,
  `docker compose up`. Imperative, stateful, "works on that one server".
- TLS via a hand-written nginx+certbot gateway that existed **only on the box**
  (not in git → not reproducible).
- Secrets in a `.env.production` file on the server.

### After (GitOps on k3s)
- One Hetzner box, **fully described in code** (Terraform + cloud-init).
- **k3s** (lightweight Kubernetes) runs everything as declarative manifests.
- **ArgoCD** watches the `norviq-infra` git repo and makes the cluster match it
  (GitOps: git is the source of truth, not the server).
- Deploys: CI builds an image, pushes to GHCR, and **commits a new image tag**
  into this repo. ArgoCD notices and rolls it out. No SSH, no server-side git.
- TLS via **cert-manager** (Let's Encrypt) + Traefik ingress — declared in git.
- Secrets are **SealedSecrets**: encrypted, safe to commit, decrypted only
  inside the cluster.
- Heavy observability moved **off-box** to Grafana Cloud (free tier) via a small
  agent (Grafana Alloy), because a 4 GB box can't host Prometheus+Grafana+the app.

### Why this is better (and the trade-off)
- **Reproducible**: the whole platform is `terraform apply` + `kubectl apply`.
  Lose the server → rebuild in ~1 hour (see §6).
- **Declarative**: you change git, the cluster converges. Drift self-heals.
- **Auditable**: every prod change is a git commit / merged PR.
- **Trade-off**: more moving parts to learn (k8s, Helm, ArgoCD, sealed-secrets).
  On a single 4 GB node you get self-healing *pods*, not machine HA — if the box
  dies, everything is down until you rebuild (same as compose, but rebuild is now
  scripted). This is a deliberate "modern stack on a cheap box" choice.

---

## 2. What's running now (inventory)

Server `norviq-green`: Hetzner **cpx22** (2 vCPU / 4 GB / 80 GB, AMD, fsn1),
Ubuntu 24.04, **178.105.73.13** (+ IPv6). Primary IP is decoupled from the server
so a rebuild keeps the same IP → DNS never changes again.

| Layer | Component | Notes |
|---|---|---|
| OS tuning | zram (zstd, RAM-sized) + 2 GB swapfile | mandatory on 4 GB; zram needs `linux-modules-extra` |
| Orchestrator | **k3s v1.35.6** | single node, sqlite datastore (no etcd), metrics-server disabled |
| Ingress | **Traefik** (bundled with k3s) | HTTP/3 enabled, HTTP→HTTPS redirect |
| TLS | **cert-manager 1.20** | Let's Encrypt ClusterIssuers (prod + staging) |
| GitOps | **ArgoCD** (core install) | app-of-apps; no UI server (use `kubectl`/`argocd --core`) |
| Secrets | **sealed-secrets 0.38.4** | vendored `controller.yaml` (Bitnami Helm repo is dead) |
| Data | **Postgres 18** (1 instance, 2 DBs) + **Redis 7** | pg data on the detachable `/data` volume via a local PV |
| Telemetry | **Grafana Alloy** → Grafana Cloud | metrics + logs + traces off-box |
| Backups | `pg-backup` CronJob → age-encrypt → rclone → Hetzner Storage Box | nightly + weekly cluster-state |

### Namespaces
- `argocd` — GitOps controller
- `kube-system` — k3s core, Traefik, sealed-secrets
- `cert-manager` — TLS issuance
- `data` — Postgres, Redis, backup jobs
- `observability` — Alloy
- `staging` / `production` — the app (api + web) per environment

---

## 3. Architecture diagram

```
 Developer                         GitHub                          Hetzner box (k3s)
 ─────────                         ──────                          ─────────────────
 git push  ─────────►  norviq-backend / norviq-web
                          │ CI: build image
                          ▼
                       GHCR :sha ──────────────────────────►  (pulled by kubelet)
                          │ CI: yq bump image tag
                          ▼
                     norviq-infra (git)  ◄───── ArgoCD polls & syncs ─────┐
                       apps/*/values-*.yaml                               │
                          │ promote PR = prod gate                        │
                          ▼                                               │
                     merge to main ──────────────────────────────────────┘
                                                                          
 Users ──► DNS ──► Traefik (:443, cert-manager TLS) ──► api / web pods
                                          │
                     Postgres + Redis (ns: data, /data volume)
                                          │
                     Alloy ──► Grafana Cloud (metrics/logs/traces + alerts→Slack/Discord)
```

---

## 4. How to run & operate everything

All commands assume the kubeconfig:
```bash
export KUBECONFIG=~/.kube/norviq      # fetched from the server (see §6 step 3)
```

### Look around
```bash
kubectl get nodes
kubectl get applications -n argocd            # every ArgoCD app + sync/health
kubectl get pods -A                           # everything running
kubectl -n data get pods                      # postgres + redis
kubectl -n production get pods                # prod api + web
```

### ArgoCD without the UI (core install)
ArgoCD has no web UI here (saves RAM). Interact via kubectl:
```bash
# force a re-check of git
kubectl -n argocd annotate app <name> argocd.argoproj.io/refresh=hard --overwrite
# see why an app is unhealthy
kubectl -n argocd get app <name> -o jsonpath='{.status.conditions}'
```
Optional: `brew install argocd` then `argocd login --core` (uses your kubeconfig)
for `argocd app list`, `argocd app sync`, `argocd app rollback`.

### Deploy flow (what happens on a merge)
1. Merge to `main` in `norviq-backend` or `norviq-web`.
2. CI builds `ghcr.io/financeplanner/norviq-*:<sha>` and commits that tag into
   `apps/<svc>/values-staging.yaml` here.
3. ArgoCD syncs → `staging` namespace runs the new image (~3 min).
4. **Production** = run the "Promote to Production" workflow in this repo → it
   opens a PR copying the staging tag into `values-production.yaml` → **merging
   the PR is the deploy** (the manual gate).

### Database migrations
Run automatically as an ArgoCD **PreSync hook Job** before each api sync, with a
`pg_dump` taken first (to `/data/backups`). A failed migration fails the sync and
leaves the old pods serving. See `docs/runbook-rollback.md`.

### Rollback
- Normal: `git revert` the tag-bump / promote commit → ArgoCD deploys the old tag.
- Emergency: `kubectl -n production rollout undo deploy/api` (then still revert git,
  or self-heal reapplies the bad tag).

### Secrets (SealedSecrets)
```bash
# encrypt a new secret (safe to commit the output)
kubectl create secret generic NAME -n NS --from-literal=k=v --dry-run=client -o yaml \
  | kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system -o yaml \
  > secrets/NS/NAME.yaml
git add secrets/ && git commit -m "seal NAME" && git push   # ArgoCD applies it
```
**Back up the sealing key** (`docs/runbook-credentials.md` §F) — losing it means
re-sealing everything.

### Common troubleshooting
| Symptom | Look at |
|---|---|
| app `Unknown` sync | usually a missing image tag or a Helm render error — `kubectl -n argocd get app X -o jsonpath='{.status.conditions}'` |
| pod `CreateContainerConfigError` | a referenced Secret/ConfigMap doesn't exist yet (seal it) |
| pod `OOMKilled` (exit 137) | bump the memory limit in its manifest |
| `CrashLoopBackOff` | `kubectl logs <pod> --previous` |
| TLS not issuing | `kubectl get certificate,order,challenge -A` — DNS must point at the box first |

---

## 5. The k8s / GitOps concepts used (study notes)

- **Declarative vs imperative**: you describe the desired state (YAML in git);
  the controllers make reality match. Contrast with `docker compose up` which you
  *run* imperatively.
- **Controller/reconcile loop**: every k8s controller (and ArgoCD) continuously
  compares desired vs actual and acts to close the gap. "Self-healing" = this loop.
- **Helm chart**: a templated bundle of manifests. Here one shared `charts/app`
  renders both api and web with different `values-*.yaml`.
- **App-of-apps**: one root ArgoCD Application points at a folder of child
  Applications, so a single bootstrap brings up the whole platform.
- **PreSync hook**: a Job ArgoCD runs *before* applying the rest of a sync — used
  for DB migrations here.
- **SealedSecret**: asymmetric encryption. The public cert encrypts (anywhere);
  only the in-cluster controller's private key decrypts. That's why the ciphertext
  is safe in a public git repo.
- **PersistentVolume / local PV**: Postgres data lives on the Hetzner volume
  mounted at `/data`, exposed to the pod as a PV pinned to this node. The volume
  outlives the server.
- **Ingress + IngressClass**: Traefik watches Ingress objects and routes
  hostnames to services; cert-manager watches the same and provisions TLS.
- **Resource requests/limits**: requests = scheduling guarantee, limits = hard
  cap (exceed memory limit → OOMKilled). On 4 GB every workload sets these.

---

## 6. Rebuild from a brand-new VPS (the study exercise)

This is also the disaster-recovery procedure. Full version in
`docs/runbook-disaster-recovery.md`; this is the teaching walkthrough.

**What survives a total server loss:** this git repo, the Hetzner volume (if kept),
off-site backups (Storage Box), and the age private key + sealing-key backup
(in your password manager).

```bash
# 1. Provision the server (Terraform reuses the same primary IP → DNS unchanged)
cd terraform
export TF_VAR_hcloud_token='<hetzner token>'
terraform init && terraform apply
IP=$(terraform output -raw server_ipv4)

# 2. cloud-init auto-installs k3s + zram + mounts /data. Wait ~3 min, then:
ssh root@$IP 'cloud-init status --wait; systemctl is-active k3s'

# 3. Fetch the kubeconfig to your machine
ssh root@$IP 'cat /etc/rancher/k3s/k3s.yaml' | sed "s/127.0.0.1/$IP/" > ~/.kube/norviq
export KUBECONFIG=~/.kube/norviq
kubectl get nodes    # Ready

# 4. Restore the sealing key BEFORE ArgoCD (so committed SealedSecrets decrypt)
#    (decrypt your off-site cluster-state backup, apply the sealed-secrets key)
kubectl apply -f <the sealed-secrets key secret>

# 5. Bootstrap GitOps — everything else converges from git
kubectl apply -k cluster/argocd            # ArgoCD core (+ default AppProject)
kubectl apply -f argocd/root.yaml          # app-of-apps → all apps

# 6. If the data volume was lost, restore the newest dump into Postgres
#    (see docs/runbook-restore-drill.md, target the real DB)

# 7. TLS re-issues automatically once DNS resolves to the box.
```

**Gotchas learned the hard way (already fixed in the repo, keep in mind):**
- k3s install must **quote** the `eviction-hard=memory.available<200Mi` arg —
  the `<` is a shell redirection otherwise.
- Hetzner's minimal cloud kernel lacks the `zram` module → cloud-init installs
  `linux-modules-extra`.
- `cx22` doesn't exist in fsn1 → use `cpx22`.
- ArgoCD `core-install.yaml` omits the `default` AppProject → we add it.
- Large ArgoCD CRDs need `kubectl apply --server-side`.
- The ArgoCD application-controller needs ≥512 MB (320 MB OOMKills it).
- sealed-secrets: install from the vendored `controller.yaml` (Bitnami's Helm
  Pages repo 404s post-migration).

---

## 6b. Growing later (when you have paying users)

Nothing here forces you to scale on day one — the whole point of this design is
that **the deploy workflow never changes as you grow**. Do these in order, only
when a real need shows up.

### The old box: retire it whenever you want (no rush)
The new k3s box (`178.105.73.13`) can run indefinitely alongside the old compose
box. The old box is only "live" for whatever DNS still points at it. The cutover
(flip DNS, final DB copy) is a ~20–30 min job you do **when you're ready**, not on
a deadline — full steps in `runbook-cutover.md`. Until then, keep the old box as a
warm fallback; costs a few €/mo.

### Scaling ladder (cheapest → most involved)
1. **Bigger box (vertical)** — easiest win. Edit `server_type` in
   `terraform/variables.tf` (e.g. `cpx32` = 4 vCPU/8 GB, `cpx42` = 8 vCPU/16 GB),
   then `terraform apply`. Note: changing `server_type` **replaces** the server, so
   treat it like a rebuild (see §6): the primary IP is preserved (DNS unchanged),
   but you restore Postgres from the volume/backup. Do it in a maintenance window.
   Raising the box also lets you relax the tight memory limits in the manifests.
2. **Separate staging node** — give staging its own small box so a staging deploy
   can never disturb prod. Add a second `hcloud_server` + a k3s **agent** join, or a
   separate single-node cluster with its own ArgoCD apps pointing at the `staging`
   values. The GitOps layout already splits staging/production, so this is mostly
   Terraform.
3. **Multi-node HA** — real machine redundancy. Grow k3s to 3 server nodes
   (embedded etcd instead of sqlite) + a Hetzner Load Balancer in front of Traefik.
   Now a node failure doesn't take you down. This is the first step that changes
   k3s bootstrap (etcd, `--server` join tokens) — plan a proper migration.
4. **Managed / replicated Postgres** — the single Postgres pod is the real SPOF.
   When uptime matters, move to either a Hetzner-hosted managed Postgres, or run
   **CloudNativePG** (operator with replicas + automated failover + PITR). The app
   only needs `DATABASE_HOST` repointed (a values edit) + a data migration.
5. **Move heavy observability in-house (optional)** — if Grafana Cloud's free tier
   gets tight, self-host Prometheus/Loki/Grafana on a dedicated node. Alloy's
   exporters just repoint.

### If you outgrow GitHub (e.g. move to GitLab)
GitOps is CI- and registry-agnostic. Migrating means only: (a) CI becomes
`.gitlab-ci.yml` doing the same build → push → tag-bump; (b) the `ghcr-pull`
secret becomes a GitLab deploy-token dockerconfigjson; (c) ArgoCD Application
`repoURL`s point at GitLab. `charts/`, `apps/`, `argocd/`, `secrets/` are untouched.

**Rule of thumb:** stay on one box until a paying-user SLA actually requires HA.
Vertical scaling (step 1) buys a lot of headroom cheaply; only climb to steps 3–4
when downtime costs you money.

---

## 7. Repo map

```
terraform/        the server, IPs, firewall, volume, cloud-init (k3s bootstrap)
cluster/          ArgoCD core, cert-manager, sealed-secrets, alloy, traefik cfg, namespaces
charts/app/       one Helm chart for both api and web
apps/             per-service image tag + env (what CI bumps) + data layer manifests
argocd/           root app-of-apps + child Applications
secrets/          SealedSecrets (committable)
docs/             runbooks + this guide
```

See also: `runbook-bootstrap-user-steps.md`, `runbook-credentials.md`,
`runbook-cutover.md`, `runbook-rollback.md`, `runbook-restore-drill.md`,
`runbook-disaster-recovery.md`.
