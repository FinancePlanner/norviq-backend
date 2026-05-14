# Inject Apple OAuth + APNS Secrets into CI/CD Pipeline

**Date:** 2026-05-13
**Goal:** Fix App Store rejection (Guideline 2.1a — "Continue with Apple" crashes) by injecting Apple OAuth and APNS secrets into the production server, both immediately and through the CI/CD pipeline.

---

## Current Context

- **Root cause:** `.env.production` on the server has all 4 Apple OAuth vars empty, plus APNS vars empty.
- **CI/CD gap:** `deploy.yml` only passes SSH credentials + Grafana webhook URLs. It never injects OAuth/APNS secrets into the server's `.env.production`.
- **Impact:** Apple Sign-In is completely disabled in production. Apple reviewers see an error when tapping "Continue with Apple".
- **Symlink:** `.env` → `.env.production` is set up by the deploy script (`ln -sf /opt/stockplan/.env.production /opt/stockplan/.env`), but currently `.env` is pointing at `.env.development`.

---

## Phase 1 — Immediate fix on the server (SSH injection)

### 1.1 Update `.env.production` on the server

Via SSH, replace the empty values in `/opt/stockplan/.env.production` for these variables:

| Variable | Value |
|----------|-------|
| `APNS_TEAM_ID` | `84X9WYBF36` |
| `APNS_KEY_ID` | `WP8NG28N63` |
| `APNS_PRIVATE_KEY_P8` | `"-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg3+LqaSbG+KQLmTFCZ4eTi4H0qD/YJ6J6GDkae8p5zSOgCgYIKoZIzj0DAQehRANCAARBCG7g0Tg2pOCGzhcTQ6dwrPb0+PLqhk87ZSpb8xSRjAWEETwAFa1UmguiB5p83q+RXag6QZx00in9ykhm+Iyl\n-----END PRIVATE KEY-----"` |
| `APNS_TOPIC` | `facorreia.financeplan` |
| `OAUTH_APPLE_CLIENT_ID` | `facorreia.financeplan` |
| `OAUTH_APPLE_TEAM_ID` | `84X9WYBF36` |
| `OAUTH_APPLE_KEY_ID` | `BV4PBRXTZ3` |
| `OAUTH_APPLE_PRIVATE_KEY` | `"-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQgOaYZL7SaP7GMbT19yT+VgH6DGpF5vOMe8HvyKZo/xTOgCgYIKoZIzj0DAQehRANCAAQVVfzsqao1kcW3XXpP6X/mtF7Vp2ZjPoZbQFEj7QX21L/MY4hE07nlXRYaMmk3Mxt/H0op0KQiQ/I7QrHtDhms\n-----END PRIVATE KEY-----"` |
| `BILLING_PREMIUM_EMAILS` | `testemail12345678@email.com` |
| `BYPASS_BILLING` | `true` |
| `REVENUECAT_API_KEY` | `sk_HEJTcPFiLTipIaSqddoOSunQuAOTLL` |
| `REVENUECAT_WEBHOOK_SECRET` | `aDcRhXETamXkw0Us2xdjpoW14msZETwP9eVnslMOWNM` |
| `DISCORD_WEBHOOK_URL` | `https://discord.com/api/webhooks/1500153981937389568/Rw8qmmPMxxL4X1vAgy8B-E9FqlBwnG4dITCDOY4YwbQsP_5lO5SYC2hmzMjmPRbPAKq_` |
| `ACME_EMAIL` | `fernandocorreia316@gmail.com` |

Also verify existing values for Google, X, and DATABASE vars are intact.

### 1.2 Ensure `.env.production` is the active file

The deploy script does `ln -sf /opt/stockplan/.env.production /opt/stockplan/.env`.
Run this on the server to re-create the symlink pointing at `.env.production`.

### 1.3 Restart the prod app container

```bash
APP_PORT=8080 APP_IMAGE=$(grep APP_IMAGE .env.production | cut -d= -f2) \
  docker compose -p prod -f docker-compose.production.yml --env-file .env.production up -d --force-recreate app
```

### 1.4 Verify Apple OAuth is active

```bash
docker compose -p prod -f docker-compose.production.yml --env-file .env.production logs --tail=30 app
```

Look for absence of "Apple OAuth is disabled" or "APNS is disabled" warnings. A healthy log should still show warnings if something is misconfigured — absence of those means Apple OAuth started correctly.

---

## Phase 2 — Permanent CI/CD fix (GitHub Actions secret injection)

### 2.1 Add GitHub Actions secrets

In **GitHub → StockPlanBackend → Settings → Secrets and variables → Actions**, add these as **Environment secrets** for the `production` environment (matching `environment: production` in deploy.yml, step 69):

| Secret Name | Value |
|---|---|
| `APNS_TEAM_ID` | `84X9WYBF36` |
| `APNS_KEY_ID` | `WP8NG28N63` |
| `APNS_PRIVATE_KEY_P8` | *(multiline PEM as single string with \n)* |
| `APNS_TOPIC` | `facorreia.financeplan` |
| `OAUTH_APPLE_CLIENT_ID` | `facorreia.financeplan` |
| `OAUTH_APPLE_TEAM_ID` | `84X9WYBF36` |
| `OAUTH_APPLE_KEY_ID` | `BV4PBRXTZ3` |
| `OAUTH_APPLE_PRIVATE_KEY` | *(multiline PEM as single string with \n)* |
| `BILLING_PREMIUM_EMAILS` | `testemail12345678@email.com` |
| `REVENUECAT_API_KEY` | `sk_HEJTcPFiLTipIaSqddoOSunQuAOTLL` |
| `REVENUECAT_WEBHOOK_SECRET` | `aDcRhXETamXkw0Us2xdjpoW14msZETwP9eVnslMOWNM` |
| `DISCORD_WEBHOOK_URL` | *(existing webhook URL, already stored in Grafana secrets)* |
| `ACME_EMAIL` | `fernandocorreia316@gmail.com` |

> **PEM key formatting tip:** GitHub Actions secrets store values as raw strings. For PEM keys, use the escaped form with `\n` for newlines (same as currently expected by `OAuthProviderClient.swift` line 205: `privateKeyPEMRaw.replacingOccurrences(of: "\\n", with: "\n")`).

### 2.2 Modify `.github/workflows/deploy.yml`

Add a new step **between** "Checkout" and "Deploy to server" (after line 85, before line 87) that injects these secrets into `.env.production` on the server:

```yaml
      - name: Inject Apple OAuth + APNS secrets into .env.production
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SERVER_SSH_KEY }}
          script: |
            set -euo pipefail
            cd /opt/stockplan
            
            # Function: update or append a key in .env.production
            set_env_var() {
              local key="$1"
              local value="$2"
              if grep -q "^${key}=" .env.production 2>/dev/null; then
                # Escape forward slashes and pipe characters in the value for sed
                local escaped_value
                escaped_value=$(printf '%s\n' "$value" | sed 's/[\/&|]/\\&/g')
                sed -i "s|^${key}=.*|${key}=${escaped_value}|" .env.production
              else
                echo "${key}=${value}" >> .env.production
              fi
            }
            
            set_env_var "APNS_TEAM_ID" "${{ secrets.APNS_TEAM_ID }}"
            set_env_var "APNS_KEY_ID" "${{ secrets.APNS_KEY_ID }}"
            set_env_var "APNS_PRIVATE_KEY_P8" "${{ secrets.APNS_PRIVATE_KEY_P8 }}"
            set_env_var "APNS_TOPIC" "${{ secrets.APNS_TOPIC }}"
            set_env_var "OAUTH_APPLE_CLIENT_ID" "${{ secrets.OAUTH_APPLE_CLIENT_ID }}"
            set_env_var "OAUTH_APPLE_TEAM_ID" "${{ secrets.OAUTH_APPLE_TEAM_ID }}"
            set_env_var "OAUTH_APPLE_KEY_ID" "${{ secrets.OAUTH_APPLE_KEY_ID }}"
            set_env_var "OAUTH_APPLE_PRIVATE_KEY" "${{ secrets.OAUTH_APPLE_PRIVATE_KEY }}"
            set_env_var "BILLING_PREMIUM_EMAILS" "${{ secrets.BILLING_PREMIUM_EMAILS }}"
            set_env_var "REVENUECAT_API_KEY" "${{ secrets.REVENUECAT_API_KEY }}"
            set_env_var "REVENUECAT_WEBHOOK_SECRET" "${{ secrets.REVENUECAT_WEBHOOK_SECRET }}"
            set_env_var "ACME_EMAIL" "${{ secrets.ACME_EMAIL }}"
```

**Why this approach:**
- Uses the same `appleboy/ssh-action` already in the pipeline (no new dependencies)
- Updates existing keys in-place via `sed` (preserves other variables)
- Runs before the Docker Compose deploy step (so secrets are in `.env.production` before app restarts)
- Uses `set -euo pipefail` so a missing secret fails the deploy immediately

### 2.3 Risk: PEM keys with spaces and newlines in YAML

The `OAUTH_APPLE_PRIVATE_KEY` contains spaces (after "BEGIN PRIVATE") and `\n` escape sequences. When passed through `${{ secrets.X }}` into a bash `set_env_var` function:
- GitHub Actions secrets are injected at parse time, before bash
- The `\n` characters are literal backslash-n strings (which the app's `.replacingOccurrences(of: "\\n", with: "\n")` expects)
- However, if the YAML hered/script parsing splits on real newlines, this could break
- **Mitigation:** Store the PEM in GitHub as a single-line value with `\n` escape sequences (no real newlines). This matches the format `OAuthProviderClient.swift` already expects.

---

## Files to Change

| File | Change |
|------|--------|
| `.github/workflows/deploy.yml` | Add secret injection step before deploy |
| Server `/opt/stockplan/.env.production` | Updated via SSH (Phase 1) then via CI/CD (Phase 2) |
| Server `/opt/stockplan/.env` symlink | Pointed at `.env.production` |

---

## Validation

1. **After Phase 1:** `docker compose -p prod ... logs --tail=30 app` shows no "Apple OAuth is disabled" warning
2. **After Phase 2:** Push to `main`, verify the CI/CD pipeline completes successfully. The new secret injection step should complete before the deploy step.
3. **App Store:** Resubmit build. Apple reviewers should be able to complete "Continue with Apple" without error.
4. **APNS verification:** Send a test push notification to confirm the APNS private key works in production.

---

## Risks & Caveats

- **PEM key whitespace:** The user-supplied `OAUTH_APPLE_PRIVATE_KEY` value has real newlines/spaces in the middle of the PEM string. GitHub Actions may interpret these as YAML line breaks. Ensure the secret is stored as a single line with `\n` escapes.
- **Google/X secrets:** These are currently set on the server but NOT in GitHub secrets. They won't be overwritten by the new step (it only touches the new variables). However, if someone runs `git reset --hard` on the server, the `.env.production` file from git (with empty values) would wipe them. **Recommendation:** Also add Google/X/DB vars as GitHub secrets for completeness.
- **Symlink drift:** The deploy script re-creates the symlink each run. If Phase 1 only updates `.env.production` but the server's `.env` still points at `.env.development`, the running app won't see the changes until `.env` is re-linked.
