# Norviq Articles — design

Date: 2026-10-08 · Status: draft for review · Prompt: `docs/superpowers/prompts/2026-10-08-articles-prompt.md`

## 1. Intent

**What the user asked for.** A Norviq version of Probabli's articles
(<https://probabli.ai/articles/before-the-next-phase-why-2027-could-reprice-nextdecade-15>). Signed-in users
publish long-form, ticker-tagged stock write-ups. The articles are readable on the web and in iOS, can be
posted and read from Discord, and can be shared to X, LinkedIn, Discord and Instagram.

**Decided with the user (2026-10-08):**
- Surfaces: backend, web, iOS, plus a norviq-shared bump.
- Discord: a full bot, including posting from Discord, tied to the Norviq account through linking.
- Instagram: a server-generated share card.
- Authors: any signed-in user. Moderation happens after publishing: report, admin hide, required
  disclosure, rate limit.
- Ship order: Phase 1 is backend + web + sharing. Phase 2 is Discord. Phase 3 is iOS. Each phase ships
  behind a flag that is on in staging and off in production.

**Success.** A logged-out visitor opens a shared link and sees a full article with a rich preview card on
X, LinkedIn and Discord. A Discord member can publish without opening the site. Production stays off until
the user signs off on compliance.

**Assumptions (correct me):**
- The body is Markdown, not Probabli's HTML.
- One cover image per article. No inline images.
- No comments in v1.
- Authors can edit any time; the page shows "edited".

## 2. Reference shape (Probabli)

Taken from Probabli's public `GET /api/articles/15` and its JSON-LD:
- Fields: `title`, `body` (HTML), `tickerSymbols[]`, `imageUrl?`, `bulletPoints[3]`, `disclosure`,
  `viewCount`, `upvotes`, `userUpvoted`, `createdAt`, `updatedAt`, `authorDisplayName`,
  `authorIsContributor`.
- URLs: `/articles/{slug}-{id}` and `/articles/ticker/{T}`.
- Meta: OG `og:type=article`, `summary_large_image`, `article:published_time`, and an Article JSON-LD
  block with `wordCount`.

## 3. Architecture

```
iOS ──session──┐
web (logged-in)─┤ user token
web (public) ───┤ PUBLIC_API_TOKEN (PAT, market:read)      ┌─ social_reports (target_type=article)
Discord ─HTTP interactions (Ed25519)──► backend Articles ──┼─ articles / article_votes / article_views / article_images
                                         module            ├─ discord_links
                                                           └─► #articles webhook (embed)  ·  ops webhook (reports)
web renders: markdown → HTML, og.png 1200×630, card.png 1080×1350
```

The backend owns the data and its rules. The web owns rendering: Markdown → HTML, the images, the share
links and SEO. Discord talks only to the backend. iOS uses the same REST API as the web.

## 4. Backend (`Sources/StockPlanBackend/Articles/`)

### 4.1 Tables (one migration, `CreateArticlesTables`, registered in `configure.swift`)

| table | columns |
|---|---|
| `articles` | `id uuid pk`, `author_id → users`, `slug text`, `title text`, `body_markdown text`, `bullet_points text[]`, `tickers text[]`, `disclosure text`, `cover_image_id uuid?`, `status text` (`published\|hidden\|deleted`), `source text` (`web\|ios\|discord`), `view_count int`, `upvote_count int`, `word_count int`, `discord_message_id text?`, `published_at`, `edited_at?`, `created_at`, `updated_at` |
| `article_votes` | `article_id`, `user_id`, `created_at`; unique(article_id, user_id) |
| `article_views` | `article_id`, `viewer_key text` (user id or salted IP hash), `day date`; unique(article_id, viewer_key, day). Same pattern as `BoardPostView` |
| `article_images` | `id`, `owner_id`, `content_type`, `bytes bytea`, `width`, `height`, `created_at` |
| `discord_links` | `user_id unique`, `discord_user_id unique`, `discord_username`, `linked_at` |

Indexes: `(status, published_at desc)`, GIN on `tickers`, `(author_id, published_at desc)`.

Reports reuse **`social_reports`** with `target_type = "article"`, the same way Boards uses it. The admin
report queue then shows them with no new table.

### 4.2 Validation (`ArticleValidation.swift`)

Error wording follows `CommunityValidation`.
- **Title:** 8–140 chars.
- **Body:** 300–20 000 chars of Markdown.
- **Bullet points:** 1–3 items, each 10–240 chars.
- **Tickers:** 1–5 tickers, uppercased, deduplicated, each matching `^[A-Z][A-Z0-9.\-]{0,9}$`.
  - Each ticker is checked with the market data `profile`.
  - "Not found" rejects the ticker.
  - A provider error or rate limit accepts it, so FMP/Finnhub quota never blocks publishing. The event is
    logged.
- **Disclosure:** required, 10–500 chars. The composer offers presets: "I hold a position in …",
  "No position", "I may trade within 72h".
- **Slug:** from `CommunityValidation.slug()`, max 80 chars.
- **Word count:** computed on the server from the body with Markdown stripped.

### 4.3 Routes (hand-written `ArticlesController`, documented in `openapi.yaml`, `make backend-openapi-check` stays green)

**Read routes:** `ScopedBearerAuthenticator`, `SessionToken.guardMiddleware`, and
`ScopeRequirementMiddleware(.marketRead)`. This accepts first-party sessions and the web's existing
`PUBLIC_API_TOKEN` PAT with no re-mint.

- `GET /v1/articles?ticker=&author=&cursor=&limit=` returns summaries, newest first, `published` only.
  The cursor is `(published_at, id)`.
- `GET /v1/articles/:id` returns the full article, plus `viewerUpvoted` and `viewerIsAuthor` when the
  caller is a real user.
  - Counts a view, deduplicated per viewer per day.
  - For PAT calls, the web forwards the visitor's IP hash in `X-Norviq-Viewer`.
  - `hidden` and `deleted` articles return 404, except to the author and admins.
- `GET /v1/articles/:id/cover` returns the image bytes with `Cache-Control: public, max-age=86400` and an
  ETag.

**Write routes:** `ScopedBearerAuthenticator`, `SessionToken.guardMiddleware`, `FirstPartyOnlyMiddleware`
and `CommunityAccessMiddleware`, plus `viewer.requireCanContribute()` and guideline acceptance. This is the
same gate Boards uses.

- `POST /v1/articles` (rate limit 3 per 24h, key `ratelimit:article-create`; honours an `Idempotency-Key`
  header via the global `IdempotencyMiddleware`).
- `PATCH /v1/articles/:id` (author only; 10 per hour; sets `edited_at`).
- `DELETE /v1/articles/:id` (author only; soft delete).
- `POST /v1/articles/images`: multipart, `body: .collect(maxSize: "3mb")`. Accepts JPEG, PNG or WebP of at
  most 2 MB and at most 4096 px on a side, checked from magic bytes and the decoded header. Returns
  `{id}`, which the create/update call then references.
- `POST|DELETE /v1/articles/:id/vote` (60 per minute; idempotent; keeps `upvote_count` in step).
- `POST /v1/articles/:id/report` (20 per hour). Writes a `social_reports` row and pings ops through
  `req.discord.send`. Muted users can still report.

**Admin:** `POST /v1/admin/articles/:id/hide|unhide` in `CommunityAdminController` behind `AdminGuard`.

**Upvote notifications:** go to the author, coalesced over one hour, following `BoardNotifier.upvoted()`.
This reuses the `board_notifications` table and needs no new shared notification kind; it uses the
existing `other` kind with an `articleId` payload. The plan must confirm `board_notifications` can carry that target; if it cannot, add an `article_id` column, not a new shared kind.

### 4.4 Flags

- `ARTICLES_ENABLED`: `envBool`, default false. When off, every article route 404s. Same pattern as
  `PILOTS_ENABLED` in `configure.swift`.
- `DISCORD_BOT_ENABLED` (Phase 2): when off, `/v1/discord/*` and `/v1/integrations/discord/*` 404.
- The migration always runs (as an ArgoCD PreSync hook) and has no effect while the flag is off.

## 5. norviq-shared v5.19.0

Add `Sources/StockPlanShared/Articles/ArticlesDTOs.swift`:
- `ArticleSummaryDTO`, `ArticleDTO`, `ArticleAuthorDTO` (id, username, avatarURL).
- `CreateArticleRequest`, `UpdateArticleRequest`, `ArticleListResponse` (items, nextCursor).
- `ArticleSource` and `ArticleStatus`: string-backed, each with an `unknown` fallback decode.

The backend pins `exact: "5.19.0"` in Phase 1. iOS pins it in Phase 3.

## 6. Web (Phase 1)

### 6.1 Routes (`internal/server/server.go`)

- **Public group:** same placement as `/s/{symbol}`; enabled only when `config.PublicPagesEnabled()` and
  the article gate are both on.
  - `GET /articles`: feed, 20 per page, "Load more" via HTMX.
  - `GET /articles/ticker/{T}`
  - `GET /articles/{slugid}`: parses the trailing `-{uuid}` and 301s to the canonical slug.
  - `GET /u/{username}/articles`
  - `GET /articles/{id}/og.png`, `GET /articles/{id}/card.png`, `GET /articles/{id}/cover`. The cover is
    proxied so the backend URL is never exposed.
- **Logged-in group:**
  - `GET|POST /articles/new`, `GET|POST /articles/{id}/edit`, `POST /articles/{id}/delete`
  - `POST /articles/{id}/vote`
  - `POST /articles/{id}/report`
  - `POST /articles/preview`: HTMX endpoint for the Markdown preview.
  - `POST /articles/images`

Logged-in visitors read through their own token, so `viewerUpvoted` works. Anonymous visitors read
through the PAT.

### 6.2 Code layout

- `internal/handlers/articles.go`
- `internal/pages/articles/{feed,detail,compose}.templ`
- `internal/pages/articles/viewmodel.go`
- `internal/articlegate`: 404 probe, copied from `internal/pilotgate`
- `internal/markdown`: goldmark with GFM tables and autolinks, raw HTML off. Output goes through the
  bluemonday `UGCPolicy`. Links get `rel="nofollow ugc noopener"`. `$TICKER` cashtags link to
  `/articles/ticker/T`.
- `internal/sharecard`: PNG rendering with `golang.org/x/image/font/opentype` and an embedded Inter font.
  Results go into an LRU keyed by `id + updatedAt`.
- Backend client: `oapi-codegen-articles.yaml` with `include-operation-ids`, generating
  `internal/api/articlesapi`.

### 6.3 Detail page

In order:
1. Breadcrumb (Articles › $T).
2. Title.
3. Author (avatar, @username), date, "edited", reading time, views.
4. Ticker chips. Each links to `/articles/ticker/T`, and also to `/s/T` when the ticker is in
   `publicsymbols`.
5. "Key points" box with the bullets.
6. Cover image.
7. Body.
8. Disclosure box.
9. Footer: "User-generated opinion. Not investment advice."
10. Action row: upvote, share bar, report.
11. "More on $T": 3 recent articles.

### 6.4 SEO

- `<title>{title} — Norviq</title>` and a description from the first bullet.
- Canonical URL.
- OG tags: `og:type=article`, `og:image` pointing to `og.png` (1200×630), `article:published_time`,
  `article:modified_time`, and one `article:tag` per ticker.
- `twitter:card=summary_large_image` and `twitter:site=@NorviqPlanner`.
- Article JSON-LD: headline, author, datePublished, dateModified, wordCount, image.
- `internal/server/seo.go` adds the newest 500 published articles to the sitemap.

### 6.5 Share bar

Server-built links. `{url}` is the canonical URL plus `utm_source={network}&utm_medium=share`.

| network | behaviour |
|---|---|
| X | `https://x.com/intent/post?text={urlencode(title + " $T1 $T2")}&url={url}` |
| LinkedIn | `https://www.linkedin.com/sharing/share-offsite/?url={url}` |
| Discord | "Copy for Discord" puts `**{title}**\n• b1\n• b2\n{url}` on the clipboard; Discord unfurls the og.png. Phase 2 adds "Post to Norviq Discord" for linked authors. |
| Instagram | Fetches `card.png` as a File. If `navigator.canShare({files})`, calls `navigator.share`. Otherwise downloads the file and copies a caption (title, cashtags, link-in-bio note). |
| Copy link | clipboard |

All of this is a small inline script; no third-party share widgets.

### 6.6 Cards

Both cards use the dark Norviq palette and say "Not investment advice".
- `og.png`, 1200×630: wordmark, ticker chips, title (wraps to at most 3 lines with an ellipsis),
  @author, date.
- `card.png`, 1080×1350: wordmark, ticker chips, title, up to 3 bullets (each truncated), @author,
  `{PUBLIC_BASE_URL}/a/{shortid}`.

`GET /a/{shortid}` redirects to the canonical URL. The short id is the first 8 hex chars of the uuid; on a
collision the handler falls back to a lookup by prefix.

## 7. Discord (Phase 2)

### 7.1 Transport

Discord sends interactions over HTTP to `POST https://api.norviq.org/v1/discord/interactions`. No gateway
connection and no extra pod.
- Verify Ed25519 over `timestamp + rawBody` with `DISCORD_PUBLIC_KEY`, using the `Crypto` module already
  imported in the backend. Reject requests older than 5 minutes and bad signatures with 401.
- PING gets a type-1 reply.
- Staging uses a separate Discord application, pointed at the staging API host.

### 7.2 Commands

Registered by `swift run App discord-register-commands`, an async command that uses
`DISCORD_APPLICATION_ID` and `DISCORD_BOT_TOKEN` and is idempotent (bulk overwrite).
- `/article latest [ticker]` replies with an embed list of 5 articles (title, cashtags, author, link).
- `/article read id:<short id or url>` replies with one rich embed: title, url, bullets, tickers,
  disclosure, `og.png` as the image, and footer "Not investment advice".
- `/article post` opens a modal with 5 inputs:
  - title
  - tickers (comma separated)
  - key points (paragraph, one per line)
  - body (paragraph, max 4000, Discord's limit)
  - disclosure

  On submit, the same `ArticleService.create` path runs with `source=discord`, under the same
  validation, rate limit and sanctions. Errors come back ephemeral. Success replies with the article link.
  A cover can be added later on the web or iOS.
- An unlinked Discord user gets an ephemeral "Link your Norviq account" reply linking to
  `{web}/settings/integrations/discord`.

### 7.3 Account linking

1. Web settings → Discord OAuth2 authorize with scope `identify`.
2. The web callback calls `POST /v1/integrations/discord/link {code, redirectUri}`.
3. The backend exchanges the code with `DISCORD_CLIENT_ID` and `DISCORD_CLIENT_SECRET`, fetches
   `/users/@me`, and upserts `discord_links`. It returns 409 if that Discord account is linked to someone
   else.
4. `DELETE /v1/integrations/discord/link` unlinks.

### 7.4 Auto-post

After publish, a detached `Task` posts an embed to `DISCORD_ARTICLES_WEBHOOK_URL` with `?wait=true` and
stores `discord_message_id`.
- Hide or delete removes that message. Edits update it.
- Failures are logged and never fail the request.
- `DiscordWebhookService` gains `sendEmbed(_:to:)` with a named destination enum: `.ops` (the existing
  `DISCORD_WEBHOOK_URL`) and `.articles`. Article content never goes to `.ops`.

## 8. iOS (Phase 3, `Features/Articles/`)

- **Screens:**
  - `ArticlesFeedView`: segments All / By ticker / Mine.
  - `ArticleDetailView`: Markdown through `AttributedString(markdown:)`, or the Boards renderer if one
    exists.
  - `ArticleComposerView`: the same fields as the web, `PhotosPicker` for the cover, draft autosave.
- **Entry points:**
  - A segment in the existing Boards area.
  - An "Articles about $T" section on stock detail.
  - Settings → Integrations → Discord, which opens the web OAuth flow in `ASWebAuthenticationSession`.
- **Sharing:**
  - `ShareLink(item: url)`.
  - "Share card" downloads `card.png` and presents the share sheet with the image, so Instagram, Stories
    and Messages appear there.
  - Share text comes from `StockChannelShareSupport` (`StockShareDestination`).
- **Gate:** a 404 from `/v1/articles` hides every entry point.

## 9. Infra (`~/Work/production/platform/infra` only)

- `apps/norviq/api/values-common.yaml` and `values-production.yaml`: `ARTICLES_ENABLED: "false"`,
  `DISCORD_BOT_ENABLED: "false"`.
- `values-staging.yaml`: both `"true"`.
- Sealed secrets for namespaces **`norviq-staging`** and **`norviq`**:
  - `DISCORD_APPLICATION_ID`, `DISCORD_PUBLIC_KEY`, `DISCORD_BOT_TOKEN`
  - `DISCORD_CLIENT_ID`, `DISCORD_CLIENT_SECRET`
  - `DISCORD_ARTICLES_WEBHOOK_URL`

  Follow `secrets/norviq/*/README.md`. A blob sealed for the wrong namespace fails silently.
- Web values: `DISCORD_CLIENT_ID` and `DISCORD_OAUTH_REDIRECT_URL`. `PUBLIC_API_TOKEN` and
  `PUBLIC_BASE_URL` already exist.
- The user creates the Discord applications and the `#articles` channel webhooks. This needs their Discord
  admin access.

## 10. Error handling

| case | behaviour |
|---|---|
| Flag off | 404 everywhere; web hides nav; iOS hides entry points |
| Validation | 400 with a field-specific `reason`; web re-renders the form with errors inline; Discord replies ephemeral |
| Muted / banned | 403 with the existing community error shape (`expiresAt`) |
| Rate limited | 429; web shows "You can publish 3 articles a day" |
| Market provider down during ticker check | ticker accepted, warning logged |
| Webhook / Discord API failure | logged; publish still succeeds |
| Image too large or wrong type | 413 / 415 with a reason |
| Bad Discord signature | 401, no body |

## 11. Testing

- **Backend (XCTVapor, real Postgres like the existing tests):**
  - validation table tests
  - create/edit/delete permissions
  - rate limit
  - vote idempotency and counter correctness
  - view dedupe
  - mute/ban
  - hidden articles 404 for others
  - flag-off 404
  - report row and ops ping (mock `DiscordWebhookService`)
  - image magic-byte rejection
  - Discord: valid, invalid and stale signatures; PING; modal submit to article; unlinked user;
    link-code exchange with a stubbed client
- **Web (Go):**
  - handler tests against a fake articles client
  - Markdown XSS corpus stripped (`<script>`, `javascript:` links, event attributes)
  - cashtag links
  - canonical 301
  - OG and JSON-LD present
  - `og.png` is 1200×630 and `card.png` is 1080×1350 (pattern: `og_image_test.go`)
  - share URLs encoded correctly
  - sitemap includes articles only when the gate is on
- **Staging E2E per phase:** the checklist in the prompt's "Done when".

## 12. Out of scope (v1)

- comments
- contributor or paid tiers
- following authors
- AI summaries
- posting to users' own X/LinkedIn accounts
- Instagram Graph API
- inline body images
- trending ranking (feeds are chronological)

## 13. Rollout

Each phase: TDD, then merge, then dispatch the staging deploy for each touched repo, then E2E on staging,
then a user review.

Production stays off until the user:
1. reads the disclosure and "not investment advice" wording for compliance,
2. creates the production Discord app, and
3. says go.

Promote with `-f service=both`.
