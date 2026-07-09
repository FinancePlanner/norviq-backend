# POST-MVP: Global Macro & Inflation Data

**Status**: Backend Phase 2 implemented (live providers + persistence + new endpoints) on branch `feat/macro-live-data`.
**Last updated**: 2026-07-09
**Owner**: Backend (this phase) → iOS (next phase)
**Related**: `docs/post-mvp-financial-platform.md`, `MVP/README.md`, iOS `Documentation/mvp-roadmap.md`

**Scope**: Worldwide inflation gauges, CPI/HICP/IPCA, component breakdowns, top movers, Fed context, and everyday item trackers. First-class US support (FRED + optional Nowflation daily gauge) with real official-source providers for Brazil (IBGE) and Portugal/Euro Area (Eurostat). `country` is a first-class dimension everywhere (`?country=US|BR|PT|EA`, defaults to US).

## Why This Work

After the core MVP (portfolio, expenses/budgets, earnings, stock/crypto detail, dashboard, billing/trials) was accepted, the product lacked the public-macro layer users expect from a complete personal-finance + investing app: *why is my grocery bill up? what is the Fed doing? what is inflation in my country vs the US market I invest in?*

**Reference experience: nowflation.com** — a daily market-derived inflation gauge vs the lagged official BLS CPI, multiple measures (headline/core/supercore/PCE/core PCE), component tables with weights, Top Movers, Fed Watch box (Core PCE vs 2% target, trimmed mean, 2Y/10Y, FOMC odds), next-print countdown, grocery item trackers, basket treemap, methodology + open data. 1,079 series from 24 sources, base Jan 2018 = 100, vintage-true history.

## Gap Analysis vs Nowflation (screenshots, 2026-07-08)

| Nowflation feature | Status | Backing endpoint |
|---|---|---|
| Headline gauge vs official CPI + gap | **Live (official via FRED; gauge via Nowflation enrichment when configured)** | `GET /v1/macro/inflation/current` |
| Multiple gauges (Core CPI, PCE, Core PCE, Trimmed Mean) | **Live (FRED)** | same, `gauges[]` |
| Component table (Our YoY / BLS YoY / weight) | **Live (13 CPI sub-indices, static weights)** | same, `components[]`; `GET /v1/macro/inflation/components` |
| Top Movers (Utility Gas, Food at Home, Apparel...) | **Live (top 6 by \|YoY\|, direction from prior month)** | `GET /v1/macro/top-movers?focus=` |
| Category tiles (Energy / Food / Shelter / Services / Core) | **Partial** — energy_cpi/food_cpi/core series stored; shelter & services-ex-energy aggregates not yet split | `GET /v1/macro/inflation/series?series=energy_cpi` |
| Fed Watch box (Core PCE vs target, trimmed mean, 2Y/10Y, real 10Y) | **Live (FRED)** | `GET /v1/macro/fed-watch` |
| FOMC meeting odds (Kalshi/CME) | **Gap** — no free odds API; `nextFOMC.odds` ships `null` | — |
| Next CPI print countdown | **Live** (BLS 2026 release calendar; forecast filled by Nowflation enrichment) | snapshot `nextPrintCountdown` |
| Long-term multi-line chart (gauge vs official, 2018→) | **Live data** (monthly history since 2018, latest-vintage reads) — UI is iOS phase | `GET /v1/macro/inflation/series` |
| Grocery item trackers (eggs, milk, bread, gas...) | **Live** — US real prices (BLS APU), PT/EA/BR index YoY | `GET /v1/macro/items`, `GET /v1/macro/items/:id/series` |
| Basket treemap | **Later** — weights already in `components[].cpiWeight`; rendering is a client concern | — |
| "My Inflation" personalization | **Phase 3** | — |
| Housing/jobs/GDP/commodities/prediction-market sections | **Out of scope** for this phase | — |
| Methodology / open data | **Partial** — every response carries `source` + `asOf`; vintage-true storage mirrors Nowflation's revision policy | — |

## Architecture (implemented)

```
Sources/StockPlanBackend/Macro/
├── MacroController.swift        # /v1/macro/* routes (rate-limited once in routes.swift)
├── MacroService.swift           # protocol + DefaultMacroService: Redis → DB → live → stub
├── MacroRepository.swift        # vintage-safe Fluent repo (see Persistence)
├── MacroRefreshJob.swift        # LifecycleHandler poller + MacroSyncStatus
├── MacroItemsCatalog.swift      # static per-country item catalog
├── MacroCalendars.swift         # FOMC + BLS CPI 2026 calendars (refresh annually!)
├── MacroStubData.swift          # legacy stubs, source="stub", behind MACRO_ALLOW_STUB_FALLBACK
├── Macro+Application.swift      # StorageKey DI (repository/service/registry/syncStatus)
└── Providers/
    ├── MacroProvider.swift          # MacroCountry, MacroSeriesKey, protocols
    ├── MacroProviderSelection.swift # pure per-country plan (unit-tested)
    ├── MacroProviderRegistry.swift  # primary → fallback → enrichment chain
    ├── FREDMacroProvider.swift      # US primary + intl fallback (needs FRED_API_KEY)
    ├── EurostatMacroProvider.swift  # PT/EA primary (JSON-stat 2.0 decoder), no key
    ├── IBGEMacroProvider.swift      # BR primary (SIDRA), no key
    ├── NowflationEnrichment.swift   # env-configured tolerant US enrichment
    └── MacroEnrichmentStubs.swift   # SeekingAlpha/Investing.com — hard-disabled (ToS)
```

**Read path** (every endpoint): Redis (`macro:snapshot:v1:{C}` 6h US / 24h intl, `macro:fedwatch:v1` 1h) → latest `macro_snapshots` row (re-warms Redis) → live provider fetch (persists on success) → stub (only while `MACRO_ALLOW_STUB_FALLBACK=true`, marked `source: "stub"`).

**Refresh**: `MacroRefreshJob` ticks every `MACRO_REFRESH_INTERVAL_SECONDS` (3600); refreshes a country only when its cadence elapsed — US `MACRO_US_REFRESH_SECONDS` (21600 = 4×/day), others `MACRO_INTL_REFRESH_SECONDS` (86400). Per-country failure isolation; one bad upstream never blocks the rest.

**Persistence (vintage-true, mirrors Nowflation's policy)**:
- `macro_series_points` (country, series_key, period_date, value, unit, source, vintage_date) — revisions append a new vintage row; historical values are never mutated. Reads resolve the latest vintage per period.
- `macro_snapshots` (country, as_of, source, payload JSON, fetched_at) — insert-only, deduped on (country, as_of, source).
- Migration: `Migrations/CreateMacroTables.swift`.

**Health**: `/health` readiness gains a `macro` check — `skipped` when no providers configured, `degraded` (never unhealthy) listing stale countries (> 3× cadence), freshness backed by DB so restarts don't reset to "never".

## Endpoints

All under `/v1/macro`, SessionToken auth + rate limit (80/min, `ratelimit:macro`). Full schemas in `openapi.yaml` (Macro tag). Bruno requests in `norviq-collection/Macro/`.

| Endpoint | Notes |
|---|---|
| `GET /inflation/current?country=` | Full snapshot: headline, gauges, components, top movers, notes, next-print countdown |
| `GET /inflation/components?country=` | Components only |
| `GET /top-movers?country=&focus=utilities,food,shelter` | Substring filter on categories |
| `GET /inflation/series?country=&series=&from=&to=&limit=` | Real history, latest vintage per period. Keys: `headline_cpi`, `core_cpi`, `pce`, `core_pce`, `trimmed_mean_cpi`, `energy_cpi`, `food_cpi`, `nowflation_gauge`, `dgs2`, `dgs10`, `dfii10`, `t10yie` (+ legacy aliases `headline`, `official_cpi`, `nowflation_cpi`, `core`) |
| `GET /supported-countries` | Codes, currency, data source, `hasDailyData` |
| `GET /fed-watch` | **New.** Core PCE vs 2% target, distance, trimmed mean, 2Y/10Y, 10Y–2Y spread, real 10Y (TIPS), 10Y breakeven, next FOMC (2026 calendar), stance heuristic. Odds `null` (no free API) |
| `GET /items?country=` | **New.** Everyday item trackers. US: real average prices + computed YoY/MoM; PT/EA/BR: index YoY only (`latestPrice` null) |
| `GET /items/{itemId}/series?country=` | **New.** Item history |

DTOs live in `norviq-shared` `Sources/StockPlanShared/Macro/` (`MacroDTOs.swift`, `FedWatchDTOs.swift`, `MacroItemDTOs.swift`) — all Phase-2 changes were additive-optional; existing iOS builds keep decoding.

## Data Source Matrix

| Country | Primary | Fallback | Enrichment | Cadence | Key |
|---|---|---|---|---|---|
| US | FRED (BLS/BEA/Treasury/Cleveland Fed) | — | Nowflation daily gauge (env-configured) | 4×/day | `FRED_API_KEY` (free) |
| BR | IBGE SIDRA (IPCA t1737 + groups t7060) | FRED (OECD mirror) | — | daily | none |
| PT | Eurostat HICP (`prc_hicp_manr`, geo=PT) | FRED (OECD mirror) | — | daily | none |
| EA | Eurostat HICP (geo=EA20) | FRED (OECD mirror) | — | daily | none |

Series IDs verified live 2026-07-09 (all 35 FRED IDs, all Eurostat COICOP codes, all 9 SIDRA c315 group codes resolve). Notes: OECD-on-FRED fallback series lag badly (BR/PT last 2025-04, EA 2023-01) — fallback quality is "better than nothing" only. Eurostat data in this environment currently ends 2025-12; `asOf` in responses reflects the true latest month.

## Configuration

See `.env.example` ("Macro / inflation data" block): `MACRO_ENABLED`, `FRED_API_KEY`, `NOWFLATION_BASE_URL` + `NOWFLATION_SNAPSHOT_PATH`, `MACRO_REFRESH_INTERVAL_SECONDS`, `MACRO_US_REFRESH_SECONDS`, `MACRO_INTL_REFRESH_SECONDS`, `MACRO_ALLOW_STUB_FALLBACK`, `MACRO_ENRICHMENT_*_ENABLED`.

**Operator steps to go live (user action)**:
1. Get a free FRED key (https://fred.stlouisfed.org/docs/api/api_key.html) and set `FRED_API_KEY` in prod/staging secrets (sealed `api-env` in norviq-infra).
2. Optional: discover the Nowflation open-data JSON URL (browser devtools network tab on nowflation.com/data) and set `NOWFLATION_BASE_URL`/`NOWFLATION_SNAPSHOT_PATH`. Without it the US serves official-only numbers (gap/COL variant null).
3. After a few clean days: set `MACRO_ALLOW_STUB_FALLBACK=false` so missing data 503s instead of serving demo numbers.
4. Each January: refresh `MacroCalendars.swift` (FOMC + BLS CPI release dates) and the CPI weight table in `FREDMacroProvider.swift`.

## Phasing

- **Phase 1 (done)**: country-aware stub endpoints (`/current`, `/components`, `/top-movers`, `/series`, `/supported-countries`).
- **Phase 2 (this branch — done)**: real providers (FRED/Eurostat/IBGE + Nowflation enrichment), vintage-safe persistence, `MacroRefreshJob`, Redis caching, `fed-watch` + `items` endpoints, health check, OpenAPI/Bruno/env docs, 24 tests.
- **Phase 3 (next backend)**: "My Inflation" personalization (profile country + expense categories), purchasing-power/real-return calculators, shelter & services-ex-energy aggregates, more countries (GB/ONS first), central-bank policy-rate series (Fed funds, ECB, Selic).
- **iOS phase**: wire existing `Features/Macro/MacroScreen.swift` into navigation, chart via `MetricTrendChart`/`InteractiveLineChart`, Fed Watch card (new DTOs ready), items grid, country picker default from UserProfile, Pro gating (free = current + movers; Pro = history, fed-watch, items, more countries).
- **Web phase**: greenfield (`norviq-web` has zero macro surface) — new `internal/pages/macro/` + go-echarts.
- **Phase 4**: dashboard context cards, alerts on big moves, exports.

## Tests

`Tests/StockPlanBackendTests/Macro*` (24 tests; DB suites need `TEST_DATABASE_PORT=5432`):
- `MacroProviderSelectionTests` — plan matrix, country parsing, series-key aliases.
- `MacroProviderDecodingTests` — FRED `"."` missing values, Eurostat JSON-stat sparse lookup + snapshot assembly, SIDRA header-row/string/missing quirks, Nowflation tolerant decode + merge, calendars.
- `MacroRepositoryTests` — vintage safety (no dupes, revisions append, latest-vintage reads), range/limit, snapshot dedupe, freshness.
- `MacroServiceTests` — live-fetch persist, DB fallback, primary→fallback chain, stub-flag 503 behavior, fed-watch math (spread/distance/stance), item YoY/MoM from prices, refresh-job isolation + cadence skip.

## Verification Plan

1. `swift build` + `TEST_DATABASE_PORT=5432 swift test --filter Macro` green. ✔
2. External IDs verified live (FRED fredgraph, Eurostat API, SIDRA). ✔
3. With `FRED_API_KEY` set locally: hit all 8 endpoints via Bruno against dev stack (app port 8090) — `source` ≠ "stub" for US; spot-check numbers vs FRED/nowflation.com/IBGE/Eurostat.
4. `/health` shows `macro`: skipped (no key) → degraded (no data yet) → healthy after first refresh.
5. Vintage check: run refresh twice — second run inserts 0 points; simulate a revised value — new vintage row, old preserved (covered by tests).

## Risks & Mitigations

- **Nowflation endpoint discovery**: SPA, JSON URLs not statically discoverable → enrichment is fully env-configured with a tolerant decoder and never fails the refresh; US ships official-only without it.
- **Eurostat JSON-stat** decode fragility → dedicated `JSONStatDataset` decoder + fixture tests; API 503s just retry next tick, reads served from DB/Redis.
- **IBGE SIDRA** quirks (header row, stringly values, undocumented codes) → parser handles all three; c315 codes pinned + fixture-tested.
- **FRED weights drift**: CPI relative-importance weights are hardcoded and revised annually by the BLS → January maintenance task (with calendars).
- **OECD-on-FRED fallback staleness** (see matrix) → fallback only; primaries are the fresh official sources.
- **Seeking Alpha / Investing.com**: no public APIs; scraping violates their ToS. Shipped as hard-disabled stubs (`MacroEnrichmentStubs.swift`) — enabling is a product/legal decision, not a code change.
- **FOMC odds**: no free source (CME FedWatch/Kalshi are licensed) — field ships `null`, UI should hide the row.
- **iOS compat**: stub fallback stays on until live data proven; all DTO changes additive.

## Attribution Requirements

Every screen and response must show `country`, `source`, `asOf`, and "Data from X + official national source". Responses already carry these fields; iOS must render them.
