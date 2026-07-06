# Bootstrap: manual steps (things Claude cannot do for you)

Ordered. Each block is copy-pasteable. Replace `<...>` placeholders.

Repo name reality (GitHub `FinancePlanner/*`):
`norviq-infra`, `norviq-backend`, `norviq-web`, `norviq-ios` (slug `stock-plan-ios`),
`norviq-certificates` (slug `StockPlanCertificates`), `norviq-shared`.
Local dirs: infra=`norviq-infra`, backend=`norviq-backend`, web=`norviq-web`,
iOS git repo=`norviq-ios/financeplan`, certs=`norviq-certificates`.

---

## 0. Repoint local git remotes to the renamed repos (optional, GitHub redirects old URLs)

```bash
cd ~/Projects/StockProject/norviq-web      && git remote set-url origin git@github.com:FinancePlanner/norviq-web.git
cd ~/Projects/StockProject/norviq-backend  && git remote set-url origin git@github.com:FinancePlanner/norviq-backend.git
cd ~/Projects/StockProject/norviq-ios/financeplan && git remote set-url origin git@github.com:FinancePlanner/norviq-ios.git
cd ~/Projects/StockProject/norviq-certificates    && git remote set-url origin git@github.com:FinancePlanner/norviq-certificates.git
```

---

## 1. Push the branches / infra (norviq-infra already pushed to main)

```bash
# web: origin was stripped by filter-repo — re-add, then FORCE push (history rewritten)
cd ~/Projects/StockProject/norviq-web
git remote add origin git@github.com:FinancePlanner/norviq-web.git   # if missing
git push --force --all origin
git push --force --tags origin
# ^ tell any collaborators to re-clone; old PRs (cursor/*) reference dead SHAs

# backend: normal push of the new branch, open PR
cd ~/Projects/StockProject/norviq-backend
git push -u origin deploy/gitops-staging
gh pr create --fill

# web deploy branch PR (after the force-push above)
cd ~/Projects/StockProject/norviq-web
git push -u origin deploy/gitops-staging
gh pr create --fill

# iOS fastlane branch PR
cd ~/Projects/StockProject/norviq-ios/financeplan
git push -u origin ci/fastlane-release
gh pr create --fill
```

---

## 2. Seed the match certificates repo  ← fixes "Could not locate Gemfile"

`bundle exec fastlane match` must run **from the iOS app repo** (where the
`Gemfile` + `fastlane/Matchfile` live), NOT from the certificates repo.

```bash
cd ~/Projects/StockProject/norviq-ios/financeplan

# the Gemfile is on the ci/fastlane-release branch — get onto it (or merge it to main first)
git checkout ci/fastlane-release

# install the pinned fastlane
gem install bundler
bundle install

# create the encryption passphrase (remember it — this becomes MATCH_PASSWORD)
export MATCH_PASSWORD='<pick-a-strong-passphrase>'

# App Store Connect API key env (see step 3 for how to create the .p8)
export ASC_KEY_ID='<key-id>'
export ASC_ISSUER_ID='<issuer-id>'
export ASC_KEY_P8="$(base64 -i ~/Downloads/AuthKey_<key-id>.p8)"

# generate + store the distribution cert & profile in norviq-certificates
bundle exec fastlane match appstore
```

The `norviq-certificates` repo must exist and be empty (it does). match fills it
with the encrypted cert + provisioning profile. Do this **on your Mac once**; CI
only reads it (readonly).

If it complains the certs repo is the wrong URL, confirm
`fastlane/Matchfile` `git_url` = `git@github.com:FinancePlanner/norviq-certificates.git`.

---

## 3. App Store Connect API key (.p8)

1. appstoreconnect.apple.com → Users and Access → **Integrations** → App Store Connect API → **Team Keys**.
2. Generate key, role **App Manager**. Download `AuthKey_XXXX.p8` (one-time download).
3. Note **Key ID** and **Issuer ID** (top of the page).

Values map to: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (base64 of the .p8).

---

## 4. GitHub secrets

Set via `gh secret set` (run in each repo dir) or the web UI (repo → Settings → Secrets and variables → Actions).

Deploy keys are DISABLED org-wide on FinancePlanner, so CI uses fine-grained
PATs. See runbook-credentials.md §C for the token creation details.

### 4a. INFRA_TOKEN — lets backend/web CI push tag-bumps to norviq-infra

Fine-grained PAT, resource owner FinancePlanner, repo `norviq-infra`, Contents:
Read and write.

```bash
gh secret set INFRA_TOKEN --repo FinancePlanner/norviq-backend --body '<pat-infra>'
gh secret set INFRA_TOKEN --repo FinancePlanner/norviq-web     --body '<pat-infra>'
```

### 4b. MATCH_GIT_BASIC_AUTHORIZATION — lets iOS CI read the certificates repo

Fine-grained PAT, repo `norviq-certificates`, Contents: Read-only.

```bash
gh secret set MATCH_GIT_BASIC_AUTHORIZATION --repo FinancePlanner/norviq-ios \
  --body "$(echo -n 'x-access-token:<pat-certs>' | base64)"
```

### 4c. iOS secrets (repo: norviq-ios)

```bash
R=FinancePlanner/norviq-ios
gh secret set ASC_KEY_ID     --repo $R --body '<key-id>'
gh secret set ASC_ISSUER_ID  --repo $R --body '<issuer-id>'
gh secret set ASC_KEY_P8     --repo $R --body "$(base64 -i ~/Downloads/AuthKey_<key-id>.p8)"
gh secret set MATCH_PASSWORD --repo $R --body '<the passphrase from step 2>'
gh secret set SENTRY_ORG     --repo $R --body '<sentry-org-slug>'
gh secret set SENTRY_PROJECT --repo $R --body '<sentry-project-slug>'
gh secret set SENTRY_AUTH_TOKEN --repo $R --body '<sentry-auth-token>'
# full content of Config/Secrets.xcconfig (step 5) as one secret:
gh secret set SECRETS_XCCONFIG --repo $R < ~/Projects/StockProject/norviq-ios/financeplan/Config/Secrets.xcconfig
```

### 4d. Create the `app-store` GitHub Environment (manual production gate)

norviq-ios → Settings → **Environments** → New environment `app-store` →
enable **Required reviewers** → add yourself. The `release` job waits for your
approval before shipping to the App Store.

---

## 5. Xcode: wire Config/Secrets.xcconfig + rotate Pexels key

### 5a. Create the real secrets file (gitignored)

```bash
cd ~/Projects/StockProject/norviq-ios/financeplan
git checkout ci/fastlane-release           # where the example lives
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
# edit Config/Secrets.xcconfig, fill the real values
```

### 5b. Wire it as a base configuration (Xcode, one-time)

1. Open `financeplan.xcodeproj`. Select the project (blue icon) → **Info** tab → **Configurations**.
2. For each configuration (Debug, Release, Beta): set **Based on Configuration File** → `Secrets` (the xcconfig) for the `financeplan` target.
   - If Xcode doesn't list it: File → Add Files → select `Config/Secrets.xcconfig`, then re-pick it in Configurations.

### 5c. Replace hardcoded values in Info.plist with build-setting refs

In `financeplan/Info.plist`, swap the literal keys for `$(VAR)` (Xcode substitutes at build):

| Info.plist key | new value |
|---|---|
| RevenueCatAPIKey | `$(REVENUECAT_API_KEY)` |
| AmplitudeAPIKey | `$(AMPLITUDE_API_KEY)` |
| PexelsAPIKey | `$(PEXELS_API_KEY)` |
| SENTRY_DSN | `$(SENTRY_DSN)` |
| GoogleOAuthClientID | `$(GOOGLE_OAUTH_CLIENT_ID)` |

Note: a `$(SENTRY_DSN)` containing `//` needs the `Secrets.xcconfig` escaping
already shown in the example file. Build once, confirm the app still reads the
keys (add a temporary print if unsure).

### 5d. Rotate the Pexels key (it is in git history — treat as compromised)

1. pexels.com → your account → API → regenerate / new key.
2. Put the new key in `Config/Secrets.xcconfig` and the `SECRETS_XCCONFIG` GH secret (4c).
3. Old key stays in history but is now dead. (RevenueCat/Amplitude/Google iOS client IDs are public-by-design; rotate only if you want, but Pexels is a real secret.)

---

## 6. Provision the server (Terraform + HCP)

You have an hcloud token but no HCP workspace yet. Two options — HCP is what the
config expects.

### 6a. HCP Terraform (matches versions.tf `cloud {}` block)

1. app.terraform.io → sign up (free) → create organization **norviq**.
2. Create workspace **norviq-prod**, type **CLI-driven**.
3. Workspace → Settings → General → **Execution Mode: Local** (so the hcloud token stays on your machine).
4. Locally:

```bash
cd ~/Projects/StockProject/norviq-infra/terraform
terraform login                      # paste an HCP user token
export TF_VAR_hcloud_token='<your-hcloud-token>'
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
export TF_VAR_admin_cidrs='["<your-public-ip>/32"]'   # curl ifconfig.me
terraform init
terraform plan
terraform apply
terraform output server_ipv4
```

### 6b. If you would rather skip HCP: use local state

Replace the `cloud {}` block in `terraform/versions.tf` with nothing (default
local state), then `terraform init -migrate-state`. State file lives on your
disk — back it up. Simpler, but no locking/remote history.

---

## 7. Bootstrap the cluster (after apply)

```bash
IP=$(terraform -chdir=terraform output -raw server_ipv4)

# kubeconfig
ssh root@$IP 'cat /etc/rancher/k3s/k3s.yaml' | sed "s/127.0.0.1/$IP/" > ~/.kube/norviq
export KUBECONFIG=~/.kube/norviq
kubectl get nodes            # should be Ready

# ArgoCD core + app-of-apps
kubectl apply -k ~/Projects/StockProject/norviq-infra/cluster/argocd
kubectl -n argocd rollout status deploy/argocd-repo-server
kubectl apply -f ~/Projects/StockProject/norviq-infra/argocd/root.yaml
```

---

## 8. Seal secrets (needs kubeseal + the cluster from step 7)

```bash
brew install kubeseal age
# example: postgres credentials
kubectl create secret generic postgres-credentials -n data \
  --from-literal=POSTGRES_USER=stockplan_user \
  --from-literal=POSTGRES_PASSWORD='<strong>' \
  --dry-run=client -o yaml \
  | kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system -o yaml \
  > ~/Projects/StockProject/norviq-infra/secrets/data/postgres-credentials.yaml
```

Repeat for every entry in `secrets/README.md` (api-env staging+prod, web-env,
web-staging-htpasswd, backup-config, grafana-cloud). Commit + push; ArgoCD applies.

### Grafana Cloud secret (account already created)

Grafana Cloud → your stack → Connections. Grab the remote-write/OTLP endpoints,
usernames (instance IDs), and one **Access Policy token** with metrics/logs/traces write:

```bash
kubectl create secret generic grafana-cloud -n observability \
  --from-literal=PROM_URL='https://<...>/api/prom/push' \
  --from-literal=PROM_USER='<mimir-instance-id>' \
  --from-literal=LOKI_URL='https://<...>/loki/api/v1/push' \
  --from-literal=LOKI_USER='<loki-instance-id>' \
  --from-literal=TEMPO_URL='<tempo-otlp-grpc-endpoint>:443' \
  --from-literal=TEMPO_USER='<tempo-instance-id>' \
  --from-literal=GC_API_KEY='<access-policy-token>' \
  --dry-run=client -o yaml \
  | kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system -o yaml \
  > ~/Projects/StockProject/norviq-infra/secrets/observability/grafana-cloud.yaml
```

### BACK UP THE SEALING KEY (do not skip)

```bash
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  | age -r <your-age-pubkey> -o ~/norviq-sealing-key.age
# store off-site + password manager
```

---

## 9. Storage Box + backups (Phase 0 safety can run on the OLD box today)

1. Hetzner console → order **Storage Box BX11**.
2. Configure an rclone SFTP remote named `storagebox` (`rclone config`).
3. Generate the age keypair for backups: `age-keygen -o ~/keys/norviq-backup.agekey`
   (private stays offline; public goes into the `backup-config` sealed secret).
4. On the **current live box** now, cron the fixed scripts (from norviq-backend):
   ```
   30 3 * * * cd /opt/stockplan && GPG_PASSPHRASE_FILE=/root/.stockplan-backup-pass \
     ./scripts/ops/backup_postgres.sh && ./scripts/ops/backup_retention.sh && \
     ./scripts/ops/backup_offsite.sh >> /var/log/stockplan-backup.log 2>&1
   ```
5. Lower DNS TTLs (api.norviqa.io, norviq.org, www.norviq.org) to 300s.
```
