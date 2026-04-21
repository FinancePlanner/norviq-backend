# Observability Implementation Plan (Hetzner + Docker Compose)

This document defines a phased plan to add observability to `StockPlanBackend` on a single Hetzner VPS using Docker Compose.

## Goal

Implement observability in this order:

1. Vapor + `TracingMiddleware` + OpenTelemetry Collector + Jaeger + Grafana.
2. Add Prometheus next (short retention first).
3. Add Loki only if centralized log search/retention is needed.
4. For sustained production traffic, move observability to a second node or managed backend.

## Scope

- This is the implementation/runbook record for the current repo observability stack.
- Code and Compose changes are now included in the repo.
- Target environment: single VPS, Docker Compose deployment.

## Current Baseline (Repo Status)

- `TracingMiddleware` is enabled in `Sources/StockPlanBackend/configure.swift`.
- `app.traceAutoPropagation = true` is enabled in `Sources/StockPlanBackend/configure.swift`.
- `RequestLoggingMiddleware` emits request metadata including request ID, method, path, status, latency, user ID when authenticated, and inbound `traceparent` when present.
- `LOG_FORMAT=json` enables JSON app logs and is the production default.
- `docker-compose.observability.yml`, `monitoring/otel-collector.yaml`, and Grafana datasource provisioning define the first collector, Jaeger, and Grafana stack.
- `swift-otel` is wired as the app-side OTLP backend when `OBS_TRACES_ENABLED=true`.
- The production compose observability stack includes OTel Collector, Jaeger, Grafana, baseline metrics scraping, dashboards, and email/Slack alert contact points.

## Architecture Phases

### Phase 1: Tracing Foundation (Implement First)

#### Objective

Get end-to-end request traces from Vapor into Jaeger, visualized in Grafana, with minimal production overhead.

#### Services to Add

- `otel-collector`
- `jaeger` (start with all-in-one for simplicity)
- `grafana`

#### Implementation Checklist

- [x] Add OpenTelemetry tracing backend dependency for Swift (`swift-otel`) in `Package.swift`.
- [x] Bootstrap tracing backend in app startup (before serving requests) in `Sources/StockPlanBackend/entrypoint.swift`.
- [x] Keep `TracingMiddleware` enabled in `Sources/StockPlanBackend/configure.swift`.
- [x] Keep `app.traceAutoPropagation = true` unless throughput testing proves it is too expensive.
- [ ] Add manual context restore on NIO `EventLoopFuture` boundaries where applicable.
- [x] Add OTel Collector config file (`monitoring/otel-collector.yaml`) with OTLP receiver, `batch` and `memory_limiter` processors, and Jaeger trace exporter.
- [x] Add Compose services in a separate file (`docker-compose.observability.yml`).
- [x] Put observability services on internal Docker network.
- [x] Expose only Grafana to localhost unless a reverse proxy is explicitly configured.
- [x] Add persistent volume for Grafana.
- [x] Add initial dashboard data source provisioning in `monitoring/grafana/provisioning/`.
- [x] Add env vars to `.env` or `.env.production`: `OBS_SERVICE_NAME`, `OBS_ENVIRONMENT`, `OBS_OTLP_ENDPOINT`, `OBS_TRACES_ENABLED`.

#### Exit Criteria

- [ ] Requests to the API generate traces visible in Jaeger.
- [ ] Trace spans show parent-child hierarchy (middleware span -> route span).
- [ ] Grafana can query and display trace data.
- [ ] No user-facing latency regression observed in smoke tests.

### Phase 2: Metrics with Prometheus

#### Objective

Capture service health metrics (latency, errors, throughput, DB/cache behavior) with short retention.

#### Services to Add

- `prometheus`

#### Implementation Checklist

- [ ] Define core service-level indicators: HTTP request count, HTTP error rate (4xx, 5xx), HTTP latency (p50/p95/p99), DB latency/error count, Redis latency/error count.
- [ ] Add metrics instrumentation in app code where needed.
- [x] Extend OTel Collector pipeline to process/export metrics.
- [ ] Configure Prometheus scrape targets and rules in `monitoring/prometheus/prometheus.yml`.
- [ ] Start with short retention (for example 3-7 days).
- [x] Add baseline Grafana dashboard provisioning.
- [x] Add baseline alert rules and email/Slack contact point provisioning.

#### Exit Criteria

- [ ] Prometheus is collecting metrics continuously.
- [ ] Grafana dashboards show 24h and 7d trends.
- [ ] Basic alerts can trigger during controlled failure tests.

### Phase 3: Logs with Loki (Only If Needed)

#### Objective

Add centralized log search and retention if Docker logs/journal logs are no longer enough.

#### Decision Gate

Implement this phase only if at least one condition is true:

- [ ] Need cross-container log correlation in one UI.
- [ ] Need searchable retention longer than host log rotation.
- [ ] Need log-based operational workflows for incident response.

#### Services to Add

- `loki`
- `promtail` (or OTel Collector log pipeline if preferred)

#### Implementation Checklist

- [ ] Standardize app logs as structured JSON.
- [ ] Ensure trace IDs are included in log context where possible.
- [ ] Add Loki config (for example `monitoring/loki/loki-config.yml`).
- [ ] Add promtail config (for example `monitoring/promtail/promtail-config.yml`).
- [ ] Define label strategy carefully (avoid high-cardinality labels).
- [ ] Set retention limits aligned with disk budget.
- [ ] Add Grafana log exploration dashboard/panels.

#### Exit Criteria

- [ ] Can pivot from trace ID to logs during debugging.
- [ ] Log storage remains within planned disk budget.
- [ ] Query performance remains acceptable during incident workflows.

### Phase 4: Move Observability Off the App Node

#### Objective

Prevent observability workloads from contending with API and database resources.

#### Migration Triggers

Plan migration when one or more conditions persist:

- [ ] CPU contention affects API latency.
- [ ] Memory pressure causes OOM or frequent container restarts.
- [ ] Disk growth from metrics/logs risks service stability.
- [ ] Sustained production traffic requires better isolation.

#### Migration Options

1. Second Hetzner VPS dedicated to observability stack.
2. Managed backends for one or more signals (traces/metrics/logs).

#### Migration Checklist

- [ ] Move Collector + storage backends first.
- [ ] Keep app OTLP export endpoint configurable via env var.
- [ ] Restrict backend ingress to private network/VPN/firewall rules.
- [ ] Validate dashboards and alerts after endpoint cutover.
- [ ] Keep rollback path to local stack for one release window.

## Suggested File Touchpoints (When Implementing)

- `Package.swift`
- `Sources/StockPlanBackend/entrypoint.swift`
- `Sources/StockPlanBackend/configure.swift`
- `.env`
- `.env.production`
- `docker-compose.observability.yml` (new)
- `monitoring/otel-collector.yaml` (new)
- `monitoring/prometheus/prometheus.yml` (new)
- `monitoring/loki/loki-config.yml` (new, Phase 3 only)
- `monitoring/promtail/promtail-config.yml` (new, Phase 3 only)
- `monitoring/grafana/provisioning/` (new)

## Production Guardrails for a Single VPS

- Start with tracing first, then metrics, then logs.
- Set explicit memory limits per observability service in Compose.
- Keep retention short until capacity is measured.
- Expose only required ports publicly (prefer internal networking).
- Protect Grafana with auth and avoid public unauthenticated access.

## Rollout Sequence

1. Implement Phase 1 in staging.
2. Load test and check API latency impact.
3. Promote Phase 1 to production.
4. Implement and validate Phase 2.
5. Add Phase 3 only if decision gate criteria are met.
6. Reassess infra topology and execute Phase 4 when triggers appear.

https://medium.com/@kicsipixel/bridging-swift-on-server-code-and-devops-monitoring-6e29f2ef7b7c
