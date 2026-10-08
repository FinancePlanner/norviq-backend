# Market Brief: morning pre-market brief + end-of-day recap

Date: 2026-10-08 · Status: approved design, pending written-spec review · Branch: `feat/market-brief`

## Context
The user wants Norviq's main screens (web `/dashboard`, the web landing page, the iOS dashboard tab) to show two short market briefs each weekday:
- **Morning brief** (07:30 Lisbon): European and US futures rows (🇩🇪 DAX → 25.032 → 🔴 0,77%), then 5–7 📌 highlights on Asia, yields, oil, macro data and the day's calendar, plus 📍 earnings of the day.
- **Evening recap** (22:30 Lisbon, 90 min after the US close): 5–8 numbered stories that moved markets that day, with $TICKERs, including world events where they affect markets.

**Decisions made with the user:**
- Numbers come from the Yahoo chart API. The text is written by the LLM with web search.
- Both en and pt-PT are generated. Each client shows the one matching its language.
- Weekdays only.
- Everyone sees it, including logged-out visitors, so it can also bring in strangers.
- On the web it is the first card on `/dashboard`.

**Constraints:**
- The briefs are the same for every user, so each is generated once and stored.
- The LLM must never invent index levels.
- Rollout follows the usual gate pattern: on in staging, off in production.
- Infra changes go only in `~/Work/production/platform/infra`.

**Flag (user rule):** this is supply-side work while the strangers-count is 0. The public landing page section is the part that can help demand.

## Changes since the approved plan
Found while writing this spec. Both reduce risk and both follow patterns already in the code:
- **The route is not fully unauthenticated.** It sits in the existing `market:read` group: `ScopedBearerAuthenticator` and `ScopeRequirementMiddleware(.marketRead)`, the same as `Market/MarketDataController.swift:9`. iOS calls it with the user's session. The web calls it with its existing `PUBLIC_API_TOKEN` personal access token (scoped to `market:read`) for both the dashboard card and the logged-out landing card, the same way `norviq-web/internal/handlers/public_stock_data.go` does. Logged-out visitors still see the brief, but nothing is open for anyone to call. The Articles spec (`2026-10-08-articles-design.md` §4.3) makes the same choice.
- **Possible future switch to Anthropic's own web search.** `AnthropicChatClient` (#183, behind `ANTHROPIC_FIRST`) landed on main today. Anthropic's Messages API has a built-in web search tool, so it could replace OpenRouter's `:online`. For now the design stays on `:online`, which needs no client changes. Revisit if the trial makes Anthropic the default.

## 1. Shared DTOs: norviq-shared v5.20.0
New file `Sources/StockPlanShared/Market/MarketBriefDTOs.swift`, in the same style as `News/NewsTickerDTOs.swift` (public, Codable, Sendable, Equatable, explicit inits):
- `MarketBriefSlot` (`morning`, `evening`)
- `MarketBriefQuoteRow`: symbol, flag, name, `level` (a string the server has already formatted for the locale), `changePercent` (string), `direction` (up/down/flat)
- `MarketBriefQuoteGroup`: id `eu_futures`/`us_futures`, title, tone, rows
- `MarketBriefItem`: kind `highlight`/`earnings`/`story`, text, tickers, sourceUrl?
- `MarketBriefResponse`: enabled, tradingDate, slot, language, greeting?, groups, items, generatedAt, degraded

Clients add the 📌 📍 🔴 🟢 markers and story numbers from `kind` and `direction`. The server works out `tone` from the average % change; the LLM never sets it.

Tag v5.20.0 (the latest tag is v5.19.0 and HEAD is on it).
- Backend: bump the pin at `norviq-backend/Package.swift:9` from 5.18.0 to 5.20.0. `main` still pins 5.18.0. 5.19.0 carries the Articles DTOs and is pinned only on `feat/articles`. Both changes only add types, so whichever branch merges second takes the higher pin when it rebases.
- iOS: bump the pin at `project.pbxproj:1024` from 5.18.0 to 5.20.0. This also pulls in the 5.19 changes, so check that iOS still compiles.

## 2. Backend: new `Sources/StockPlanBackend/MarketBrief/`

| File | Role |
|---|---|
| `IndexQuoteProvider.swift` | A protocol, plus `YahooChartQuoteProvider`, which reads `query1.finance.yahoo.com/v8/finance/chart/{sym}?range=5d&interval=1d`. Price comes from `meta.regularMarketPrice` and the previous close from `meta.chartPreviousClose`. Each symbol is fetched separately, with an 8 s timeout and a browser User-Agent. If one symbol fails, only that row is left out. Symbols: ES=F, NQ=F, ^GDAXI, ^FCHI, ^STOXX50E (or FESX=F), ^N225, ^HSI, BZ=F, ^TNX. |
| `MarketBriefFormatter.swift` | Formats numbers for each language with `NumberFormatter`: pt_PT gives `25.032` and `0,77%`, en_US gives `25,032` and `0.77%`. Also holds the flag and name for each symbol. |
| `MarketBriefFacts.swift` | Builds the "SERVER-SELECTED FACTS" JSON: Yahoo quotes; the 10-year yield from `FREDMacroProvider` (`Macro/Providers/FREDMacroProvider.swift`) as a backup to ^TNX; today's earnings from the earnings service (`Earnings/EarningsProvider.swift`); headlines from `NewsProvider` general news and `FeedsClient` (`News/FeedsClient.swift`). |
| `MarketBriefPrompt.swift` | Same style as `AI/AIPrompt.swift`: a fixed system prompt plus the facts block. One call returns both languages (`{"en":{…},"pt-PT":{…}}`, `json_object`), so the two versions say the same thing and the cost is halved. Rules: no number that isn't in the facts or a cited web result; use `$TICKER`; pt-PT, not pt-BR; 5–7 morning items and 5–8 evening stories. |
| `MarketBriefValidator.swift` | Checks the LLM output: it must decode as JSON; item counts and lengths (≤280 characters) must be in range; tickers must match `^\$?[A-Z.]{1,6}$`. Every formatted number in the text must either match a fact or belong to an item with a `sourceUrl`; otherwise that item is dropped. If fewer than 3 items are left, the brief is rejected. |
| `MarketBriefSchedule.swift` | A pure function `dueSlot(now:) -> (tradingDate, slot)?` using the `Europe/Lisbon` time zone, so daylight-saving changes need no special handling. Monday–Friday only. Morning window 07:30–12:00, evening window 22:30–23:59. |
| `MarketBriefJob.swift` | Copies the pattern in `Insights/SentimentAggregationJob.swift`: `BackgroundJobState` and `scheduleRepeatedTask` every 300 s. When a slot is due and no row exists yet, it takes the Postgres lock with `JobLock.runAsLeader(app, name: "market_brief_job")` (`Shared/JobLock.swift`), checks again, then generates. At most 3 attempts per slot, tracked in memory. A pod that boots late, say at 08:10, still produces that morning's brief. |
| `MarketBriefController.swift` | Serves `GET /v1/market/brief?lang=&slot=&date=`. By default it returns the latest brief for the language, so on weekends users see Friday's recap. An unknown `lang` falls back to `en`. When the flag is off it returns 200 with `enabled:false`. Response header `Cache-Control: private, max-age=300`, because the route is authenticated; the web keeps its own cache. |

**LLM call:**
- The text is generated through a dedicated `DefaultOpenAIChatClient(apiKey:model:baseURL:maxTokens:timeout:)` (`AI/OpenAIClient.swift:287`). It uses the key and base URL from `AIProviderConfiguration.load()`, the model from `MARKET_BRIEF_MODEL` (default `anthropic/claude-haiku-4.5:online`; the `:online` suffix turns on OpenRouter web search, so no request-body change is needed), and a 90 s timeout.
- **Fallback when that call fails:** try once more with `app.openAIChatClient` (the existing fallback chain), using only the facts we gathered ourselves. That brief is saved with `degraded=true`.

**Storage:**
- New model `Models/MarketBriefRecord.swift`, following `Models/MacroSnapshotRecord.swift`. Columns: trading_date, slot, language, payload (JSON), generated_at, model, sources, degraded.
- Migration `Migrations/CreateMarketBriefs.swift` with a unique key on (trading_date, slot, language). Register it after `AddSocialFacebookImport()` (`ConfigureBootstrap.swift:~440`).
- The en and pt-PT rows are written in one transaction.

**Wiring:**
- `configure.swift`: register the job only when `envBool("MARKET_BRIEF_ENABLED")` is true, next to the PILOTS block.
- Routes: register `market/brief` in the same `market:read` group as `MarketDataController`, under the existing `ratelimit:market` limit (`routes.swift:74`). There is no unauthenticated route.
- `Sources/StockPlanBackend/openapi.yaml`: add `getMarketBrief` with `security: []` and its schemas.
- Add a command `market-brief-generate --slot morning|evening` to `asyncCommands`, modelled on `portfolio-backfill`, so a run can be forced on staging.

## 3. Web (norviq-web, build with `GOFLAGS=-mod=mod`)
- Generate a client from `oapi-codegen-market-brief.yaml` into `internal/api/marketbrief`, the same way as the newsticker slice. Add a Makefile target and list it under `oapi-codegen-local` (around Makefile:95–104).
- `internal/handlers/market_brief.go`: calls the backend with the `PUBLIC_API_TOKEN` PAT for both the dashboard and the landing page (copy `public_stock_data.go`; the brief is the same for every user, so it never needs the user's own token), passing `lang=i18n.Language(ctx)`. On an error, or when the flag is off, it returns an empty 200 so the card disappears (the same as `DashboardNewsTicker` in `dashboard_extras.go:67`).
- `internal/pages/dashboard/market_brief.templ`: `MarketBriefShell` loads the card with `hx-get` and `hx-trigger="load, every 900s"`, like `news_ticker.templ:11`. The card is built from `vigil.Panel`, `ListRow` and `RowTrailing`.
- Put the shell at the top of `CommandCenterPage` (`command_center.templ:23`) and in a new landing section between the hero and the vigil section (`landing.templ:~78`).
- Routes (`internal/server/server.go`): `/dashboard/market-brief` in the auth group (around line 325), and a public `/market-brief` (around line 194).
- Add the UI strings to both `internal/i18n/locales/active.{en,pt-PT}.json` files.

## 4. iOS (`norviq-ios/financeplan/financeplan`)
- New `Features/News/MarketBrief/{MarketBriefService,MarketBriefViewModel,MarketBriefCard}.swift`. Follow `NewsTickerViewModel`: show the cached brief first, then refresh from the network.
- Register the service as `Container.shared.marketBriefService` (Factory).
- Language comes from `AppLanguage.rawValue`, which is already `en` or `pt-PT`.
- The card is a `GlassCard` placed above `NewsTickerStrip` in `DashboardRoot.swift:~422`.

## 5. Infra (only in `platform/infra/apps/norviq/api/`)
- `values-staging.yaml`: `MARKET_BRIEF_ENABLED: "true"`, `MARKET_BRIEF_MODEL: anthropic/claude-haiku-4.5:online`.
- `values-production.yaml`: `MARKET_BRIEF_ENABLED: "false"`, same model.
- **Blocker for a real staging test:** staging's sealed `api-env` has no `OPENROUTER_API_KEY` (`values-staging.yaml:112`), so AI is turned off there. The key has to be sealed for namespace `norviq-staging` and secret name `api-env` (see `secrets/norviq/README.md`). The user provides the key value. Without it, staging only tests the rows and the "disabled" path.
- No network policy changes: outbound traffic is open (`cluster/network-policies/default-deny.yaml` only blocks incoming traffic).

## 6. Rollout order
1. Tag shared v5.20.0.
2. Backend PR. Deploy to staging by manual dispatch; merging to main does not deploy.
3. Seal the staging key and turn on the staging flag (infra PR). Read 2–3 weekdays of output in both languages and check `ai_completion` cost logs.
4. Web PR, then iOS PR (pin bump to 5.20.0, which reaches TestFlight through CI).
5. Production: promote with `-f service=both`, then set `MARKET_BRIEF_ENABLED` to "true" in values-production.

## Verification
- **Unit tests** (`Tests/StockPlanBackendTests/`):
  - `MarketBriefScheduleTests`: daylight-saving changes on 2026-03-29 and 2026-10-25; 07:29 vs 07:30; 12:01 (window missed); Saturday; a late pod boot.
  - `YahooChartQuoteProviderTests`: a saved JSON response; a missing `chartPreviousClose`; an error payload.
  - `MarketBriefFormatterTests`: pt and en formatting, including negative values.
  - `MarketBriefValidatorTests`: an invented number is dropped; a number with a source is kept; too few items is rejected.
  - Controller test: a `market:read` token gets 200, no token gets 401, and a token missing `market:read` gets 403; Cache-Control header present; weekend returns Friday's recap.
  - OpenAPI bundle test.
- **Staging end to end:** run `market-brief-generate --slot morning`, then `curl -H "Authorization: Bearer $PAT" https://dev-api.norviq.org/v1/market/brief?lang=pt-PT` and `?lang=en`, using a staging PAT with `market:read`. Check that the index levels match Yahoo by hand.
- **Web:** run `templ generate` and `go test ./...`. Check `/dashboard` and the logged-out `/` in both languages (lang cookie).
- **iOS:** run `xcodebuild` (with `ENABLE_USER_SCRIPT_SANDBOXING=NO` locally). Look at the card in the simulator in en and pt-PT.

## Risks
- **Yahoo is unofficial.** It can rate-limit, start requiring a cookie or crumb, or block datacenter IPs. Mitigation: a missing row is left out, quotes are cached in memory for 15 minutes, and the provider sits behind a protocol so it can be swapped. ^STOXX50E may be stale before the market opens; FESX=F is the alternative.
- **Web search cost.** The `:online` suffix costs about $0.02 per call, at 2 calls a day. The free fallback models don't run web search, and some don't support `json_object` (`AIModelCapabilities`, `AIFallbackChain.swift:46`). That is why the fallback brief is marked `degraded`.
- **Invented facts.** The number check in the validator is a heuristic. The `degraded` flag stays visible and rejected items are logged.
- **Market holidays** still produce a brief. A holiday list can come later.
- **Copyright.** Headlines are summarised, never copied, which is the same rule as the ticker.
