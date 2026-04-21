# StockPlanBackend Deployment Guide

This guide covers deploying the StockPlanBackend Vapor application to a production server, including CI/CD configuration.

## Recommended Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         VPS Server                          │
│                                                             │
│   ┌─────────────┐      ┌─────────────┐     ┌─────────────┐ │
│   │    Nginx    │──────│  Vapor App  │─────│  PostgreSQL │ │
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
| **Reverse Proxy** | ✅ Nginx | Battle-tested proxy and HTTPS with Let's Encrypt |
| **Domain vs IP** | ✅ Use a domain | Required for HTTPS, professional, enables CDN/WAF later |

---

## 1. Server Provisioning (One-Time Setup)

### Prerequisites
- VPS with Ubuntu 22.04+ (Hetzner, DigitalOcean, etc.)
- Domain name with DNS access (e.g., `api.stockplan.app`)
- SSH access to your server

### Install Dependencies

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER

# Install Nginx, Certbot, and Supervisor
sudo apt install -y nginx certbot python3-certbot-nginx supervisor

# Log out and back in for docker group to take effect
```

### Domain & DNS Setup (Namecheap to Hetzner)

Before configuring Nginx, ensure your domain points to your Hetzner machine:
1. Find your Hetzner server's public IPv4 address.
2. In your Namecheap dashboard, navigate to **Advanced DNS** for your domain.
3. Add an `A Record` for your API (e.g., Host: `api`, Value: `YOUR_HETZNER_IP`).
4. Wait for DNS to propagate (can take a few minutes to hours).

### TLS (HTTPS) Certificates

Generate your Let's Encrypt certificates using Certbot. This requires your DNS to be pointing to the Hetzner machine.

```bash
sudo certbot certonly --nginx -d api.yourdomain.com
```

### Nginx Configuration

The configuration files for enabled sites can be found in `/etc/nginx/sites-enabled/`. Create a new file at `/etc/nginx/sites-available/stockplan` and symlink it to `/etc/nginx/sites-enabled/stockplan`.

```nginx
# Redirect all HTTP traffic to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name api.yourdomain.com;

    return 301 https://$host$request_uri;
}

# Main HTTPS Server Block
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name api.yourdomain.com;

    ssl_certificate /etc/letsencrypt/live/api.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.yourdomain.com/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    # (Optional) Generate dhparam: sudo openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048
    ssl_dhparam /etc/ssl/certs/dhparam.pem;
    ssl_ciphers 'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256...'; # See full list in best practices
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_stapling on;
    ssl_stapling_verify on;
    add_header Strict-Transport-Security max-age=15768000;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy no-referrer always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()" always;

    location / {
        try_files $uri @proxy;
    }

    location @proxy {
        proxy_pass http://127.0.0.1:8080;
        proxy_pass_header Server;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_connect_timeout 3s;
        proxy_read_timeout 10s;
    }
}
```

Restart Nginx:
```bash
sudo systemctl restart nginx
```

---

## 2. Application Configuration

### Clone and Configure

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
DATABASE_USERNAME=<NON_DEFAULT_DB_USER>
DATABASE_PASSWORD=<STRONG_RANDOM_PASSWORD>   # Use: openssl rand -base64 32
JWT_SECRET=<STRONG_RANDOM_SECRET>            # Use: openssl rand -base64 64
ALLOWED_ORIGINS=https://www.norviqaapp.com,https://norviqaapp.com
USER_PII_ENCRYPTION_ACTIVE_KEY_ID=prod-v1
USER_PII_ENCRYPTION_ACTIVE_KEY=<BASE64_32_BYTE_KEY>
REDIS_URL=redis://redis:6379
RESEND_API_KEY=<RESEND_KEY>
RESEND_FROM_EMAIL=no-reply@yourdomain.com
APP_IMAGE=ghcr.io/yourusername/StockPlanBackend:latest
LOG_LEVEL=info
LOG_FORMAT=json
OBS_TRACES_ENABLED=true
OBS_SERVICE_NAME=StockPlanBackend
OBS_ENVIRONMENT=production
OBS_OTLP_ENDPOINT=http://otel-collector:4317
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
GRAFANA_ADMIN_PASSWORD=<STRONG_RANDOM_PASSWORD>
GRAFANA_SMTP_ENABLED=true
GRAFANA_ALERT_EMAIL_TO=alerts@example.com
GRAFANA_ALERT_EMAIL_FROM=alerts@example.com
GRAFANA_SMTP_HOST=smtp.example.com:587
GRAFANA_SMTP_USER=<SMTP_USER>
GRAFANA_SMTP_PASSWORD=<SMTP_PASSWORD>
GRAFANA_SLACK_WEBHOOK_URL=<SLACK_WEBHOOK_URL>
```

Production startup fails if `JWT_SECRET` is missing, blank, shorter than 32 characters, or equal to the development default. Production startup also fails if `ALLOWED_ORIGINS` is missing or contains localhost/wildcard origins.

Use a non-default database username and password in production. Keep Postgres and Redis on the Docker internal network only; neither service should publish host ports.

### Production Docker Compose

The project includes `docker-compose.production.yml` with the Vapor app and PostgreSQL.

Key features:
- **Network isolation** — database is not exposed externally  
- **Health checks** — app waits for database to be ready
- **Image-only runtime** — `app` and `migrate` require `APP_IMAGE`; production compose never builds on the server

> [!NOTE]
> The `app` service uses `ports` to expose port 8080 locally to the host (`127.0.0.1:8080:8080`). Nginx handles external traffic on ports 80/443 and proxies to this internal port.

### Start the Application (Initial Manual Deployment)

```bash
export APP_IMAGE=ghcr.io/yourusername/StockPlanBackend:$(git rev-parse HEAD)

docker pull "$APP_IMAGE"
docker compose -f docker-compose.production.yml up -d db
docker compose -f docker-compose.production.yml run --rm migrate
docker compose -f docker-compose.production.yml up -d app
docker compose -f docker-compose.production.yml -f docker-compose.observability.yml up -d
./scripts/ops/production_preflight.sh api.norviqa.io https://www.norviqaapp.com
```

---

## 3. CI/CD Pipeline Configuration

### Current Production Pipeline (GitHub Actions)

Deployments are automated via GitHub Actions (`.github/workflows/deploy.yml`).

**On every push to `main`:**
1. Builds and pushes an immutable image tag to GHCR
2. Updates `latest` to the same artifact
3. SSHs to production server
4. Pulls that exact immutable image (`APP_IMAGE`)
5. Runs migrations from the same image
6. Restarts app with zero-downtime
7. Gates deploy on `/health/ready` before success, with `/health` as rollback compatibility fallback
8. Persists deployed `APP_IMAGE` in `.env` for future compose commands

After a deploy, run `./scripts/ops/production_preflight.sh <domain> <allowed-origin>` from the server and paste the output into the release notes. This confirms health, request IDs, CORS, security headers, private DB/Redis exposure, and JSON log shape.

**Required GitHub Secrets** (Settings → Secrets → Actions):

| Secret | Description |
|--------|-------------|
| `SERVER_HOST` | Your server IP or hostname |
| `SERVER_USER` | SSH username (e.g., `deploy`) |
| `SERVER_SSH_KEY` | Private SSH key for server access |
| `GITHUB_TOKEN` | Built-in token (already available in Actions) |

> [!TIP]
> Create a dedicated deploy user on the server with Docker access:
> ```bash
> sudo adduser deploy
> sudo usermod -aG docker deploy
> ```

### Hetzner Sizing Baseline

- `CX23` (`2 vCPU / 4 GB RAM / 40 GB SSD`) is an acceptable baseline for one API node + Nginx + Postgres in low/medium early production traffic.
- Scale triggers: sustained RAM pressure, p95 latency drift, disk growth. First upgrade path is usually more RAM.

### Build Artifact Hygiene

When SwiftPM checkout artifacts get stale, clear them locally:

```bash
swift package reset
rm -rf .build
```

---

## 4. Alternative CI/CD Providers (GitLab Migration Strategy)

If migrating the Swift full-stack project (monorepo) from GitHub to GitLab:

### Advantages
1. **Superior, Built-in CI/CD:** Visual pipeline graph makes troubleshooting multi-stage builds easier.
2. **Integrated Container Registry:** Robust, built-in registry (`registry.gitlab.com`).

### Disadvantages
1. **macOS Runner Costs:** Building `StockPlanIOSApp` requires macOS runners, which consume SaaS minutes quickly.
2. **Migration Overhead:** Requires rewriting `.github/workflows` to `.gitlab-ci.yml`.

### Migration Steps
1. **Create GitLab Project** and push code (`git push -u origin main`).
2. **Delete GitHub Actions:** `rm -rf .github/workflows`.
3. **Create `.gitlab-ci.yml`** replicating the test and build stages.
4. **Move Secrets** to GitLab's **Settings > CI/CD > Variables**.
5. **Update Docker scripts** to pull from `registry.gitlab.com`.

---

## 5. Operations & Runbook

### Viewing Logs

```bash
# App logs
docker compose -f docker-compose.production.yml logs -f app

# Database logs
docker compose -f docker-compose.production.yml logs -f db

# Nginx logs
sudo tail -f /var/log/nginx/error.log
sudo tail -f /var/log/nginx/access.log
```

### Database Backups

```bash
# Create backup
./scripts/ops/backup_postgres.sh

# Restore backup
RESTORE_DATABASE_URL=postgres://restore_user:restore_password@restore-host:5432/stockplan_restore \
  ./scripts/ops/restore_drill_postgres.sh backups/stockplan_YYYYMMDD_HHMMSS.sql.gpg
```

Run a restore drill before launch and at least quarterly after launch. Keep daily encrypted backups for 14 days, weekly backups for 8 weeks, and monthly backups for 12 months unless your privacy/retention policy requires a shorter window.

### Rollback Strategy

```bash
# Rollback Migrations
docker compose -f docker-compose.production.yml run --rm app migrate --revert --yes

# Rollback Application Image (Redeploy previous known-good image)
export APP_IMAGE=ghcr.io/yourusername/StockPlanBackend:<previous_git_sha>
docker pull "$APP_IMAGE"
docker compose -f docker-compose.production.yml up -d --no-deps app
```

### Image Retention and Cleanup Policy

Run periodic cleanup to remove stale layers on the server:

```bash
docker image prune -af --filter "until=168h"
```

### Troubleshooting

- **Container won't start:** `docker compose -f docker-compose.production.yml logs app`
- **Database connection refused:** `docker compose -f docker-compose.production.yml ps db`
- **Nginx certificate errors:** `dig api.yourdomain.com`
- **Port 443 already in use:** `sudo lsof -i :443` then `sudo systemctl stop apache2`
