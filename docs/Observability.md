# Observability

This document records what is currently implemented for `StockPlanBackend`, how to test it locally and in production, and which self-hosted observability backends are viable if the current stack needs to grow.

## What Is Implemented

The backend now has a first-pass OpenTelemetry-based observability stack for a Docker Compose deployment:

- App-side telemetry is wired with `swift-otel` in `Package.swift`.
- `Sources/StockPlanBackend/entrypoint.swift` bootstraps OpenTelemetry when `OBS_TRACES_ENABLED=true`.
- OpenTelemetry log export is intentionally disabled in `entrypoint.swift` so the app keeps the existing Vapor/SwiftLog JSON logging bootstrap. This avoids double-bootstrapping `LoggingSystem`.
- `TracingMiddleware` and `app.traceAutoPropagation = true` are enabled in `Sources/StockPlanBackend/configure.swift`.
- `RequestLoggingMiddleware` emits structured request metadata: request ID, method, path, status, latency, user ID when authenticated, and inbound trace context when present.
- Production defaults use JSON logs through `LOG_FORMAT=json`.
- `monitoring/otel-collector.yaml` defines an OpenTelemetry Collector with:
  - OTLP gRPC receiver on `4317`.
  - OTLP HTTP receiver on `4318`.
  - `hostmetrics` receiver for CPU, memory, disk, filesystem, load, and network metrics.
  - `memory_limiter` and `batch` processors.
  - Trace export to Jaeger.
  - Metrics export through the Collector Prometheus exporter on `9464`.
- `docker-compose.observability.yml` adds:
  - `otel-collector`
  - `jaeger`
  - `grafana`
- Grafana is bound to `127.0.0.1:3000:3000`, so it is not publicly exposed by Compose.
- Grafana provisioning exists for:
  - Jaeger datasource.
  - Collector metrics datasource.
  - Baseline dashboard.
  - Baseline alert rules.
  - Email and Slack contact points.
- `.env.production` documents the required observability env vars:
  - `OBS_TRACES_ENABLED`
  - `OTEL_SERVICE_NAME`
  - `OTEL_RESOURCE_ATTRIBUTES`
  - `OTEL_EXPORTER_OTLP_ENDPOINT`
  - `OTEL_EXPORTER_OTLP_PROTOCOL`
  - Grafana admin, SMTP, email alert, and Slack webhook settings.

## Important Limitations

The current stack is enough for launch smoke testing and incident triage, but it is not a full long-retention observability platform yet.

- Traces are stored in Jaeger all-in-one. That is simple, but not the best long-term production trace store.
- Metrics are exposed by the Collector Prometheus exporter and queried by Grafana. There is no durable Prometheus, Mimir, VictoriaMetrics, or ClickHouse metrics store yet.
- App logs are structured JSON in container logs, but they are not centralized in Loki, OpenObserve, SigNoz, Uptrace, or ClickStack yet.
- Alert expressions are baseline expressions and must be validated against real metric names emitted by the deployed app and collector.
- The stack runs on the same node as the app in the default Compose setup. That is acceptable for MVP, but move it to another node if CPU, memory, or disk pressure affects API latency.

## Local Test Procedure

Use this path when you want the app container and observability services to communicate on the same Docker network, matching production most closely.

1. Create or update local env:

```bash
cp .env.production .env
```

Set local-safe values in `.env`:

```text
APP_IMAGE=stockplanbackend:observability-local
DATABASE_USERNAME=stockplan_local_observability
DATABASE_PASSWORD=replace-this-with-at-least-24-characters
DATABASE_NAME=stockplan_observability
JWT_SECRET=replace-this-with-at-least-32-characters
USER_PII_ENCRYPTION_ACTIVE_KEY_ID=local-v1
USER_PII_ENCRYPTION_ACTIVE_KEY=<base64-encoded-32-byte-key>
OBS_TRACES_ENABLED=true
LOG_FORMAT=json
OTEL_SERVICE_NAME=StockPlanBackendLocal
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=local
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=replace-this-with-a-local-password
GRAFANA_ALERT_EMAIL_TO=local@example.com
GRAFANA_ALERT_EMAIL_FROM=local@example.com
GRAFANA_SMTP_HOST=host.docker.internal:1025
GRAFANA_SMTP_USER=local
GRAFANA_SMTP_PASSWORD=local
GRAFANA_SLACK_WEBHOOK_URL=http://localhost:9/unused
```

The SMTP and Slack values above satisfy Grafana provisioning locally. To test email delivery on macOS, run a local SMTP sink such as Mailpit on port `1025` and keep `GRAFANA_SMTP_HOST=host.docker.internal:1025`. To test Slack delivery, replace the unused URL with a real webhook in a staging/private Slack channel.

2. Build a local API image:

```bash
docker build -t stockplanbackend:observability-local .
```

3. Start the production-shaped stack plus observability:

```bash
docker compose -f docker-compose.production.yml -f docker-compose.observability.yml up -d db redis otel-collector jaeger grafana
docker compose -f docker-compose.production.yml -f docker-compose.observability.yml --profile tools run --rm migrate
docker compose -f docker-compose.production.yml -f docker-compose.observability.yml up -d app
```

4. Generate traffic:

```bash
curl -i http://127.0.0.1:8080/health/live
curl -i http://127.0.0.1:8080/health/ready
curl -i http://127.0.0.1:8080/
```

5. Check container health and logs:

```bash
docker compose -f docker-compose.production.yml -f docker-compose.observability.yml ps
docker compose -f docker-compose.production.yml -f docker-compose.observability.yml logs --tail=100 app
docker compose -f docker-compose.production.yml -f docker-compose.observability.yml logs --tail=100 otel-collector
docker compose -f docker-compose.production.yml -f docker-compose.observability.yml logs --tail=100 grafana
```

6. Open Grafana:

```text
http://127.0.0.1:3000
```

Expected local results:

- Grafana accepts the configured admin credentials.
- The Jaeger datasource is provisioned.
- The OTel Collector Metrics datasource is provisioned.
- The StockPlan dashboard is visible.
- App logs show JSON request lines.
- Collector logs show received/exported trace or metric activity after traffic.
- Grafana Explore can query Jaeger for recent traces from `StockPlanBackendLocal`.

## Local Host-Run Swift Alternative

If you run `swift run` on the host instead of running the app in Docker, the host cannot reach `otel-collector:4317` unless the Collector port is exposed. Use a small local override file for that workflow:

```yaml
# docker-compose.observability.local.yml
services:
  otel-collector:
    ports:
      - "127.0.0.1:4317:4317"
      - "127.0.0.1:4318:4318"
```

Start the observability services with the override:

```bash
docker compose -f docker-compose.production.yml -f docker-compose.observability.yml -f docker-compose.observability.local.yml up -d otel-collector jaeger grafana
```

Then run the app with host-reachable OTLP settings:

```bash
OBS_TRACES_ENABLED=true \
OTEL_SERVICE_NAME=StockPlanBackendLocal \
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=local \
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4317 \
OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
LOG_FORMAT=json \
swift run StockPlanBackend serve --hostname 127.0.0.1 --port 8080
```

## Setting Up Slack Alerts

### Step 1 — Create a Slack Incoming Webhook

1. Go to https://api.slack.com/apps and click **Create New App → From scratch**.
2. Name it `StockPlan Alerts`, pick your workspace, click **Create App**.
3. In the left sidebar click **Incoming Webhooks**, toggle it **On**.
4. Click **Add New Webhook to Workspace**, pick your `#alerts` channel (or create one), click **Allow**.
5. Copy the webhook URL — it looks like `https://hooks.slack.com/services/T.../B.../...`.

### Step 2 — Add the webhook to the contact points file

Grafana provisioning files do **not** expand shell environment variables. You must put the URL directly in the file on the server:

```bash
sed -i 's|url: .*|url: https://hooks.slack.com/services/YOUR/WEBHOOK/URL|' \
  /opt/stockplan/monitoring/grafana/provisioning/alerting/contact-points.yaml
```

### Step 3 — Re-enable the contact point provisioning file

```bash
mv /opt/stockplan/monitoring/grafana/provisioning/alerting/contact-points.yaml.disabled \
   /opt/stockplan/monitoring/grafana/provisioning/alerting/contact-points.yaml
```

### Step 4 — Fix the alert rules datasource

The provisioned alert rules currently reference `otel-collector-metrics` as the datasource UID. Update them to use `prometheus` (the fixed datasource UID from the datasources.yaml update):

```bash
sed -i 's/datasourceUid: otel-collector-metrics/datasourceUid: prometheus/g' \
  /opt/stockplan/monitoring/grafana/provisioning/alerting/rules.yaml
```

### Step 5 — Recreate Grafana to pick up all changes

```bash
docker compose -p prod -f docker-compose.production.yml -f docker-compose.observability.yml up -d --force-recreate grafana
docker logs prod-grafana-1 --tail=20
```

Grafana should start cleanly with no errors.

### Step 6 — Verify in Grafana UI

1. Open Grafana via SSH tunnel (`ssh -L 3001:127.0.0.1:3000 root@<server-ip>`) then go to `http://localhost:3001`.
2. Go to **Alerting → Contact points** — you should see `stockplan-slack`.
3. Click the **Test** button next to it — a test message should appear in your Slack channel within seconds.
4. Go to **Alerting → Alert rules** — you should see the `stockplan-production` group with 4 rules.

### Alerts that are configured

| Alert | Severity | Triggers when |
|---|---|---|
| App or collector metrics missing | critical | No metrics reach Grafana for 5 min |
| Sustained high host CPU | warning | CPU > 85% for 10 min |
| Sustained high host memory | warning | Memory > 85% for 10 min |
| Billing webhook errors | critical | RevenueCat webhook returns 5xx |

### Adding more Slack channels

To route different severity alerts to different channels, edit `contact-points.yaml` locally and add another receiver:

```yaml
  - uid: stockplan-slack-critical
    type: slack
    settings:
      url: ${GRAFANA_SLACK_WEBHOOK_URL_CRITICAL:-}
      recipient: "#incidents"
      mentionChannel: here
```

Then add `GRAFANA_SLACK_WEBHOOK_URL_CRITICAL=https://hooks.slack.com/...` to `.env` and push the file to the server.

---

## Production Server Setup (Hetzner / SSH)

This section covers the exact steps to bring up and fix the observability stack on a live server when GitHub Actions is unavailable or containers need manual intervention.

### Starting the full stack

```bash
ssh root@<server-ip>
cd /opt/stockplan

# Start prod app + infra
docker compose -p prod -f docker-compose.production.yml up -d

# Start observability stack
docker compose -p prod -f docker-compose.production.yml -f docker-compose.observability.yml up -d
```

### Updating env vars without a redeploy

`restart` does not reload env files. You must force-recreate the container:

```bash
# Edit the env file
nano /opt/stockplan/.env

# Force-recreate to pick up changes
docker compose -p prod -f docker-compose.production.yml up -d --force-recreate app

# Verify the var is live
docker exec prod-app-1 env | grep YOUR_VAR
```

### Accessing Grafana (SSH tunnel)

Grafana is bound to `127.0.0.1:3000` on the server and is not publicly exposed. Access it via tunnel from your local machine:

```bash
ssh -L 3001:127.0.0.1:3000 root@<server-ip>
```

Then open `http://localhost:3001`. If port 3001 is also taken, use any free local port.

### Resetting the Grafana admin password

```bash
docker exec prod-grafana-1 grafana cli admin reset-admin-password yournewpassword
```

Note: avoid special shell characters like `!` in the password when running via `docker exec` — they can be misinterpreted by the shell.

### Fixing Grafana crash on startup (Slack contact point)

If Grafana crashes with `token must be specified when using the Slack chat API`, the Slack alerting provisioning file is missing a webhook URL. Disable it until you have a real webhook:

```bash
mv /opt/stockplan/monitoring/grafana/provisioning/alerting/contact-points.yaml \
   /opt/stockplan/monitoring/grafana/provisioning/alerting/contact-points.yaml.disabled

docker compose -p prod -f docker-compose.production.yml -f docker-compose.observability.yml up -d --force-recreate grafana
```

To re-enable later, add `GRAFANA_SLACK_WEBHOOK_URL=https://hooks.slack.com/...` to `.env` and rename the file back.

### Verifying Prometheus is scraping

Prometheus runs on the internal Docker network only. Query it via `docker exec`:

```bash
# Check targets are up
docker exec prod-prometheus-1 wget -qO- "http://localhost:9090/api/v1/targets" | python3 -m json.tool | grep health

# List available metric names
docker exec prod-prometheus-1 wget -qO- "http://localhost:9090/api/v1/label/__name__/values" | python3 -m json.tool | head -30
```

`"health": "up"` confirms Prometheus is scraping the OTel Collector successfully.

### Reloading Prometheus config without restart

```bash
docker exec prod-prometheus-1 kill -HUP 1
```

### Pushing updated monitoring files to the server

Run from your local project root:

```bash
cd /path/to/StockPlanBackend

scp monitoring/prometheus.yml root@<server-ip>:/opt/stockplan/monitoring/prometheus.yml
scp monitoring/otel-collector.yaml root@<server-ip>:/opt/stockplan/monitoring/otel-collector.yaml
scp monitoring/grafana/provisioning/datasources/datasources.yaml root@<server-ip>:/opt/stockplan/monitoring/grafana/provisioning/datasources/datasources.yaml
scp monitoring/grafana/provisioning/dashboards/stockplan-production.json root@<server-ip>:/opt/stockplan/monitoring/grafana/provisioning/dashboards/stockplan-production.json
```

Then reload:

```bash
docker exec prod-prometheus-1 kill -HUP 1
docker compose -p prod -f docker-compose.production.yml -f docker-compose.observability.yml up -d --force-recreate grafana
```

### Datasource configuration

The Grafana datasources are provisioned from `monitoring/grafana/provisioning/datasources/datasources.yaml`:

- **Prometheus** (`http://prometheus:9090`) — default datasource for all metrics panels.
- **Jaeger** (`http://jaeger:16686`) — for distributed trace search.

The OTel Collector Prometheus exporter (`:9464`) is scraped by Prometheus, not queried directly by Grafana.

### Checking which Docker networks containers share

If the app cannot reach the OTel Collector (traces not appearing in Jaeger), verify they are on the same network:

```bash
docker inspect prod-app-1 --format '{{json .NetworkSettings.Networks}}' | python3 -m json.tool
docker inspect prod-otel-collector-1 --format '{{json .NetworkSettings.Networks}}' | python3 -m json.tool
```

Both must share `prod_internal`. If the app was started with a different project name it will be on a different network. Always use `-p prod` when starting the prod stack.

---

## Production Test Procedure

1. Set real production env values:

```text
OBS_TRACES_ENABLED=true
LOG_FORMAT=json
OTEL_SERVICE_NAME=StockPlanBackend
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=production
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
GRAFANA_ADMIN_PASSWORD=<strong password>
GRAFANA_ALERT_EMAIL_TO=<ops inbox>
GRAFANA_ALERT_EMAIL_FROM=<verified sender>
GRAFANA_SMTP_HOST=<smtp host:port>
GRAFANA_SMTP_USER=<smtp user>
GRAFANA_SMTP_PASSWORD=<smtp password>
GRAFANA_SLACK_WEBHOOK_URL=<slack webhook>
```

2. Deploy the stack:

```bash
docker compose -f docker-compose.production.yml -f docker-compose.observability.yml up -d db redis otel-collector jaeger grafana
docker compose -f docker-compose.production.yml -f docker-compose.observability.yml --profile tools run --rm migrate
docker compose -f docker-compose.production.yml -f docker-compose.observability.yml up -d app
```

3. Run the production preflight:

```bash
BASE_URL=https://api.norviqa.io ./scripts/ops/production_preflight.sh
```

4. Generate real request traffic:

```bash
curl -i https://api.norviqa.io/health/live
curl -i https://api.norviqa.io/health/ready
```

5. Confirm traces and metrics:

```bash
docker compose -f docker-compose.production.yml -f docker-compose.observability.yml logs --tail=100 otel-collector
docker compose -f docker-compose.production.yml -f docker-compose.observability.yml logs --tail=100 app
```

6. Access Grafana through an SSH tunnel because Compose binds it to localhost on the server:

```bash
ssh -L 3000:127.0.0.1:3000 <user>@<server>
```

Then open:

```text
http://127.0.0.1:3000
```

7. In Grafana:

- Open the provisioned StockPlan dashboard.
- Open Explore -> Jaeger and search for the `StockPlanBackend` service.
- Open Explore -> OTel Collector Metrics and confirm host metrics are present.
- Confirm alert contact points exist for email and Slack.
- Trigger a controlled failure in staging first, not production, and confirm alert delivery.

## Production Acceptance Checklist

- [ ] `/health/live` returns 200.
- [ ] `/health/ready` returns 200.
- [ ] App logs are JSON in production.
- [ ] App logs include request IDs and latency.
- [ ] OpenTelemetry bootstrap log appears when `OBS_TRACES_ENABLED=true`.
- [ ] Collector receives app telemetry without connection errors.
- [ ] Jaeger contains recent API traces.
- [ ] Grafana can query Jaeger.
- [ ] Grafana can query Collector metrics.
- [ ] Email alert contact point can send a test alert.
- [ ] Slack alert contact point can send a test alert.
- [ ] CPU and memory overhead are acceptable during smoke/load testing.
- [ ] Grafana is not exposed publicly unless protected by HTTPS, auth, and firewall rules.

## Self-Hosted Observability Options

The backend already emits OpenTelemetry, so future backends should accept OTLP directly or through an OpenTelemetry Collector. These are viable self-hosted options.

### Current Stack: OTel Collector + Jaeger + Grafana

Best for MVP launch and low-traffic production validation.

Pros:

- Already implemented.
- Simple Compose footprint.
- Works with OpenTelemetry.
- Grafana gives a familiar UI.
- Jaeger is easy to inspect for request traces.

Cons:

- No durable metrics store yet.
- No centralized log search.
- Jaeger all-in-one is not the long-term trace backend I would choose for higher traffic.

Recommendation: keep this for launch smoke testing and first production rollout.

### Grafana LGTM

Grafana's open stack is Loki for logs, Grafana for UI/alerts, Tempo for traces, and Mimir or Prometheus-compatible storage for metrics. Grafana also positions its stack around open standards like OpenTelemetry and Prometheus.

Pros:

- Natural upgrade from the current Grafana setup.
- Tempo is a better long-term trace backend than Jaeger all-in-one.
- Loki adds centralized log search.
- Prometheus/Mimir gives real metrics retention.
- Components can be adopted incrementally.

Cons:

- More moving parts than all-in-one products.
- Mimir and production Loki need careful storage and retention configuration.

Recommendation: best next step if you want to grow the current architecture without replacing it. For this API, the practical path is: add Prometheus first, replace Jaeger with Tempo later, add Loki only when log search becomes necessary.

Sources checked:

- https://grafana.com/about/grafana-stack/
- https://grafana.com/oss/tempo/

### SigNoz

SigNoz is an OpenTelemetry-native observability platform for traces, metrics, logs, dashboards, alerts, and APM. It can be self-hosted and uses ClickHouse as its storage layer.

Pros:

- One integrated product instead of assembling Grafana, Tempo, Loki, and Prometheus yourself.
- Strong OpenTelemetry fit.
- Good APM workflows for request latency, errors, traces, and logs.
- ClickHouse backend is suitable for high-volume telemetry.

Cons:

- Heavier than the current MVP stack.
- You operate ClickHouse and the SigNoz services.
- Migration means changing the Collector export target and dashboard workflow.

Recommendation: strong option if you want a self-hosted Datadog/New Relic-style product and prefer one UI over a composable Grafana stack.

Sources checked:

- https://signoz.io/
- https://github.com/SigNoz/signoz

### Uptrace

Uptrace is an open-source OpenTelemetry APM for traces, metrics, and logs. It uses ClickHouse for telemetry data and PostgreSQL for metadata.

Pros:

- Compact all-in-one APM experience.
- Good OpenTelemetry compatibility.
- Includes dashboards, alerting, service graphs, trace search, and metrics.
- Can be run self-hosted.

Cons:

- Adds ClickHouse and PostgreSQL operational responsibility.
- Smaller ecosystem than Grafana.

Recommendation: good if you want a smaller all-in-one APM and are comfortable operating ClickHouse.

Sources checked:

- https://uptrace.dev/
- https://github.com/uptrace/uptrace

### ClickStack / HyperDX

ClickStack combines ClickHouse, OpenTelemetry, and HyperDX for logs, metrics, traces, dashboards, and production debugging workflows.

Pros:

- Built around ClickHouse and OpenTelemetry.
- Strong log and trace search.
- Good fit if telemetry volume grows and query speed matters.

Cons:

- More operational weight than the current stack.
- Best when you are ready to operate ClickHouse intentionally.

Recommendation: consider later if log/search volume becomes a major need or if you want ClickHouse-centered observability.

Sources checked:

- https://clickhouse.com/use-cases/observability
- https://github.com/hyperdxio/hyperdx

### VictoriaMetrics Stack

VictoriaMetrics now offers separate open-source components for metrics, logs, and traces: VictoriaMetrics, VictoriaLogs, and VictoriaTraces. VictoriaTraces accepts OTLP and exposes Jaeger-compatible query APIs.

Pros:

- Efficient, self-hosted, infrastructure-oriented stack.
- Strong metrics story.
- Lower-resource design is useful on small VPS deployments.

Cons:

- Less of a polished single APM workflow than SigNoz or Uptrace.
- You compose the experience yourself with Grafana or the VictoriaMetrics tooling.

Recommendation: good for cost-efficient infrastructure metrics and logs; evaluate carefully before replacing the trace/APM workflow.

Sources checked:

- https://victoriametrics.com/
- https://docs.victoriametrics.com/victoriatraces/

### OpenObserve

OpenObserve is an open-source observability platform for logs, metrics, and traces with OpenTelemetry support.

Pros:

- Unified platform.
- Strong positioning for high-volume log and telemetry storage.
- Self-hostable.

Cons:

- Another full platform to operate.
- Needs evaluation against your expected traffic, retention, and alerting needs.

Recommendation: consider if centralized logs become the main requirement and the Grafana/Loki path feels too operationally complex.

Source checked:

- https://openobserve.ai/

## Recommendation For StockPlanBackend

For the MVP:

1. Keep the current OTel Collector + Jaeger + Grafana stack.
2. Validate trace visibility and alert delivery in staging.
3. Add a durable Prometheus-compatible metrics store before relying on metrics for production incidents.
4. Add centralized logs only after Docker logs are not enough.

For production after MVP:

1. If you want incremental control, evolve to Grafana LGTM.
2. If you want an all-in-one self-hosted APM, evaluate SigNoz and Uptrace first.
3. If telemetry volume grows heavily, evaluate ClickStack/HyperDX or VictoriaMetrics components.
