# Credentials & env vars: where each value comes from and how to set it

Every token/secret the system needs, one row each. "Set via" = GH secret,
sealed secret, terraform var, or shell export.

## Master table

| Value | Where to get it | Set via |
|---|---|---|
| `TF_VAR_hcloud_token` | Hetzner Cloud Console → project → Security → API Tokens → Generate (Read & Write). You already have one. | shell export (§A) |
| `TF_VAR_ssh_public_key` | `cat ~/.ssh/id_ed25519.pub` (or `ssh-keygen -t ed25519` first) | shell export |
| `TF_VAR_admin_cidrs` | `curl -s ifconfig.me` → `["<ip>/32"]` | shell export |
| HCP user token | app.terraform.io → User Settings → Tokens → Create (or `terraform login`) | `terraform login` (§A) |
| `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_P8` | App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys (§B) | GH secret (norviq-ios) + shell for match |
| `MATCH_PASSWORD` | You invent it (`openssl rand -base64 24`). Remember it. | GH secret (norviq-ios) + shell for match |
| `INFRA_TOKEN` | Fine-grained PAT, Contents:Read/Write on norviq-infra (§C). Deploy keys are DISABLED org-wide. | GH secret (norviq-backend + norviq-web) |
| `MATCH_GIT_BASIC_AUTHORIZATION` | `echo -n "x-access-token:<PAT>" \| base64` — PAT with Contents:Read on norviq-certificates (§C) | GH secret (norviq-ios) |
| `SENTRY_ORG` | Sentry → Settings → the org slug in the URL | GH secret (norviq-ios) |
| `SENTRY_PROJECT` | Sentry → your iOS project → slug | GH secret (norviq-ios) |
| `SENTRY_AUTH_TOKEN` | Sentry → Settings → Auth Tokens → Create (scopes: `project:releases`, `org:read`) | GH secret (norviq-ios) |
| `SECRETS_XCCONFIG` | The whole `Config/Secrets.xcconfig` file (§D) | GH secret (norviq-ios) |
| `REVENUECAT_API_KEY` (iOS) | app.revenuecat.com → Project → API Keys → **Apple App Store** public key (`appl_...`) | inside Secrets.xcconfig |
| `AMPLITUDE_API_KEY` | amplitude.com → Settings → Projects → your project → API Key | inside Secrets.xcconfig |
| `PEXELS_API_KEY` | pexels.com → your account → Image & Video API → **regenerate** (old one is in git history) | inside Secrets.xcconfig |
| `SENTRY_DSN` (iOS) | Sentry → iOS project → Settings → Client Keys (DSN) | inside Secrets.xcconfig |
| `GOOGLE_OAUTH_CLIENT_ID` | console.cloud.google.com → APIs & Services → Credentials → your iOS OAuth client ID (public by design) | inside Secrets.xcconfig |
| api-env (whole `.env.production`) | Already on the live box: `/opt/stockplan/.env.production`. Contains DATABASE_PASSWORD, JWT_SECRET, APNS_*, FINNHUB_*, FMP_API_KEY, RESEND_API_KEY, USER_PII_ENCRYPTION_*, IBKR_*, SENTRY_* etc. | sealed secret (§E) |
| api-env staging | The live box `.env.development` (dev values) | sealed secret (§E) |
| web-env | web `.env.production` on box: SESSION_SECRET, SENTRY_DSN, POSTHOG_PROJECT_TOKEN, REVENUECAT_WEB_API_KEY. Generate SESSION_SECRET fresh: `openssl rand -hex 32` | sealed secret (§E) |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` | You invent (must match DATABASE_USERNAME/PASSWORD in api-env) | sealed secret (§E) |
| web-staging-htpasswd | `htpasswd -nbB norviq '<pass>'` (needs apache2-utils / httpd) | sealed secret (§E) |
| Grafana Cloud: `PROM_URL` `PROM_USER` `LOKI_URL` `LOKI_USER` `TEMPO_URL` `TEMPO_USER` | grafana.com → your stack → **Connections** / "Send Metrics/Logs/Traces" → each shows endpoint URL + username (numeric instance ID) | sealed secret grafana-cloud (§F) |
| Grafana Cloud: `GC_API_KEY` | grafana.com → stack → Access Policies → Create token (scopes: metrics:write, logs:write, traces:write) | sealed secret grafana-cloud (§F) |
| `AGE_PUBLIC_KEY` (backups) | `age-keygen -o ~/keys/norviq-backup.agekey` → prints `Public key: age1...` (keep the file offline) | sealed secret backup-config (§F) |
| rclone Storage Box creds | Hetzner Storage Box order confirmation → hostname `uXXXXX.your-storagebox.de`, user `uXXXXX`, password you set | `rclone config` remote `storagebox` (§F) |
| `GPG_PASSPHRASE_FILE` (old box backups) | You invent; write to `/root/.stockplan-backup-pass` (chmod 600) on the box | file on old box (§G) |

---

## §A. Terraform / Hetzner

```bash
cd ~/Projects/StockProject/norviq-infra/terraform
terraform login                                   # opens browser, paste HCP token
export TF_VAR_hcloud_token='<hetzner-api-token>'  # from Hetzner Console → Security → API Tokens
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
export TF_VAR_admin_cidrs="[\"$(curl -s ifconfig.me)/32\"]"
terraform init
terraform apply
```

Hetzner token exact path: console.hetzner.cloud → select project → left nav
**Security** → **API Tokens** tab → **Generate API Token** → permission **Read & Write**.
Copy immediately (shown once).

---

## §B. App Store Connect API key (.p8)

1. appstoreconnect.apple.com → **Users and Access** → **Integrations** tab →
   **App Store Connect API** → **Team Keys** → **+**.
2. Name it `norviq-ci`, Access **App Manager**, Generate.
3. **Download** `AuthKey_<KEYID>.p8` — one-time only. Save to `~/Downloads/`.
4. On that page copy: **Key ID** (per key) and **Issuer ID** (top, shared).

```bash
export ASC_KEY_ID='<KEYID>'
export ASC_ISSUER_ID='<ISSUER-UUID>'
export ASC_KEY_P8="$(base64 -i ~/Downloads/AuthKey_<KEYID>.p8)"
```

---

## §C. CI git access via fine-grained PATs (deploy keys are disabled org-wide)

FinancePlanner org disables deploy keys (`422 Deploy keys are disabled`), so CI
authenticates to the private infra/certs repos with fine-grained PATs instead.

Create the PAT(s): github.com → Settings → Developer settings →
**Fine-grained tokens** → Generate new token. Resource owner **FinancePlanner**
(may need org approval: Org → Settings → Personal access tokens → allow).

**PAT-infra** — Repository access: only `norviq-infra`; Permissions: **Contents:
Read and write**. Used by backend + web CI to push tag bumps.

```bash
gh secret set INFRA_TOKEN --repo FinancePlanner/norviq-backend --body '<pat-infra>'
gh secret set INFRA_TOKEN --repo FinancePlanner/norviq-web     --body '<pat-infra>'
```

**PAT-certs** — Repository access: only `norviq-certificates`; Permissions:
**Contents: Read-only**. Used by iOS CI so match can clone the certs repo.

```bash
# match reads git over HTTPS using base64("x-access-token:<PAT>")
gh secret set MATCH_GIT_BASIC_AUTHORIZATION --repo FinancePlanner/norviq-ios \
  --body "$(echo -n 'x-access-token:<pat-certs>' | base64)"
```

(One PAT scoped to both repos also works if you prefer fewer tokens; least
privilege = two.)

---

## §D. iOS Secrets.xcconfig + GH secrets

```bash
cd ~/Projects/StockProject/norviq-ios/financeplan
git checkout ci/fastlane-release
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
# edit Config/Secrets.xcconfig — fill the 5 values from the master table
```

Then push all iOS GH secrets:

```bash
R=FinancePlanner/norviq-ios
gh secret set ASC_KEY_ID        --repo $R --body "$ASC_KEY_ID"
gh secret set ASC_ISSUER_ID     --repo $R --body "$ASC_ISSUER_ID"
gh secret set ASC_KEY_P8        --repo $R --body "$ASC_KEY_P8"
gh secret set MATCH_PASSWORD    --repo $R --body '<your match passphrase>'
gh secret set SENTRY_ORG        --repo $R --body '<sentry-org-slug>'
gh secret set SENTRY_PROJECT    --repo $R --body '<sentry-ios-project-slug>'
gh secret set SENTRY_AUTH_TOKEN --repo $R --body '<sentry-auth-token>'
gh secret set SECRETS_XCCONFIG  --repo $R < Config/Secrets.xcconfig
```

App-store environment: norviq-ios → Settings → Environments → New `app-store`
→ Required reviewers → add yourself.

---

## §E. Sealed secrets — apps (needs cluster + kubeseal)

Simplest correct approach: seal the WHOLE env file. The Helm chart's explicit
`env:` (DATABASE_HOST/NAME, LOG_*, OBS_*) overrides any stale value in the
secret, so you don't have to cherry-pick keys.

```bash
brew install kubeseal age
export KUBECONFIG=~/.kube/norviq
KS="kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system -o yaml"
INFRA=~/Projects/StockProject/norviq-infra

# --- api-env (production) : copy .env.production off the live box first ---
scp root@<old-box>:/opt/stockplan/.env.production /tmp/api.prod.env
kubectl create secret generic api-env -n production --from-env-file=/tmp/api.prod.env \
  --dry-run=client -o yaml | $KS > $INFRA/secrets/production/api-env.yaml

# --- api-env (staging) ---
scp root@<old-box>:/opt/stockplan/.env.development /tmp/api.dev.env
kubectl create secret generic api-env -n staging --from-env-file=/tmp/api.dev.env \
  --dry-run=client -o yaml | $KS > $INFRA/secrets/staging/api-env.yaml

# --- postgres-credentials (must match DATABASE_USERNAME/PASSWORD in api-env) ---
kubectl create secret generic postgres-credentials -n data \
  --from-literal=POSTGRES_USER='stockplan_user' \
  --from-literal=POSTGRES_PASSWORD='<same as api-env DATABASE_PASSWORD>' \
  --dry-run=client -o yaml | $KS > $INFRA/secrets/data/postgres-credentials.yaml

# --- web-env (production) ---
kubectl create secret generic web-env -n production \
  --from-literal=SESSION_SECRET="$(openssl rand -hex 32)" \
  --from-literal=SENTRY_DSN='<web sentry dsn>' \
  --from-literal=POSTHOG_PROJECT_TOKEN='<posthog token>' \
  --from-literal=REVENUECAT_WEB_API_KEY='<revenuecat web key>' \
  --dry-run=client -o yaml | $KS > $INFRA/secrets/production/web-env.yaml
# repeat with -n staging into secrets/staging/web-env.yaml (its own SESSION_SECRET)

# --- web staging basic-auth ---
kubectl create secret generic web-staging-htpasswd -n staging \
  --from-literal=users="$(htpasswd -nbB norviq '<staging-pass>')" \
  --dry-run=client -o yaml | $KS > $INFRA/secrets/staging/web-staging-htpasswd.yaml

cd $INFRA && git add secrets/ && git commit -m "Seal secrets" && git push
rm -f /tmp/api.prod.env /tmp/api.dev.env      # do not leave plaintext around
```

RevenueCat WEB key: revenuecat dashboard → API Keys → **Web Billing** (`rcb_...`).
PostHog token: eu.posthog.com → Project Settings → Project API Key (`phc_...`).

---

## §F. Sealed secrets — observability + backups

```bash
# age keypair for backups (private key stays OFFLINE)
age-keygen -o ~/keys/norviq-backup.agekey        # prints "Public key: age1..."

# Grafana Cloud: grafana.com → your stack → Connections
#   Prometheus/Mimir "Send Metrics"  -> PROM_URL + username (PROM_USER)
#   Loki "Send Logs"                 -> LOKI_URL + username (LOKI_USER)
#   Tempo "Send Traces" (OTLP)       -> TEMPO_URL + username (TEMPO_USER)
#   Access Policies -> create token  -> GC_API_KEY
kubectl create secret generic grafana-cloud -n observability \
  --from-literal=PROM_URL='https://<...>/api/prom/push' \
  --from-literal=PROM_USER='<mimir-id>' \
  --from-literal=LOKI_URL='https://<...>/loki/api/v1/push' \
  --from-literal=LOKI_USER='<loki-id>' \
  --from-literal=TEMPO_URL='<tempo-otlp-endpoint>:443' \
  --from-literal=TEMPO_USER='<tempo-id>' \
  --from-literal=GC_API_KEY='<access-policy-token>' \
  --dry-run=client -o yaml | $KS > $INFRA/secrets/observability/grafana-cloud.yaml

# rclone Storage Box remote for the in-cluster backup CronJob
rclone config create storagebox sftp \
  host u<XXXXX>.your-storagebox.de user u<XXXXX> pass '<storagebox-pass>' port 23
# the CronJob reads rclone config from the backup-config secret; seal the
# rclone.conf + the age PUBLIC key:
kubectl create secret generic backup-config -n data \
  --from-file=rclone.conf=$HOME/.config/rclone/rclone.conf \
  --from-literal=AGE_PUBLIC_KEY="$(grep -o 'age1[0-9a-z]*' ~/keys/norviq-backup.agekey | head -1)" \
  --dry-run=client -o yaml | $KS > $INFRA/secrets/data/backup-config.yaml

# BACK UP THE SEALING KEY (losing it = re-seal everything)
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  | age -r "$(grep -o 'age1[0-9a-z]*' ~/keys/norviq-backup.agekey | head -1)" \
  -o ~/norviq-sealing-key.age
# copy ~/norviq-sealing-key.age off-site + note the passphrase in a password manager

cd $INFRA && git add secrets/ && git commit -m "Seal observability + backup secrets" && git push
```

---

## §G. Old box — Phase 0 safety (do today, before any cutover)

```bash
ssh root@<old-box>
printf '%s' '<invent-a-passphrase>' > /root/.stockplan-backup-pass && chmod 600 /root/.stockplan-backup-pass
# configure rclone remote "storagebox" on the box too (rclone config)
crontab -e
# add:
30 3 * * * cd /opt/stockplan && GPG_PASSPHRASE_FILE=/root/.stockplan-backup-pass ./scripts/ops/backup_postgres.sh && ./scripts/ops/backup_retention.sh && ./scripts/ops/backup_offsite.sh >> /var/log/stockplan-backup.log 2>&1
```

Then lower DNS TTL for `api.norviqa.io`, `norviq.org`, `www.norviq.org` to 300s
at your DNS provider.

---

## Order to actually do it

1. §G (backups on old box) — today, independent
2. §C (deploy keys) + §B (ASC key) + §D (iOS secrets) — unblocks iOS CI + match
3. §A (terraform apply) → cluster exists
4. Bootstrap ArgoCD (see runbook-bootstrap-user-steps §7)
5. §E + §F (seal secrets) → apps + observability go healthy
6. Backup sealing key (§F end) — do not skip
```
