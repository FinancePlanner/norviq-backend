# POST-MVP: Global Macro & Inflation Data

**Status**: Backend Phase 2 implemented (live providers + persistence + new endpoints) on branch `feat/macro-live-data`.
**Last updated**: 2026-07-09
**Owner**: Backend (this phase) → iOS (next phase)
**Related**: `docs/post-mvp-financial-platform.md`, `MVP/README.md`, iOS `Documentation/mvp-roadmap.md`

**Scope**: A global, Nowflation-style macro and cost-of-living layer: inflation gauges, official-release gaps, component tables, top movers, forecasts, personal inflation, everyday item trackers, housing/rates context, macro dashboards, public methodology, data status, and embeddable/API surfaces. Current backend coverage is US, Brazil, Portugal, and Euro Area; the product target is worldwide coverage with `country`, `region`, `currency`, `basket`, `measure`, `source`, `asOf`, and `vintage` as first-class dimensions.

## Why This Work

After the core MVP (portfolio, expenses/budgets, earnings, stock/crypto detail, dashboard, billing/trials) was accepted, the product lacked the public-macro layer users expect from a complete personal-finance + investing app: *why is my grocery bill up? what is the Fed doing? what is inflation in my country vs the US market I invest in?*

**Reference experience: nowflation.com** — a daily inflation gauge vs lagged official CPI, CPI-comparable and cost-of-living shelter variants, multiple measures (headline/core/supercore/PCE/core PCE), component tables with weights, forecasts and public scoreboards, item pages, personal inflation/cart calculators, geography pages, macro/rates/housing/labor/commodity dashboards, embeds, status, methodology, open data, and vintage-true history. Nowflation is US-centric; Norviq should use it as the feature model, not the geography model.

## Nowflation Feature Model, Globalized

Every Nowflation-inspired surface must work from a global contract instead of hardcoding US concepts. The US can expose BLS CPI, PCE, Fed Watch, FOMC, and state/metro pages. Other markets should map to the closest official source: Eurostat HICP/ECB context, IBGE IPCA/Selic, ONS CPIH/BoE, StatsCan CPI/BoC, INEGI CPI/Banxico, and so on.

| Nowflation pattern | Global Norviq version | Current backend status |
|---|---|---|
| Today gauge vs official + gap | Country/region inflation nowcast vs latest official national statistic, with gap, as-of, source, and confidence | **Partial live** — US official via FRED plus optional Nowflation enrichment; BR/PT/EA official monthly |
| CPI-comparable and cost-of-living shelter variants | Per-market official basket plus a cost-of-living variant that uses local rents, home prices, mortgage rates, and ownership mix where data exists | **Gap** — US owned/rent components exist; global shelter variant needs new sources |
| Multiple gauges | Headline, core, trimmed mean, services/supercore, central-bank-preferred measure, and PCE-equivalent only where the country defines them | **Partial live** — US headline/core/PCE/core PCE/trimmed mean; global headline only today |
| Component table with weights | COICOP/national basket component table: our YoY, official YoY, contribution, weight, and source lineage | **Live for current countries**, with static weights and country-specific component depth |
| Top movers and category tiles | Largest component/item moves by country, category, contribution, and timeframe | **Live** for existing components/items |
| Forecast and next-print countdown | Official-release calendar per statistical agency, forecast, consensus/market expectation when licensed, and post-release error grading | **Partial live** — US BLS/FOMC calendar; global calendars and scoreboards pending |
| Long-run chart and revision history | Latest-vintage and vintage-at-time series for every country/measure; revision diff pages | **Live data model** — vintage-safe storage implemented |
| Personal inflation / cart calculator | User basket from expense categories, country, region, household type, currency, and merchant/category mix | **Phase 3** |
| Grocery/item pages | Global item trackers for food, fuel, utilities, rent, mortgage, vehicles, transit, and staples; show price when available, index otherwise | **Partial live** — US BLS APU prices; BR/PT/EA index YoY |
| Geography pages | Country pages first, then regions/states/metros where official data exists | **Partial live** — country dimension exists; subnational geographies pending |
| Housing and affordability | Rent, home price, mortgage rate, payment burden, rent-vs-buy, and affordability by country/region | **Partial live (lite)** — US HPI/mortgage/starts/supply + rent; EA HPI/mortgage/rent; BR rent (+ Selic via BCB); see `/v1/macro/housing` |
| Rates, central-bank, and policy watch | Fed/ECB/BoE/BoC/Bacen/Banxico/etc. policy context, yield curves, real rates, breakevens where available | **Partial live** — `/v1/macro/policy-watch` US/BR/EA; Fed Watch US alias remains |
| Macro dashboards | Jobs, GDP, expectations, activity, labor, conditions, income, trade, surveys, money, fiscal, stress, liquidity, FX, credit, growth, real wages, recession | **Partial live (lite)** — `/v1/macro/economy` unemployment, GDP, Sahm, policy rate; US adds payrolls/claims/NBER |
| Commodities and energy | Global fuel, electricity, utility gas, food commodities, and FX-adjusted import pressure | **Partial live** — US energy/fuel CPI and item prices |
| Compare/matrix pages | Country-vs-country, region-vs-region, and measure-vs-measure comparisons using normalized units and caveat labels | **Gap** |
| Embeds, data, status, methodology | Public-ish API/embeds, source status, coverage badges, changelog, methodology, and data-quality labels | **Partial live** — source/asOf in responses; needs public docs/status surfaces |
| Forecast scoreboard | Grade Norviq forecasts against official releases, consensus, central banks, and prediction markets where licensed | **Gap** |

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
| `GET /fed-watch` | US-only. Core PCE vs 2% target, yields, next FOMC, stance. Odds `null`. |
| `GET /policy-watch?country=` | **New.** Country-aware Fed/ECB/Bacen context (`US`/`BR`/`EA`). |
| `GET /housing?country=` | **New.** Lite housing hub (HPI/mortgage/rent/starts/supply — coverage varies). |
| `GET /economy?country=` | **New.** Lite growth/labor hub + Sahm rule (+ NBER US-only). |
| `GET /items?country=` | Everyday item trackers. US: real average prices + computed YoY/MoM; PT/EA/BR: index YoY only (`latestPrice` null) |
| `GET /items/{itemId}/series?country=` | **New.** Item history |

DTOs live in `norviq-shared` `Sources/StockPlanShared/Macro/` (`MacroDTOs.swift`, `FedWatchDTOs.swift`, `MacroItemDTOs.swift`) — all Phase-2 changes were additive-optional; existing iOS builds keep decoding.

## Implemented Data Source Matrix

| Country | Primary | Fallback | Enrichment | Cadence | Key |
|---|---|---|---|---|---|
| US | FRED (BLS/BEA/Treasury/Cleveland Fed) | — | Nowflation daily gauge (env-configured) | 4×/day | `FRED_API_KEY` (free) |
| BR | IBGE SIDRA (IPCA t1737 + groups t7060) | FRED (OECD mirror) | — | daily | none |
| PT | Eurostat HICP (`prc_hicp_manr`, geo=PT) | FRED (OECD mirror) | — | daily | none |
| EA | Eurostat HICP (geo=EA20) | FRED (OECD mirror) | — | daily | none |

Series IDs verified live 2026-07-09 (all 35 FRED IDs, all Eurostat COICOP codes, all 9 SIDRA c315 group codes resolve). Notes: OECD-on-FRED fallback series lag badly (BR/PT last 2025-04, EA 2023-01) — fallback quality is "better than nothing" only. Eurostat data in this environment currently ends 2025-12; `asOf` in responses reflects the true latest month.

## Global Coverage Strategy

Global does **not** mean every country has the same feature depth on day one. Each market gets a coverage badge:

| Level | Meaning | Example features |
|---|---|---|
| L0 — Official headline | National CPI/HICP/IPCA headline, latest release, history, source metadata | Country page, current snapshot, series chart |
| L1 — Core basket | Core measures, components, weights, top movers, next-release calendar | Component table, movers, print countdown |
| L2 — Nowcast | High-frequency proxies for fuel, food, shelter, energy, vehicles, FX/import pressure | Today gauge, gap vs official, volatile-category tiles |
| L3 — Cost of living | Personal basket, local prices, rent/home/mortgage, regional data | My Inflation, cart calculator, affordability |
| L4 — Macro context | Policy rates, yield curve, labor, GDP, income, trade, stress, liquidity, forecast scoreboard | Country macro dashboard and compare/matrix pages |

Expansion order:

1. **Current foundation**: US, BR, PT, EA with `country` as the API dimension.
2. **Tier 1**: GB, CA, MX, JP, AU, and individual Eurostat member states because official inflation APIs and English/structured metadata are reliable.
3. **Tier 2**: OECD/G20 coverage through national statistics, central-bank APIs, OECD, IMF, World Bank, BIS, and FRED mirrors where direct APIs are missing.
4. **Tier 3**: Subnational geography where official data supports it: US states/metros, Eurostat geographies, and national regional datasets.

Global normalization rules:

- Use ISO country/region/currency codes in every request and response.
- Store both native measure names (`CPIH`, `HICP`, `IPCA`) and normalized measure families (`headline`, `core`, `services`, `food`, `energy`, `shelter`).
- Prefer official national statistical agencies for official prints; use high-frequency market/public data only for nowcasts and clearly label it as such.
- Attach `frequency`, `coverageLevel`, `sourceURL`, `license`, `asOf`, `fetchedAt`, and `vintageDate` to persisted data.
- Never compare unlike measures silently. Cross-country compare pages must show caveats for basket, tax, housing, seasonal-adjustment, and methodology differences.

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
- **Phase 3 (next backend)**: global country registry, coverage badges, release calendars, normalized measure families, "My Inflation" personalization (profile country + expense categories), purchasing-power/real-return calculators, shelter & services-ex-energy aggregates, Tier-1 countries (GB/CA/MX/JP/AU + Eurostat member states), central-bank policy-rate series (Fed, ECB, BoE, BoC, Bacen, Banxico).
- **Phase 4**: high-frequency global nowcast proxies (fuel/energy/food/shelter/FX), forecast scoreboards, compare/matrix pages, methodology/status/data pages, public embed payloads.
- **iOS phase**: wire existing `Features/Macro/MacroScreen.swift` into navigation, chart via `MetricTrendChart`/`InteractiveLineChart`, country/region picker default from UserProfile, coverage badges, local central-bank context card, items grid, personal basket, Pro gating (free = current + movers; Pro = history, policy watch, items, more countries).
- **Web phase**: greenfield (`norviq-web` has zero macro surface) — new `internal/pages/macro/` + go-echarts for country pages, compare/matrix, methodology/status, and embeddable charts.
- **Phase 5**: dashboard context cards, alerts on big moves, exports.

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
- **US-centric feature drift**: Nowflation names are BLS/Fed-specific; global surfaces must map concepts to local equivalents instead of forcing US terminology on every market.
- **iOS compat**: stub fallback stays on until live data proven; all DTO changes additive.

## Attribution Requirements

Every screen and response must show `country`, optional `region`, `measure`, `currency`, `coverageLevel`, `source`, `asOf`, and "Data from X + official national source". Forecasts and nowcasts must be labeled separately from official releases. Responses already carry part of this metadata; clients must render it and new APIs must fill the missing global fields as coverage expands.
