# POST-MVP: Global Macro & Inflation Data

**Status**: Planned (post-MVP).  
**Last updated**: 2026-07-08 (code stubs for country support implemented)  
**Owner**: Backend + iOS  
**Related**: `docs/post-mvp-financial-platform.md`, MVP/README.md, iOS `Documentation/mvp-roadmap.md`

**Scope**: Worldwide inflation gauges, CPI/HICP equivalents, component breakdowns, top movers, and macro indicators. Strong first-class support for the United States (via Nowflation + official sources) with easy expansion to other countries (Brazil, Portugal/Euro Area, UK, etc.). Users can view their home country + the US market.

## Why This Work

After the core MVP (portfolio tracking, expenses/budgets, earnings, stock/crypto detail, dashboard, billing/trials) is accepted by the App Store and users, the product lacks a major public-macro layer that real users expect in a "complete" personal finance + investing app.

Users around the world care deeply about inflation and cost-of-living:
- A Portuguese user (or anyone focused on global markets) may primarily want high-quality **US data** (because US markets and Fed policy heavily influence global assets, equities, and commodities).
- A Brazilian user wants timely **Brazilian IPCA / official CPI** + food/energy components.
- European users (Portugal, Germany, Spain, etc.) want **HICP** from Eurostat/ECB, with breakdowns for housing, energy, and food.
- Similar needs exist for UK (ONS), India, Mexico, Japan, China, etc.

**US Reference Experience: Nowflation.com**
Nowflation.com (https://nowflation.com) remains the gold-standard reference for a rich, near-real-time inflation experience:
- Daily "Nowflation Gauge" (market-derived) vs lagged official BLS CPI/PCE.
- Multiple measures (headline, core, supercore, PCE, core PCE).
- Detailed component tables + **Top Movers** (Utilities, Food, Shelter, etc.).
- Charts, FED context, forecasts, grocery/energy deep dives, "my inflation", open data.

**Goal**: Deliver something **as complete and delightful** (mobile-adapted) for the US *and* a growing set of other countries. The architecture must treat "country" as a first-class dimension from day one so adding Brazil, Portugal/Euro Area, UK, etc. is straightforward.

This makes the app useful globally while giving US-market-focused users (including many Portuguese-speaking users) the best possible data for the market they care most about.

## Evaluation of Nowflation + Global Data Landscape

### US Reference (Nowflation.com)
**Homepage snapshot (2026-07-08)**:
- Headline: US inflation today **1.74%** Nowflation Gauge (CPI-comparable) vs **4.2%** official CPI (May), gap **-2.46pp**. COL variant 1.47%. +33.9% cumulative since 2018 base.
- Daily narrative calls out swing factors (motor fuel).
- Tables:
  - Every gauge comparison (CPI, Core, Supercore, PCE, Core PCE).
  - Component detail (Our YoY / BLS YoY / CPI weight) for Shelter (Rent 0.8% vs Owned 3.3%), Motor Fuel, Food at Home/Away, Electricity/Utility Gas, etc.
- **TOP MOVERS** (screenshots): Utility Gas +11.82%, Food at Home +0.68%, Apparel +0.64%, Shelter: Owned +0.53%, Everything Else +0.38%, Motor Fuel -1.09%.
- Charts: Long-term multi-line (Nowflation vs Official) + recent.
- Supporting: FED Watch box, basket % (Energy 23.5%, Food, Shelter), next-print countdown, grocery item trackers (eggs, milk, bread, chicken, gas), methodology, open data downloads, many linked sections (housing, jobs, rates, macro, commodities, prediction markets, affordability).

Screenshots show a professional, dark, dense, terminal-style dashboard. Nowflation excels at timeliness and component granularity for the US.

**What makes the US experience "complete"**:
- Near-real-time gauge + official lag explanation.
- Actionable categories (Utilities, Food, Shelter highlighted).
- Transparency (sources, weights, methodology, vintage data).
- Breadth (FED context, housing, groceries, forecasts, personal basket).
- Beautiful yet scannable presentation.

### Global Requirements
Most countries publish official CPI/HICP monthly (lagged). Few have Nowflation-style daily market-derived gauges. We need a **tiered global approach**:

- **Tier 1 (High priority)**: United States (Nowflation + BLS/FRED), Euro Area + Portugal (Eurostat HICP + ECB + INE Portugal), Brazil (IBGE IPCA + BCB).
- **Tier 2**: UK (ONS), Germany/France/Spain (national + HICP), Mexico, India, China, Japan, Canada, Australia.
- **Tier 3**: Broader coverage via IMF/OECD/World Bank/FRED aggregates.

Key data types we want per country (adapted naming):
- Headline inflation + core/ex-food-energy.
- Major components: Food, Energy/Utilities, Housing/Shelter/Rent, Transport, etc.
- Top movers / largest contributors.
- Official vs "now" or alternative measures where available.
- Charts + history (monthly for most, daily for US).

**Recommended data sources**:
- **US**: Nowflation.com (daily gauge) + BLS + FRED (rich history + components).
- **Euro Area / Portugal**: Eurostat HICP API, ECB Statistical Data Warehouse.
- **Brazil**: IBGE (IPCA), Banco Central do Brasil (Selic + inflation expectations), FRED series.
- **Global fallback / many countries**: FRED (St. Louis Fed has excellent multi-country coverage), IMF CPI, OECD, BIS.
- Real-time alternatives: Truflation-style approaches where available (currently limited outside US).

We should normalize responses (headline, core, food, energy, housing) while preserving country-specific names and sources.

**User experience goal**:
- Default to user's profile country (from UserProfile) + easy US view.
- Ability to switch countries or view a shortlist (e.g. "My Country + US").
- "My Inflation" personalization using local basket + user's expense categories.

### Initial Supported Countries (Phase 1+)
- `US` — Nowflation + BLS/FRED (richest experience)
- `EA` or `PT` — Eurostat HICP + ECB (Portugal users get EU + national view)
- `BR` — IBGE IPCA + BCB

Later additions: `GB`, `MX`, `IN`, `CN`, `JP`, `CA`, `AU`, etc.

**UserProfile integration** (future):
- Add preferred `macroCountry` (or use existing locale/country field).
- Dashboard and Macro screen default to this value.

## Current App State (MVP)

**Backend**:
- Excellent asset-centric market data + user portfolio statistics.
- No macro series, no inflation gauges, no public economic indicators.
- Hermes only for private X sentiment.

**iOS**:
- Personal dashboard (savings rate, budget streak, portfolio trends, activity).
- Strong stock/earnings/portfolio tools.
- Zero inflation / cost-of-living / macro surface.

**Web**: Portfolio/statistics parity only.

**Result**: Post-MVP acceptance, users interested in the *backdrop* of their finances (why is my grocery bill up? shelter costs? fed moves? Selic decisions in Brazil?) have nothing. We need to support multiple countries.

## Recommended Scope & Phasing

**Phase 1 (Global Macro MVP) — Current Implementation**:
- Country-aware current snapshot supporting **US** (Nowflation-powered data), **BR** (IPCA-style), **PT** and **EA** (HICP-style).
- Headline + multiple gauges, components, and Top Movers with localized category names where appropriate.
- History series endpoint (stub data per country).
- `/supported-countries` endpoint.
- All endpoints accept `?country=US|BR|PT|EA` (defaults to US).
- Currently pure stub data inside `MacroService` + `MacroController`. No external API calls yet.

**Phase 2**: 
- Full history across supported countries.
- Forecasts, central bank policy rates (Fed, ECB, BCB Selic, etc.).
- More components + chart parity.
- Add 2-3 additional countries.

**Phase 3**: 
- Personalization ("My Inflation") using user's profile country + expense categories.
- Grocery / specific item deep-dives per country.
- Calculators (purchasing power, real returns).
- Broader macro (unemployment, policy rates, housing).

**Phase 4**: 
- Dashboard integration + context cards ("Inflation in your country: X%").
- Alerts on big moves.
- Exports, web parity.
- Primary-source independence and "now" style gauges where feasible.

**Data Strategy**:
- **US (priority)**: Nowflation.com (daily) + BLS + FRED.
- **Europe / Portugal**: Eurostat HICP API + ECB + national statistical institutes (INE.pt). FRED also has good Euro area series.
- **Brazil**: IBGE (IPCA series) + BCB.
- **Global**: FRED (excellent multi-country coverage for CPI, core, food, energy, policy rates), IMF, OECD, BIS.
- Architecture: Pluggable `MacroDataProvider` per country/region group (e.g. `NowflationMacroProvider`, `FredMacroProvider`, `EurostatMacroProvider`). Daily (US) or scheduled monthly refresh jobs. Store normalized + raw.
- Cache snapshots + full history.
- Always show clear source + "as of" + "official vs alternative" attribution.
- Start narrow on countries (US + PT/Euro Area + BR) but design DTOs and storage with `country` as a dimension from the beginning.

**Mobile Adaptation**:
- Country picker / segmented control (My Country | US | Others).
- Hero gauge + narrative per selected country.
- Localized Top Movers (e.g. "Alimentos", "Habitação", "Energia" for PT/BR).
- 2x2 or list Top Movers, expandable components, beautiful line chart.
- Reuse existing GlassCard, charts, typography.
- Free: current + movers for supported countries. Pro: history, full components, forecasts, personalization, more countries.

## Backend Endpoints (Current MVP Implementation)

All under `/v1/macro`, SessionToken + rate limit (market-like).

**Country support (implemented)**:
- `?country=US|BR|PT|EA` query parameter (case-insensitive).
- Defaults to `US`.
- Every response includes `country` and `currency`.

### 1. GET /v1/macro/inflation/current?country=US
Primary MVP endpoint.

**Current behavior**:
- Returns full snapshot with headline, gauges, components, and top movers.
- US uses Nowflation-style numbers + narrative.
- BR returns IPCA-style data with Portuguese category names.
- PT/EA returns HICP-style data.

**Example response shape** (US):
```json
{
  "country": "US",
  "currency": "USD",
  "asOf": "2026-07-08",
  "updatedAt": "...",
  "source": "nowflation.com + BLS (2026-07-08)",
  "headline": {
    "name": "Nowflation CPI",
    "nowValue": 1.74,
    "officialValue": 4.2,
    "officialAsOf": "2026-05",
    "gap": -2.46,
    "colVariant": 1.47,
    "cumulativeSinceBase": 33.9,
    "basePeriod": "2018-01"
  },
  "gauges": [ ... multiple gauges ... ],
  "components": [ ... 14 components ... ],
  "topMovers": [ ... 6 items ... ],
  "notes": "Nowflation Gauge holds at 1.73% YoY...",
  "nextPrintCountdown": { ... }
}
```

Similar structure is returned for `?country=BR` and `?country=PT` / `?country=EA` with appropriate localized data.

### 2. GET /v1/macro/inflation/series?country=BR&series=headline
Time series for charts (MVP stub data, country-aware).

### 3. GET /v1/macro/top-movers?country=BR&focus=alimentos
Supports optional `focus` filter.

### 4. GET /v1/macro/supported-countries
Returns list of supported countries with metadata (implemented).
Returns list of supported countries with display names and data freshness.

**Current implemented endpoints (MVP)**:
- `GET /v1/macro/inflation/current?country=BR`
- `GET /v1/macro/inflation/components?country=PT`
- `GET /v1/macro/top-movers?country=US&focus=food`
- `GET /v1/macro/inflation/series?country=BR`
- `GET /v1/macro/supported-countries`

All responses include `country` + `currency`.

**Query patterns**:
- `/v1/macro/inflation/current` → defaults to "US"
- `/v1/macro/inflation/current?country=BR`
- `/v1/macro/top-movers?country=PT`

Later phases will add rate snapshots, personalization, and real providers.

## DTOs (norviq-shared)

`Macro/MacroDTOs.swift` (country-aware, implemented):
- `InflationSnapshotResponse` (has `country`, `currency`)
- `InflationGaugeDTO`
- `InflationComponentDTO`
- `TopMoverDTO`
- `MacroSeriesPoint`
- `SupportedCountry`
```swift
public struct InflationSnapshotResponse {
    public let country: String
    public let currency: String
    ...
}
```

Mirror style of `StatisticsDTOs.swift` and `MarketDTOs.swift`. Country-specific category names are acceptable (e.g. "Alimentos" for Brazil/Portugal).

## Backend Implementation Skeleton (Current MVP State)

Implemented:
- `MacroController.swift` — thin controller, reads `?country=`, delegates to service
- `MacroService.swift` — contains the MVP stub data for US / BR / PT / EA
- `Macro+Application.swift` (placeholder)
- `NowflationMacroProvider.swift` (existing placeholder, not yet wired)
- Registered in `routes.swift` under rate-limited `/v1/macro/*`

Not yet implemented (planned for later phases):
- Real providers (Nowflation fetch, FRED, Eurostat, IBGE)
- `MacroRefreshJob`
- Database models + migrations for snapshots
- Health check integration for per-country freshness
- OpenAPI updates

See `MarketDataController.swift` + `StatisticsController.swift` for patterns we will follow.

**Database note**: When we move beyond stubs, add `country` column (default "US") early.

## iOS Additions

- `API/Macro/MacroEndpoints.swift` + HTTP client + factory (support `country` param)
- `Features/Macro/`
  - `InflationHeroGauge.swift`
  - `TopMoversGrid.swift` (highlight country-appropriate movers, e.g. Alimentos + Habitação for PT/BR)
  - `ComponentBreakdownList.swift`
  - `MacroScreen.swift` + ViewModel + country picker
  - Re-use charts
- Country selector (default from UserProfile, quick switch to US)
- Teaser card in `DashboardRoot.swift` (shows user's primary country + US context)
- Paywall gating consistent with existing (Reports, etc.)
- Localization support for category names where possible

## Documentation & Attribution

- This file is the source of truth.
- Every screen and response **must** show: `country`, `source`, `asOf`, and "Data from X + official national source".
- Update `post-mvp-financial-platform.md` with a "Macro & Cost-of-Living Context" subsection.
- Add Bruno collection under `norviq-collection/Macro/`.
- Maintain a `docs/macro-data-sources.md` (or section here) listing per-country sources and update cadence.

## Verification Plan

1. Backend: stub → live US (Nowflation) → live Brazil/Euro → full response shape + numbers (within tolerance).
2. iOS: renders hero + movers + chart correctly for US and at least one other country.
3. Spot-check US numbers daily against https://nowflation.com/. Spot-check other countries against official sources (IBGE, Eurostat).
4. Health/readiness reflects per-country data freshness.
5. Mobile layout, Dynamic Type, dark mode, Pro gating, country switching.
6. Update this doc + add country-specific screenshots on changes.

## Risks & Mitigations

- Data availability varies: Most countries = monthly official only. US gets the "daily now" advantage.
- Parse / API fragility → Use FRED where possible (stable), fall back to disabled per country, monitor freshness.
- Scope creep → Phase 1: US (rich) + 1-2 others (official). Add countries incrementally.
- Attribution / licensing → Always credit prominently. Prefer official open data + FRED.
- Personalization value high — do after basic public data works.
- Localization of category names (Alimentos vs Food) — start English + country code; add translations later.

## Immediate Next Actions (Backend Focus)

1. Backend endpoint improvements + doc sync (in progress).
2. Clean service/controller separation (done — `MacroService.swift` now holds MVP logic).
3. Keep updating this doc to reflect the actual state of the MVP endpoints as they evolve.
4. Later: wire real data sources, add persistence, jobs, etc. (outside current "just backend endpoint" scope).

This delivers the "something as complete" experience globally, with excellent US data for users who (like many Portuguese speakers) primarily follow the American market.
