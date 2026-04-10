# StockPlanBackend Deployment Guide

This guide covers deploying the StockPlanBackend Vapor application to a production server.

## Recommended Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         VPS Server                          │
│                                                             │
│   ┌─────────────┐      ┌─────────────┐     ┌─────────────┐ │
│   │    Caddy    │──────│  Vapor App  │─────│  PostgreSQL │ │
│   │   (HTTPS)   │:8080 │   (Docker)  │     │   (Docker)  │ │
│   └─────────────┘      └─────────────┘     └─────────────┘ │
│         │                                                   │
│         │ :443                                              │
└─────────│───────────────────────────────────────────────────┘
          │
    Internet (api.yourdomain.com)
```

## Key Decisions

| Decision | Recommendation | Reason |
|----------|----------------|--------|
| **Docker Compose** | ✅ Yes, for both app and DB | Simplified deployment, easy migrations, consistent environments |
| **Reverse Proxy** | ✅ Caddy | Automatic HTTPS with Let's Encrypt, simpler config than nginx |
| **Domain vs IP** | ✅ Use a domain | Required for HTTPS, professional, enables CDN/WAF later |

---

## Prerequisites

- VPS with Ubuntu 22.04+ (Hetzner, DigitalOcean, etc.)
- Domain name with DNS access (e.g., `api.stockplan.app`)
- SSH access to your server

## Step 1: Server Setup

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER

# Install Caddy
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install caddy

# Log out and back in for docker group to take effect
```

## Step 2: DNS Configuration

Point your domain to your server IP:

```
Type: A
Name: api (or @ for root)
Value: YOUR_SERVER_IP
TTL: 300
```

## Step 3: Clone and Configure

```bash
# Clone your repository
git clone https://github.com/yourusername/StockPlanBackend.git
cd StockPlanBackend

# Create production environment file
cp .env.production .env
```

Edit `.env` with production values:

```bash
# .env
DATABASE_HOST=db
DATABASE_NAME=stockplan_prod
DATABASE_USERNAME=stockplan_user
DATABASE_PASSWORD=<STRONG_RANDOM_PASSWORD>   # Use: openssl rand -base64 32
JWT_SECRET=<STRONG_RANDOM_SECRET>            # Use: openssl rand -base64 64
APP_IMAGE=ghcr.io/yourusername/StockPlanBackend:latest   # overwritten by CI deploy with immutable SHA tag
LOG_LEVEL=info
```

> [!CAUTION]
> Never commit production secrets to git. Use `openssl rand -base64 32` to generate secure passwords.

## Step 4: Production Docker Compose

The project includes `docker-compose.production.yml` with Caddy, the Vapor app, and PostgreSQL properly configured.

Key features:
- **Caddy** handles HTTPS automatically via Let's Encrypt
- **Network isolation** — database is not exposed externally  
- **Health checks** — app waits for database to be ready
- **Environment-based domain** — set `DOMAIN` in `.env`
- **Image-only runtime** — `app` and `migrate` require `APP_IMAGE`; production compose never builds on the server

> [!NOTE]
> The `app` service uses `expose` instead of `ports` to keep port 8080 internal-only. Caddy handles external traffic on ports 80/443.

## Step 5: Caddy Configuration

The `Caddyfile` in the project root configures:
- Reverse proxy to the Vapor app
- Security headers (X-Frame-Options, X-Content-Type-Options, etc.)
- Gzip/Zstd compression
- JSON logging

> [!TIP]
> Caddy automatically obtains and renews HTTPS certificates from Let's Encrypt. No manual certificate management needed.

## Step 6: Deploy

```bash
# Use immutable image tag produced by CI (example tag shown)
export APP_IMAGE=ghcr.io/yourusername/StockPlanBackend:$(git rev-parse HEAD)

# Pull the exact image to deploy
docker pull "$APP_IMAGE"

# Start the database first
docker compose -f docker-compose.production.yml up -d db

# Run migrations
docker compose -f docker-compose.production.yml run --rm migrate

# Start/update the app
docker compose -f docker-compose.production.yml up -d app

# Restart Caddy to load new config
sudo systemctl reload caddy
```

## Step 7: Verify Deployment

```bash
# Check containers are running
docker compose -f docker-compose.production.yml ps

# Check app logs
docker compose -f docker-compose.production.yml logs -f app

# Test the API
curl https://api.yourdomain.com/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"Password123"}'
```

## Additional Guides

- Local packaging workflow (Point 3): `docs/deployment/local-container-workflow.md`
- Operations hardening runbook (Point 4): `docs/deployment/operations-runbook.md`

---

### CI/CD Deployment

Deployments are automated via GitHub Actions (`.github/workflows/deploy.yml`).

**On every push to `main`:**
1. Builds and pushes an immutable image tag to GHCR
2. Updates `latest` to the same artifact
3. SSHs to production server
4. Pulls that exact immutable image (`APP_IMAGE`)
5. Runs migrations from the same image
6. Restarts app with zero-downtime
7. Gates deploy on `/health` before success
8. Persists deployed `APP_IMAGE` in `.env` for future compose commands

**Build strategy:**
- Default strategy is Swift Container Plugin (`build-container-image`) with `x86_64-swift-linux-musl`.
- Rollback strategy is available via workflow dispatch input: `build_strategy=dockerfile`.

**Required GitHub Secrets** (Settings → Secrets → Actions):

| Secret | Description |
|--------|-------------|
| `SERVER_HOST` | Your server IP or hostname |
| `SERVER_USER` | SSH username (e.g., `deploy`) |
| `SERVER_SSH_KEY` | Private SSH key for server access |
| `GITHUB_TOKEN` | Built-in token (already available in Actions) for GHCR push/pull |

> [!TIP]
> Create a dedicated deploy user on the server with Docker access:
> ```bash
> sudo adduser deploy
> sudo usermod -aG docker deploy
> ```

**Manual deployment** (if needed):
```bash
gh workflow run deploy

# Trigger Dockerfile fallback build path explicitly
gh workflow run deploy -f build_strategy=dockerfile
```

### Viewing Logs

```bash
# App logs
docker compose -f docker-compose.production.yml logs -f app

# Database logs
docker compose -f docker-compose.production.yml logs -f db

# Caddy logs
sudo tail -f /var/log/caddy/api.log
```

### Database Backups

```bash
# Create backup
docker compose -f docker-compose.production.yml exec db \
  pg_dump -U stockplan_user stockplan_prod > backup_$(date +%Y%m%d).sql

# Restore backup
cat backup_20260207.sql | docker compose -f docker-compose.production.yml exec -T db \
  psql -U stockplan_user stockplan_prod
```

### Rollback Migrations

```bash
docker compose -f docker-compose.production.yml run --rm app migrate --revert --yes
```

### Rollback Application Image

```bash
# Redeploy a previous known-good immutable image
export APP_IMAGE=ghcr.io/yourusername/StockPlanBackend:<previous_git_sha>
docker pull "$APP_IMAGE"
docker compose -f docker-compose.production.yml up -d --no-deps app
```

### Image Retention and Cleanup Policy

- GHCR: keep immutable SHA tags for rollback history; apply package retention rules in GHCR settings.
- Server: run periodic cleanup to remove stale layers:

```bash
docker image prune -af --filter "until=168h"
```

---

## Why Caddy Over Nginx?

| Feature | Caddy | Nginx |
|---------|-------|-------|
| Automatic HTTPS | ✅ Built-in | ❌ Requires certbot setup |
| Configuration | Simple Caddyfile | Complex nginx.conf |
| Certificate Renewal | Automatic | Cron job required |
| HTTP/2 & HTTP/3 | Default | Manual configuration |
| Performance | Excellent | Excellent |

For a straightforward API backend, Caddy significantly reduces operational complexity.

## Why Use a Domain?

1. **HTTPS Required**: Modern iOS/Android apps require HTTPS. Self-signed certs cause issues.
2. **Mobility**: Change servers without updating client apps.
3. **CDN Ready**: Easy to add Cloudflare or similar later.
4. **Professionalism**: `api.stockplan.app` > `93.184.216.34:8080`

---

## Troubleshooting

### Container won't start
```bash
docker compose -f docker-compose.production.yml logs app
```

### Database connection refused
Ensure DB is healthy before starting app:
```bash
docker compose -f docker-compose.production.yml ps db
```

### Caddy certificate errors
Check domain DNS is propagated:
```bash
dig api.yourdomain.com
```

### Port 443 already in use
Stop conflicting service:
```bash
sudo lsof -i :443
sudo systemctl stop apache2  # or whatever is using it
```
