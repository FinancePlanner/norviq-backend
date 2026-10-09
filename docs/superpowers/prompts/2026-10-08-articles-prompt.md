# Build "Norviq Articles": user-published stock write-ups on web, iOS and Discord, shareable to X / LinkedIn / Discord / Instagram

You are working in `~/Work/production/apps/norviq`. Read `CLAUDE.md` there and in `~/Work/production`
first. Infra changes go ONLY in `~/Work/production/platform/infra` — never `norviq-infra/` (archived).

## Goal
Signed-in users publish long-form, ticker-tagged stock articles (a thesis). Anyone can read them on public,
SEO-indexable web pages and in the iOS app; Discord users can browse and publish via slash commands; every
article can be shared to X, LinkedIn, Discord and Instagram with a good preview card.
Reference product: Probabli's articles (https://probabli.ai/articles/before-the-next-phase-why-2027-could-reprice-nextdecade-15).
Mirror the *shape*, not the branding or text.

## Process
1. Use `superpowers:brainstorming` only to confirm open details below, then write a spec at
   `norviq-backend/docs/superpowers/specs/2026-10-08-articles-design.md` and a plan via
   `superpowers:writing-plans` (model: `2026-10-01-pilot-follow-design.md`). Get user sign-off on the spec.
2. Execute with `superpowers:test-driven-development`, one phase at a time; each phase ends shippable behind
   flags. Stop for user review between phases.
3. Ship order: **Phase 1 backend + web + sharing → Phase 2 Discord → Phase 3 iOS.**

## Data model (backend, new `Sources/StockPlanBackend/Articles/` module)
Do NOT add a `BoardPostKind.article` case — older iOS builds decode `BoardPostKind` from norviq-shared and an
unknown case breaks them. New tables (Fluent migrations, registered in `configure.swift`):
- `articles`: id (uuid), author_id → users, slug, title (≤140), body_markdown (≤20 000), bullet_points
  (text[], exactly 1–3, each ≤240), tickers (text[], 1–5, uppercased, validated against
  `MarketDataService.profile`), disclosure (required, ≤500), cover_image_id?, status
  (`published|hidden|deleted`), source (`web|ios|discord`), view_count, upvote_count, word_count,
  published_at, updated_at. Index on (status, published_at desc) and GIN on tickers.
- `article_votes` (article_id, user_id unique), `article_views` (dedupe per viewer/ip-hash per 24h —
  copy `BoardPostView`), `article_images` (bytea, content_type, ≤2 MB, JPEG/PNG/WebP re-encoded/validated;
  no object storage exists for Norviq — Postgres is fine for v1), `discord_links`
  (user_id unique, discord_user_id unique, linked_at).
- Reports: reuse the Boards report flow/table if it can reference a new target type cleanly; otherwise
  `article_reports`. Every report pings ops Discord via existing `req.discord.send`.

Reuse, don't re-implement: `Community/CommunityAccess.swift` (`CommunityViewer.requireCanContribute()`,
sanctions, guideline acceptance), `Community/CommunityValidation.swift` (`slug()`, `tags()`), `BoardNotifier`
pattern for "your article got upvotes" (1-hour coalescing), `CommunityAdminController` + `AdminGuard` for
hide/unhide + report queue.

## Backend API (hand-written Vapor `RouteCollection`, also documented in `openapi.yaml`;
keep `make backend-openapi-check` green)
- `GET /v1/articles?ticker=&author=&cursor=` (public read: anonymous or `PUBLIC_API_TOKEN`), `GET /v1/articles/:id`
  (counts a view), `GET /v1/articles/:id/cover`.
- `POST /v1/articles`, `PATCH /v1/articles/:id`, `DELETE /v1/articles/:id` (author only), `POST /v1/articles/:id/cover`
  (multipart; set route body limit explicitly — Vapor's default collect size is tiny).
- `POST|DELETE /v1/articles/:id/vote`, `POST /v1/articles/:id/report`.
- Admin: hide/unhide in `CommunityAdminController`.
- Rate limit: 3 articles / user / 24h, 10 edits / hour. Idempotency header on create (existing
  `IdempotencyMiddleware`).
- Flag: `ARTICLES_ENABLED` (env, default false) → routes 404 when off, exactly like `PILOTS_ENABLED`
  (`configure.swift` ~L491). Separate `DISCORD_BOT_ENABLED` for Phase 2.
- Body is Markdown, stored raw. Backend computes word_count and a plain-text excerpt; it never stores HTML.

## norviq-shared
Add `Sources/StockPlanShared/Articles/ArticlesDTOs.swift` (ArticleDTO, ArticleSummaryDTO, Create/Update
requests, ArticleSource, ArticleStatus — make enums tolerant of unknown values). Tag v5.19.0. Backend and iOS
pin by **exact** version; bump both deliberately.

## Web (norviq-web, Go + chi + templ + HTMX)
- Pages in `internal/pages/articles/`, handler `internal/handlers/articles.go`, routes in
  `internal/server/server.go`. Read pages are PUBLIC (outside the logged-in group, like `/s/{symbol}`,
  using `PUBLIC_API_TOKEN` via `config.PublicPagesEnabled()`); write pages require auth.
  - `/articles` feed, `/articles/ticker/{T}`, `/articles/{slug}-{id}` (canonical; redirect wrong slug),
    `/u/{username}/articles`, `/articles/new`, `/articles/{id}/edit`.
  - Detail layout: title, author + date + views, ticker chips (link to `/articles/ticker/{T}` and `/s/{T}`
    when in `internal/publicsymbols`), "Key points" bullet box, cover image, body, disclosure box,
    "Not investment advice" footer, upvote (HTMX), report, share bar, more-on-this-ticker list.
  - Composer: title, tickers (autocomplete), 1–3 bullets, Markdown body with HTMX live preview, disclosure
    (required), cover upload, community-guidelines gate.
- Markdown: goldmark (raw HTML disabled) + bluemonday UGC policy; links `rel="nofollow ugc noopener"`;
  `$TICKER` cashtags auto-link to `/articles/ticker/{T}`.
- Backend client: add `oapi-codegen-articles.yaml` with `include-operation-ids`, generating
  `internal/api/articlesapi` (pattern: `oapi-codegen-pilots.yaml`).
- Gate: `internal/articlegate`, a 404 probe like `internal/pilotgate`; hide nav entry when off.
- SEO: OG `og:type=article`, `article:published_time/modified_time`, `article:tag` per ticker,
  `twitter:card=summary_large_image`, Article JSON-LD (headline, author, datePublished, wordCount);
  add articles to `internal/server/seo.go` sitemap; canonical URL.
- Images, rendered in Go (embedded font, `golang.org/x/image` or `fogleman/gg`), cached by id+updated_at:
  - `/articles/{id}/og.png` 1200×630 → used as `og:image` / `twitter:image`.
  - `/articles/{id}/card.png` 1080×1350 (IG portrait): Norviq mark, tickers, title, the bullets, author,
    short URL.
- Share bar (no third-party JS):
  - X: `https://x.com/intent/post?text={title} ${T}&url={url}`
  - LinkedIn: `https://www.linkedin.com/sharing/share-offsite/?url={url}`
  - Discord: "Copy for Discord" (title + bullets + URL — Discord unfurls the OG card) and, if the author
    linked Discord, "Post to Norviq Discord" (Phase 2).
  - Instagram: on mobile `navigator.share({files:[card.png]})` when `navigator.canShare` allows files; else
    download card.png + copy caption. Add UTM params (`utm_source=x|linkedin|discord|instagram`,
    matching `marketing-plan.md`).
  - Copy link.

## Discord (Phase 2) — HTTP Interactions, no gateway process
- Discord application with Interactions Endpoint URL `https://api.norviq.org/v1/discord/interactions`
  (separate app/channel for staging). Verify `X-Signature-Ed25519` + `X-Signature-Timestamp` with
  `DISCORD_PUBLIC_KEY` (swift-crypto `Curve25519.Signing`); answer PING with type 1; reject bad sigs with 401
  (Discord tests this on save).
- Slash commands (registered by a Vapor async command `discord-register-commands`, using `DISCORD_BOT_TOKEN`):
  - `/article latest [ticker]` → embed list. `/article read <id>` → rich embed (title, tickers, bullets,
    disclosure, link, og.png as image).
  - `/article post` → modal: title, tickers, key points (one per line), body (paragraph, Discord caps at
    4000 chars), disclosure. Unlinked users get an ephemeral "Link your Norviq account" link.
    Validation errors come back ephemeral. Respond within 3 s; do any slow work after a deferred response.
- Account linking: web settings "Connect Discord" → Discord OAuth2 (`identify`) → web callback → backend
  `POST /v1/integrations/discord/link {code, redirectUri}` exchanges the code (`DISCORD_CLIENT_ID/SECRET`),
  stores `discord_links`. Unlink endpoint too. Sanctions apply to Discord-sourced posts the same way.
- Auto-post every newly published article as a rich embed to `#articles` via `DISCORD_ARTICLES_WEBHOOK_URL`.
  Extend `Services/DiscordWebhookService.swift` with an embed-capable, named-webhook send. Do NOT reuse
  `DISCORD_WEBHOOK_URL` — that is the ops/alerts channel (signups, reports). Fire-and-forget; failure must
  not fail the publish.
- Hidden/deleted articles: delete the Discord message if we stored its id (webhook `?wait=true` returns it).

## iOS (Phase 3, `norviq-ios/financeplan`, new `Features/Articles/`)
- Feed (all / by ticker / mine), detail (Markdown via `AttributedString(markdown:)` or existing renderer —
  check `Features/Boards` first), composer (PhotosPicker cover), upvote, report, link Discord in settings.
- Ticker entry point: "Articles" section on the stock detail screen.
- Share: `ShareLink` with URL; "Share card" fetches `card.png` and presents it so Instagram appears in the
  sheet. Reuse `Features/Stocks/StockChannelShareSupport.swift` (`StockShareDestination`) for share text.
- Hide everything when the backend 404s (flag off). Follow `swiftui-design-principles`.

## Infra (in `~/Work/production/platform/infra` only)
- `apps/norviq/api/values-{common,staging,production}.yaml`: `ARTICLES_ENABLED` / `DISCORD_BOT_ENABLED`
  "true" in staging, "false" in common/production.
- Sealed secrets in `secrets/norviq/{staging,production}/`: `DISCORD_APPLICATION_ID`, `DISCORD_PUBLIC_KEY`,
  `DISCORD_BOT_TOKEN`, `DISCORD_CLIENT_ID`, `DISCORD_CLIENT_SECRET`, `DISCORD_ARTICLES_WEBHOOK_URL`. Seal for
  namespace **`norviq`** / **`norviq-staging`** (NOT `production`, which is LuminaVault's) — a wrong-namespace
  blob fails silently. Follow `secrets/norviq/*/README.md`.
- Web: `PUBLIC_API_TOKEN` must already be set for public pages; also add `DISCORD_CLIENT_ID` + OAuth redirect
  for linking.

## Gotchas
- Deploys are manual: merge → dispatch "Deploy to k3s (staging)" per repo → `promote-norviq.yml` with
  explicit `-f service=both` (it defaults to api only).
- Backend pre-commit hook may reformat the whole repo with a local swiftformat that disagrees with CI —
  check `git show --stat` after committing.
- Migrations run as an ArgoCD PreSync hook; they must be safe while the flag is off.
- Legal: disclosure is mandatory; render "Not investment advice — user-generated opinion" on every
  article, card and embed. Get the user's compliance read before flipping production on.

## Out of scope for v1
Comments (add later, reusing the Boards comment tree), paid/contributor tiers, follow-author, AI summaries,
automatic posting to users' own X/LinkedIn accounts (needs their OAuth + API costs), Instagram Graph API.

## Done when
- Backend: Swift tests for validation, rate limit, vote idempotency, view dedupe, sanctions, flag-off 404,
  Discord signature verification (valid/invalid/stale), modal → article.
- Web: Go tests for handlers, markdown sanitisation (XSS payloads stripped), OG tags, og.png/card.png sizes
  (pattern: `og_image_test.go`), share URLs encoded correctly.
- Staging E2E: publish on web → visible at `/articles/{slug}-{id}` logged out → embed appears in staging
  `#articles` → X/LinkedIn preview shows og.png (check via the platforms' card validators/post inspector) →
  card.png shares to Instagram from an iPhone → `/article post` from Discord creates an article tied to the
  linked account → admin hide removes it from feed and Discord → iOS reads, composes, shares.
- Production flags stay off until the user says go.
