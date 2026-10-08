# Norviq Articles — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Signed-in users publish ticker-tagged stock articles through the backend and web. Logged-out visitors can read them on public, crawlable pages, and every article can be shared to X, LinkedIn, Discord and Instagram with generated preview cards. Everything sits behind `ARTICLES_ENABLED`.

**Architecture:**
- A new `Articles` module in the Vapor backend owns data and rules. Reads accept the web's existing `PUBLIC_API_TOKEN` (scope `market:read`); writes go through the Boards community gate.
- norviq-shared v5.19.0 carries the DTOs.
- The Go web app renders Markdown, the public pages, the composer, the share bar and the PNG cards. It calls the backend through a hand-written client (same as Boards).
- Infra flips the flag on in staging only.

**Tech Stack:**
- Backend: Swift 6, Vapor 4, Fluent/Postgres, Swift Testing.
- Web: Go 1.27, chi, templ, HTMX, goldmark, bluemonday, golang.org/x/image (gofont), testify.

**Spec:** `norviq-backend/docs/superpowers/specs/2026-10-08-articles-design.md` (approved 2026-10-08)

## Deviations from the spec (decided while planning; listed so a reviewer can veto them)

1. **URLs use an 8-char `code`, not the uuid.**
   - Paths are `/articles/{slug}-{code}` and the short link is `/a/{code}`.
   - The code comes from `abcdefghjkmnpqrstuvwxyz23456789` and is unique-indexed.
   - The backend accepts a uuid *or* a code as `:ref`.
   - Why: the spec's 8-hex prefix with prefix lookup was fragile.
2. **Views are counted by a beacon (`POST /articles/{code}/view` → `POST /v1/articles/:ref/view`), not on GET.**
   - Why: anonymous article pages are cached for 15 minutes like `/s/{symbol}`, so a GET-time count would count one view per cache fill.
3. **The web client is hand-written (`internal/api/articles.go`, reusing `doBoardsRequest`), not oapi-codegen.**
   - Boards set this precedent.
   - The main generated client is pinned to an old spec revision.
4. **Upvote notifications are deferred to a later phase.**
   - `board_notifications.post_id` is a required foreign key to `board_posts`, so articles can't ride on it without a schema change and a shared-DTO change.
5. **Cards use the Go fonts (`gofont/gobold`, `goregular`), not Inter.**
   - `opentype` needs TTF, and the repo only ships web fonts.
6. **Phase 2 columns (`discord_message_id`, `discord_links`) are not created here.** Phase 2 adds its own migration.
7. **Feeds page with a plain "Older articles" link (no HTMX "Load more"), and are not held in the in-process page cache.**
   - That cache never evicts, and feed keys (cursor, ticker) are visitor-controlled.
   - Feeds get a 2-minute CDN `max-age` instead.
   - Only article pages and cards, which are bounded by the number of articles, are cached in-process.

## Global Constraints

- Feature flag: `ARTICLES_ENABLED` (backend env, default `false`). When it is off, every `/v1/articles*` and `/v1/admin/articles*` route returns 404.
- Field limits:
  - title 8–140 chars
  - body 300–20 000 chars of Markdown
  - bullet points 1–3, each 10–240 chars
  - tickers 1–5, each matching `^[A-Z][A-Z0-9.-]{0,9}$` after trim, a leading `$` stripped, and uppercasing
  - disclosure 10–500 chars
  - slug max 80
- Daily cap: 3 articles per author per 24h, enforced against the DB (`article_daily_limit`, 429). Admins are exempt.
- Images: JPEG/PNG/WebP, ≤ 2 MB, ≤ 4096 px per side, checked by magic bytes plus the header. The route body limit is `3mb`.
- Every rendered article, card and caption carries: **"User-generated opinion. Not investment advice."**
- Twitter handle: `@NorviqPlanner`. The OG image is 1200×630. The Instagram card is 1080×1350.
- Infra changes go only in `~/Work/production/platform/infra`. Branch from `main` there; that checkout is currently on `feat/observability-tealweevil`.
- norviq-shared is pinned by **exact** version. This phase bumps the backend to `5.19.0`; iOS waits for Phase 3.
- Backend commits: the pre-commit hook may reformat the whole repo. After each commit, run `git show --stat HEAD`. If unrelated files appear, `git reset --soft HEAD~1`, restore them, and recommit with `--no-verify`.
- Do not touch the unrelated, uncommitted `Dockerfile` change in norviq-web.
- Deploys are manual: dispatch "Deploy to k3s (staging)" in each repo, then run `promote-norviq.yml -f service=both`. Production stays off.

## Review Focus

1. **A logged-in visitor sees a cached anonymous page, or an anonymous visitor gets someone's CSRF cookie.**
   - Expected: only session-less requests use the cache and strip `Set-Cookie`/`Vary: Cookie`.
   - Pinned by `TestDetailAnonymousIsCachedAndCookieless` and `TestDetailSignedInIsPersonalAndUncached` (Task 14).
2. **A hostile Markdown body.**
   - Inputs: `<script>`, `<img onerror>`, `[x](javascript:alert(1))`, raw `<iframe>`.
   - Expected: everything stripped and links safe.
   - Pinned by `TestRenderStripsDangerousMarkup` (Task 10).
3. **A wrong or stale slug in the URL (`/articles/old-title-abcd2345`), or a bare code.**
   - Expected: 301 to the canonical slug, not a 404.
   - Pinned by `TestDetailRedirectsToCanonicalSlug` (Task 14).
4. **A ticker lookup while the market provider is down or out of quota.**
   - Expected: publish still succeeds and the event is logged.
   - Pinned by `unavailableTickerIsAccepted` (Task 5).
5. **A hidden article reached by a direct link or the short link.**
   - Expected: 404 for everyone except the author and admins, and it disappears from feeds.
   - Pinned by `hiddenIsAuthorAndAdminOnly` (Task 7) and `TestHiddenArticle404sPublicly` (Task 14).

---

# Part A — norviq-shared

### Task 1: Articles DTOs (v5.19.0)

**Files:**
- Create: `norviq-shared/Sources/StockPlanShared/Articles/ArticlesDTOs.swift`
- Test: `norviq-shared/Tests/StockPlanSharedTests/ArticlesDTOsTests.swift`

**Interfaces:**
- Produces (used by Tasks 2–8, and by iOS in Phase 3):
  - `ArticleSource {web, ios, discord, unknown}`
  - `ArticleStatus {published, hidden, deleted, unknown}`
  - `ArticleAuthor(id: UUID, username: String?, avatarURL: String?)`
  - `ArticleSummary(id, code, slug, title, bulletPoints, tickers, author, coverImageId: UUID?, upvoteCount, viewCount, wordCount, status, source, publishedAt: Date, editedAt: Date?)`
  - `ArticleDetail(article: ArticleSummary, bodyMarkdown, disclosure, viewerUpvoted, viewerIsAuthor)`
  - `ArticleListResponse(items, nextCursor: String?)`
  - `ArticleWriteRequest(title, bodyMarkdown, bulletPoints, tickers, disclosure, coverImageId: UUID?, source: ArticleSource?)`
  - `ArticleVoteResponse(upvoteCount, voted)`
  - `ArticleReportRequest(reason: BoardReportReason, note: String?)`
  - `ArticleImageUploadResponse(id: UUID)`
  - `ArticleVisibilityRequest(hidden: Bool)`

- [ ] **Step 1: Branch**

```bash
cd ~/Work/production/apps/norviq/norviq-shared && git checkout main && git pull && git checkout -b feat/articles-dtos
```

- [ ] **Step 2: Write the failing test**

```swift
import Foundation
import StockPlanShared
import Testing

@Suite("ArticlesDTOs")
struct ArticlesDTOsTests {
    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    @Test("write request round-trips with camelCase keys")
    func writeRequestRoundTrip() throws {
        let request = ArticleWriteRequest(
            title: "Why 2027 could reprice NEXT",
            bodyMarkdown: "Body",
            bulletPoints: ["First LNG in 1H 2027"],
            tickers: ["NEXT"],
            disclosure: "I hold $NEXT.",
            coverImageId: nil,
            source: .web
        )
        let data = try encoder.encode(request)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"bodyMarkdown\":\"Body\""))
        #expect(json.contains("\"bulletPoints\":[\"First LNG in 1H 2027\"]"))
        #expect(json.contains("\"source\":\"web\""))
        #expect(try decoder.decode(ArticleWriteRequest.self, from: data) == request)
    }

    @Test("detail round-trips including dates")
    func detailRoundTrip() throws {
        let summary = ArticleSummary(
            id: UUID(), code: "abcd2345", slug: "why-2027", title: "Why 2027",
            bulletPoints: ["One key point here"], tickers: ["NEXT"],
            author: ArticleAuthor(id: UUID(), username: "ana", avatarURL: nil),
            coverImageId: nil, upvoteCount: 6, viewCount: 1715, wordCount: 589,
            status: .published, source: .web,
            publishedAt: Date(timeIntervalSince1970: 1_790_000_000), editedAt: nil
        )
        let detail = ArticleDetail(article: summary, bodyMarkdown: "Body", disclosure: "No position", viewerUpvoted: true, viewerIsAuthor: false)
        let decoded = try decoder.decode(ArticleDetail.self, from: encoder.encode(detail))
        #expect(decoded == detail)
    }

    @Test("unknown status and source decode as .unknown so a newer server never breaks an older client")
    func unknownEnums() throws {
        #expect(try decoder.decode([ArticleStatus].self, from: Data("[\"archived\",\"hidden\"]".utf8)) == [.unknown, .hidden])
        #expect(try decoder.decode([ArticleSource].self, from: Data("[\"telegram\",\"discord\"]".utf8)) == [.unknown, .discord])
    }
}
```

- [ ] **Step 3: Run the test and check it fails**

Run: `swift test --filter ArticlesDTOsTests`
Expected: FAIL to compile with "cannot find 'ArticleWriteRequest' in scope".

- [ ] **Step 4: Write the DTOs**

```swift
import Foundation

// MARK: - Enums

/// Where an article was written. Decodes unknown values as `.unknown` so an
/// older client keeps working when a new surface is added.
public enum ArticleSource: String, Codable, CaseIterable, Sendable {
    case web
    case ios
    case discord
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ArticleSource(rawValue: raw) ?? .unknown
    }
}

/// `hidden` is a moderator action; `deleted` is the author's soft delete.
public enum ArticleStatus: String, Codable, CaseIterable, Sendable {
    case published
    case hidden
    case deleted
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ArticleStatus(rawValue: raw) ?? .unknown
    }
}

// MARK: - Read models

public struct ArticleAuthor: Codable, Sendable, Equatable {
    public let id: UUID
    public let username: String?
    public let avatarURL: String?

    public init(id: UUID, username: String?, avatarURL: String?) {
        self.id = id
        self.username = username
        self.avatarURL = avatarURL
    }
}

/// Feed row. `code` is the short, URL-safe id used in links.
public struct ArticleSummary: Codable, Sendable, Equatable {
    public let id: UUID
    public let code: String
    public let slug: String
    public let title: String
    public let bulletPoints: [String]
    public let tickers: [String]
    public let author: ArticleAuthor
    public let coverImageId: UUID?
    public let upvoteCount: Int
    public let viewCount: Int
    public let wordCount: Int
    public let status: ArticleStatus
    public let source: ArticleSource
    public let publishedAt: Date
    public let editedAt: Date?

    public init(
        id: UUID, code: String, slug: String, title: String, bulletPoints: [String], tickers: [String],
        author: ArticleAuthor, coverImageId: UUID?, upvoteCount: Int, viewCount: Int, wordCount: Int,
        status: ArticleStatus, source: ArticleSource, publishedAt: Date, editedAt: Date?
    ) {
        self.id = id
        self.code = code
        self.slug = slug
        self.title = title
        self.bulletPoints = bulletPoints
        self.tickers = tickers
        self.author = author
        self.coverImageId = coverImageId
        self.upvoteCount = upvoteCount
        self.viewCount = viewCount
        self.wordCount = wordCount
        self.status = status
        self.source = source
        self.publishedAt = publishedAt
        self.editedAt = editedAt
    }
}

public struct ArticleDetail: Codable, Sendable, Equatable {
    public let article: ArticleSummary
    public let bodyMarkdown: String
    public let disclosure: String
    public let viewerUpvoted: Bool
    public let viewerIsAuthor: Bool

    public init(article: ArticleSummary, bodyMarkdown: String, disclosure: String, viewerUpvoted: Bool, viewerIsAuthor: Bool) {
        self.article = article
        self.bodyMarkdown = bodyMarkdown
        self.disclosure = disclosure
        self.viewerUpvoted = viewerUpvoted
        self.viewerIsAuthor = viewerIsAuthor
    }
}

public struct ArticleListResponse: Codable, Sendable, Equatable {
    public let items: [ArticleSummary]
    public let nextCursor: String?

    public init(items: [ArticleSummary], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

// MARK: - Writes

/// Create and full-replace update share one shape. `source` is ignored on update.
public struct ArticleWriteRequest: Codable, Sendable, Equatable {
    public let title: String
    public let bodyMarkdown: String
    public let bulletPoints: [String]
    public let tickers: [String]
    public let disclosure: String
    public let coverImageId: UUID?
    public let source: ArticleSource?

    public init(
        title: String, bodyMarkdown: String, bulletPoints: [String], tickers: [String],
        disclosure: String, coverImageId: UUID?, source: ArticleSource?
    ) {
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.bulletPoints = bulletPoints
        self.tickers = tickers
        self.disclosure = disclosure
        self.coverImageId = coverImageId
        self.source = source
    }
}

public struct ArticleVoteResponse: Codable, Sendable, Equatable {
    public let upvoteCount: Int
    public let voted: Bool

    public init(upvoteCount: Int, voted: Bool) {
        self.upvoteCount = upvoteCount
        self.voted = voted
    }
}

public struct ArticleReportRequest: Codable, Sendable, Equatable {
    public let reason: BoardReportReason
    public let note: String?

    public init(reason: BoardReportReason, note: String?) {
        self.reason = reason
        self.note = note
    }
}

public struct ArticleImageUploadResponse: Codable, Sendable, Equatable {
    public let id: UUID

    public init(id: UUID) {
        self.id = id
    }
}

public struct ArticleVisibilityRequest: Codable, Sendable, Equatable {
    public let hidden: Bool

    public init(hidden: Bool) {
        self.hidden = hidden
    }
}
```

- [ ] **Step 5: Run the tests and check they pass**

Run: `swift test --filter ArticlesDTOsTests && swift test`
Expected: PASS. The full suite is green.

- [ ] **Step 6: Commit, merge and tag**

```bash
git add Sources/StockPlanShared/Articles Tests/StockPlanSharedTests/ArticlesDTOsTests.swift
git commit -m "feat(articles): add Articles DTOs"
```

Then **ask the user before pushing.** A tag on a shared package is outward-facing. Once they approve:

```bash
git checkout main && git merge --ff-only feat/articles-dtos && git push origin main
git tag v5.19.0 && git push origin v5.19.0
```

---

# Part B — norviq-backend (branch `feat/articles`, already created; it holds the spec commit)

### Task 2: Pin shared 5.19.0 and add pure validation

**Files:**
- Modify: `norviq-backend/Package.swift:9` (`exact: "5.18.0"` → `exact: "5.19.0"`)
- Create: `norviq-backend/Sources/StockPlanBackend/Articles/ArticleValidation.swift`
- Test: `norviq-backend/Tests/StockPlanBackendTests/ArticleValidationTests.swift`

**Interfaces:**
- Produces:
  - `ArticleValidation.title(_:) throws -> String`
  - `.body(_:) throws -> String`
  - `.bulletPoints(_:) throws -> [String]`
  - `.tickers(_:) throws -> [String]`
  - `.disclosure(_:) throws -> String`
  - `.slug(from title: String) -> String`
  - `.wordCount(markdown:) -> Int`
  - `.makeCode() -> String`
  - `.maxPerDay = 3`

- [ ] **Step 1: Pin and resolve**

```bash
cd ~/Work/production/apps/norviq/norviq-backend
sed -i '' 's/norviq-shared.git", exact: "5.18.0"/norviq-shared.git", exact: "5.19.0"/' Package.swift
swift package resolve && grep -A3 norviq-shared Package.resolved | grep version
```
Expected: `"version" : "5.19.0"`.

- [ ] **Step 2: Write the failing test**

```swift
import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Article validation")
struct ArticleValidationTests {
    @Test("titles collapse whitespace and must be 8–140 characters")
    func titles() throws {
        #expect(try ArticleValidation.title("  Why   2027 could reprice ") == "Why 2027 could reprice")
        #expect(throws: (any Error).self) { try ArticleValidation.title("short") }
        #expect(throws: (any Error).self) { try ArticleValidation.title(String(repeating: "a", count: 141)) }
    }

    @Test("body must be 300–20,000 characters after trimming")
    func bodies() throws {
        let ok = String(repeating: "a", count: 300)
        #expect(try ArticleValidation.body("\n\(ok)\n") == ok)
        #expect(throws: (any Error).self) { try ArticleValidation.body(String(repeating: "a", count: 299)) }
        #expect(throws: (any Error).self) { try ArticleValidation.body(String(repeating: "a", count: 20001)) }
    }

    @Test("1–3 key points, blanks dropped, each 10–240 characters")
    func bullets() throws {
        #expect(try ArticleValidation.bulletPoints(["  First key point  ", "", " "]) == ["First key point"])
        #expect(throws: (any Error).self) { try ArticleValidation.bulletPoints([]) }
        #expect(throws: (any Error).self) { try ArticleValidation.bulletPoints(["too short"]) }
        #expect(throws: (any Error).self) {
            try ArticleValidation.bulletPoints(["Point number one", "Point number two", "Point number three", "Point number four"])
        }
    }

    @Test("tickers drop $, uppercase, dedupe, keep order, cap at five and reject bad shapes")
    func tickers() throws {
        #expect(try ArticleValidation.tickers(["$next", "NEXT", " brk.b ", "rds-a"]) == ["NEXT", "BRK.B", "RDS-A"])
        #expect(throws: (any Error).self) { try ArticleValidation.tickers([]) }
        #expect(throws: (any Error).self) { try ArticleValidation.tickers(["A", "B", "C", "D", "E", "F"]) }
        #expect(throws: (any Error).self) { try ArticleValidation.tickers(["1ABC"]) }
        #expect(throws: (any Error).self) { try ArticleValidation.tickers(["TOOLONGTICK"]) }
        #expect(throws: (any Error).self) { try ArticleValidation.tickers(["NV DA"]) }
    }

    @Test("disclosure is required, 10–500 characters")
    func disclosure() throws {
        #expect(try ArticleValidation.disclosure(" No position in $NEXT ") == "No position in $NEXT")
        #expect(throws: (any Error).self) { try ArticleValidation.disclosure("none") }
        #expect(throws: (any Error).self) { try ArticleValidation.disclosure(String(repeating: "a", count: 501)) }
    }

    @Test("slugs are ascii, dashed, at most 80 characters and never empty")
    func slugs() {
        #expect(ArticleValidation.slug(from: "Before the Next Phase: Why 2027 Could Reprice NextDecade") == "before-the-next-phase-why-2027-could-reprice-nextdecade")
        #expect(ArticleValidation.slug(from: "Ação $NVDA — 100%!") == "a-o-nvda-100")
        #expect(ArticleValidation.slug(from: "!!!") == "article")
        let long = ArticleValidation.slug(from: String(repeating: "word ", count: 40))
        #expect(long.count <= 80 && !long.hasSuffix("-"))
    }

    @Test("word count ignores markdown punctuation")
    func words() {
        #expect(ArticleValidation.wordCount(markdown: "# Title\n\n**Bold** text, [a link](https://x.com) - item") == 6)
    }

    @Test("codes are 8 chars from the unambiguous alphabet")
    func codes() {
        let code = ArticleValidation.makeCode()
        #expect(code.count == 8)
        #expect(code.allSatisfy { "abcdefghjkmnpqrstuvwxyz23456789".contains($0) })
    }
}
```

- [ ] **Step 3: Run the test and check it fails**

Run: `swift test --filter ArticleValidationTests`
Expected: FAIL to compile with "cannot find 'ArticleValidation' in scope".

- [ ] **Step 4: Write the validation**

```swift
import Foundation
import Vapor

/// Input rules for articles. Pure, so they test without a database.
enum ArticleValidation {
    static let maxPerDay = 3
    static let titleRange = 8 ... 140
    static let bodyRange = 300 ... 20000
    static let maxBullets = 3
    static let bulletRange = 10 ... 240
    static let maxTickers = 5
    static let disclosureRange = 10 ... 500
    static let maxSlugLength = 80
    /// No i, l, o, 0 or 1: a code is read off an image card and typed back in.
    static let codeAlphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    static func title(_ raw: String) throws -> String {
        let title = collapse(raw)
        guard titleRange.contains(title.count) else {
            throw Abort(.badRequest, reason: "Title must be 8–140 characters.")
        }
        return title
    }

    static func body(_ raw: String) throws -> String {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bodyRange.contains(body.count) else {
            throw Abort(.badRequest, reason: "The article must be 300–20,000 characters.")
        }
        return body
    }

    static func bulletPoints(_ raw: [String]) throws -> [String] {
        let items = raw.map(collapse).filter { !$0.isEmpty }
        guard (1 ... maxBullets).contains(items.count) else {
            throw Abort(.badRequest, reason: "Add one to three key points.")
        }
        guard items.allSatisfy({ bulletRange.contains($0.count) }) else {
            throw Abort(.badRequest, reason: "Each key point must be 10–240 characters.")
        }
        return items
    }

    static func tickers(_ raw: [String]) throws -> [String] {
        var seen = Set<String>()
        var tickers: [String] = []
        for item in raw {
            var ticker = item.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if ticker.hasPrefix("$") {
                ticker.removeFirst()
            }
            if ticker.isEmpty {
                continue
            }
            guard isTicker(ticker) else {
                throw Abort(.badRequest, reason: "\"\(ticker.prefix(12))\" isn't a ticker symbol.")
            }
            if seen.insert(ticker).inserted {
                tickers.append(ticker)
            }
        }
        guard (1 ... maxTickers).contains(tickers.count) else {
            throw Abort(.badRequest, reason: "Tag one to five tickers.")
        }
        return tickers
    }

    static func disclosure(_ raw: String) throws -> String {
        let disclosure = collapse(raw)
        guard disclosureRange.contains(disclosure.count) else {
            throw Abort(.badRequest, reason: "Add a disclosure of 10–500 characters, e.g. \"No position\".")
        }
        return disclosure
    }

    static func slug(from title: String) -> String {
        var slug = ""
        var lastWasDash = true
        for scalar in title.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        if slug.count > maxSlugLength {
            slug = String(slug.prefix(maxSlugLength))
        }
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        return slug.isEmpty ? "article" : slug
    }

    static func wordCount(markdown: String) -> Int {
        let stripped = markdown.replacingOccurrences(of: #"\]\([^)]*\)"#, with: " ", options: .regularExpression)
        return stripped
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "#*_>`[]()!~|-")))
            .filter { word in word.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
            .count
    }

    static func makeCode() -> String {
        String((0 ..< 8).map { _ in codeAlphabet.randomElement()! })
    }

    private static func isTicker(_ value: String) -> Bool {
        guard (1 ... 10).contains(value.count), let first = value.first, first.isASCII, first.isLetter else {
            return false
        }
        return value.allSatisfy { ($0.isASCII && ($0.isUppercase || $0.isNumber)) || $0 == "." || $0 == "-" }
    }

    private static func collapse(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
```

- [ ] **Step 5: Run the tests and check they pass**

Run: `swift test --filter ArticleValidationTests`
Expected: PASS (8 tests).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved Sources/StockPlanBackend/Articles/ArticleValidation.swift Tests/StockPlanBackendTests/ArticleValidationTests.swift
git commit -m "feat(articles): pin shared 5.19.0 and add article validation"
git show --stat HEAD
```

---

### Task 3: Image sniffing (pure)

**Files:**
- Create: `norviq-backend/Sources/StockPlanBackend/Articles/ArticleImageSniffer.swift`
- Test: `norviq-backend/Tests/StockPlanBackendTests/ArticleImageSnifferTests.swift`

**Interfaces:**
- Produces:
  - `struct SniffedImage { let contentType: String; let width: Int; let height: Int }`
  - `ArticleImageSniffer.sniff(_ bytes: [UInt8]) throws -> SniffedImage`
    - 415 for an unknown type
    - 413 for more than `maxBytes = 2_000_000` bytes
    - 400 when a side exceeds `maxSide = 4096` or the header is unreadable

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
@testable import StockPlanBackend
import Testing
import Vapor

@Suite("Article image sniffing")
struct ArticleImageSnifferTests {
    /// Minimal PNG: signature + IHDR with the given size. Pixels are not needed.
    static func png(width: UInt32, height: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
        bytes += withUnsafeBytes(of: width.bigEndian, Array.init)
        bytes += withUnsafeBytes(of: height.bigEndian, Array.init)
        bytes += [8, 6, 0, 0, 0, 0, 0, 0, 0]
        return bytes
    }

    /// Minimal JPEG: SOI, an APP0 segment, then SOF0 with the given size.
    static func jpeg(width: UInt16, height: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xC0, 0x00, 0x11, 0x08]
        bytes += withUnsafeBytes(of: height.bigEndian, Array.init)
        bytes += withUnsafeBytes(of: width.bigEndian, Array.init)
        bytes += [0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]
        return bytes
    }

    /// Minimal lossy WebP (VP8): RIFF header, VP8 chunk with a keyframe header.
    static func webp(width: UInt16, height: UInt16) -> [UInt8] {
        var bytes: [UInt8] = Array("RIFF".utf8) + [0x24, 0, 0, 0] + Array("WEBPVP8 ".utf8) + [0x18, 0, 0, 0]
        bytes += [0x30, 0x01, 0x00, 0x9D, 0x01, 0x2A]
        bytes += withUnsafeBytes(of: width.littleEndian, Array.init)
        bytes += withUnsafeBytes(of: height.littleEndian, Array.init)
        bytes += [UInt8](repeating: 0, count: 8)
        return bytes
    }

    @Test("PNG, JPEG and WebP report type and size")
    func knownTypes() throws {
        let png = try ArticleImageSniffer.sniff(Self.png(width: 1200, height: 630))
        #expect(png.contentType == "image/png" && png.width == 1200 && png.height == 630)
        let jpeg = try ArticleImageSniffer.sniff(Self.jpeg(width: 800, height: 600))
        #expect(jpeg.contentType == "image/jpeg" && jpeg.width == 800 && jpeg.height == 600)
        let webp = try ArticleImageSniffer.sniff(Self.webp(width: 640, height: 480))
        #expect(webp.contentType == "image/webp" && webp.width == 640 && webp.height == 480)
    }

    @Test("an SVG or HTML file is unsupported media")
    func unknownType() {
        #expect {
            try ArticleImageSniffer.sniff(Array("<svg onload=alert(1)>".utf8))
        } throws: { ($0 as? any AbortError)?.status == .unsupportedMediaType }
    }

    @Test("over 2 MB is too large; over 4096 px a side is rejected")
    func limits() {
        let big = Self.png(width: 10, height: 10) + [UInt8](repeating: 0, count: 2_000_001)
        #expect { try ArticleImageSniffer.sniff(big) } throws: { ($0 as? any AbortError)?.status == .payloadTooLarge }
        #expect { try ArticleImageSniffer.sniff(Self.png(width: 5000, height: 10)) } throws: { ($0 as? any AbortError)?.status == .badRequest }
    }
}
```

- [ ] **Step 2: Run the test and check it fails**

Run: `swift test --filter ArticleImageSnifferTests`
Expected: FAIL to compile with "cannot find 'ArticleImageSniffer'".

- [ ] **Step 3: Write the sniffer**

```swift
import Foundation
import Vapor

struct SniffedImage: Equatable {
    let contentType: String
    let width: Int
    let height: Int
}

/// Identifies a cover image by its bytes, never by the client's claimed type,
/// so an SVG or HTML file can't be stored and served back as an "image".
enum ArticleImageSniffer {
    static let maxBytes = 2_000_000
    static let maxSide = 4096

    static func sniff(_ bytes: [UInt8]) throws -> SniffedImage {
        guard bytes.count <= maxBytes else {
            throw Abort(.payloadTooLarge, reason: "Images must be 2 MB or smaller.")
        }
        let image: SniffedImage?
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            image = png(bytes)
        } else if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            image = jpeg(bytes)
        } else if bytes.count >= 12, bytes[0 ..< 4] == [0x52, 0x49, 0x46, 0x46], bytes[8 ..< 12] == [0x57, 0x45, 0x42, 0x50] {
            image = webp(bytes)
        } else {
            throw Abort(.unsupportedMediaType, reason: "Use a JPEG, PNG or WebP image.")
        }
        guard let image, image.width > 0, image.height > 0 else {
            throw Abort(.badRequest, reason: "That image file looks damaged.")
        }
        guard image.width <= maxSide, image.height <= maxSide else {
            throw Abort(.badRequest, reason: "Images can be at most 4096 pixels on a side.")
        }
        return image
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
    private static func le16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }

    private static func png(_ b: [UInt8]) -> SniffedImage? {
        guard b.count >= 24 else { return nil }
        return SniffedImage(contentType: "image/png", width: be32(b, 16), height: be32(b, 20))
    }

    /// Walks the marker segments to the first start-of-frame.
    private static func jpeg(_ b: [UInt8]) -> SniffedImage? {
        var i = 2
        while i + 9 < b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            let length = be16(b, i + 2)
            let isStartOfFrame = (0xC0 ... 0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker)
            if isStartOfFrame {
                return SniffedImage(contentType: "image/jpeg", width: be16(b, i + 7), height: be16(b, i + 5))
            }
            guard length >= 2 else { return nil }
            i += 2 + length
        }
        return nil
    }

    private static func webp(_ b: [UInt8]) -> SniffedImage? {
        guard b.count >= 30 else { return nil }
        let chunk = String(decoding: b[12 ..< 16], as: UTF8.self)
        switch chunk {
        case "VP8 ":
            return SniffedImage(contentType: "image/webp", width: le16(b, 26) & 0x3FFF, height: le16(b, 28) & 0x3FFF)
        case "VP8L":
            let bits = Int(b[21]) | Int(b[22]) << 8 | Int(b[23]) << 16 | Int(b[24]) << 24
            return SniffedImage(contentType: "image/webp", width: (bits & 0x3FFF) + 1, height: ((bits >> 14) & 0x3FFF) + 1)
        case "VP8X":
            let width = (Int(b[24]) | Int(b[25]) << 8 | Int(b[26]) << 16) + 1
            let height = (Int(b[27]) | Int(b[28]) << 8 | Int(b[29]) << 16) + 1
            return SniffedImage(contentType: "image/webp", width: width, height: height)
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: Run the tests and check they pass**

Run: `swift test --filter ArticleImageSnifferTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/StockPlanBackend/Articles/ArticleImageSniffer.swift Tests/StockPlanBackendTests/ArticleImageSnifferTests.swift
git commit -m "feat(articles): sniff cover image type and size from bytes"
git show --stat HEAD
```

---

### Task 4: Models, migration and ticker verifier

**Files:**
- Create: `norviq-backend/Sources/StockPlanBackend/Articles/ArticleModels.swift`
- Create: `norviq-backend/Sources/StockPlanBackend/Migrations/CreateArticlesTables.swift`
- Create: `norviq-backend/Sources/StockPlanBackend/Articles/ArticleTickerVerifier.swift`
- Modify: `norviq-backend/Sources/StockPlanBackend/ConfigureBootstrap.swift`. After `app.migrations.add(CreateBoardNotifications())` (line ~437), add `app.migrations.add(CreateArticlesTables())`.
- Test: `norviq-backend/Tests/StockPlanBackendTests/ArticleSchemaTests.swift`

**Interfaces:**
- Produces:
  - Fluent models `Article`, `ArticleVote`, `ArticleView`, `ArticleImage` (fields below)
  - `enum TickerCheck { case exists, missing, unknown }`
  - `protocol ArticleTickerVerifier: Sendable { func check(_ symbol: String, on req: Request) async -> TickerCheck }`
  - `Application.articleTickerVerifier` (default `MarketProfileTickerVerifier`; tests override it)

- [ ] **Step 1: Write the failing test**

```swift
import Fluent
import Foundation
@testable import StockPlanBackend
import Testing
import Vapor

@Suite("Article schema", .serialized)
struct ArticleSchemaTests {
    @Test("articles, votes, views and images migrate and revert; code is unique", .databaseLocked)
    func migrates() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()
            let user = User(email: "art+schema@example.com", passwordHash: "x")
            try await user.save(on: app.db)
            let authorId = try user.requireID()

            let first = Article(authorId: authorId, code: "abcd2345", slug: "a", title: "T", bodyMarkdown: "B",
                                bulletPoints: ["P"], tickers: ["NEXT"], disclosure: "D", coverImageId: nil,
                                source: "web", wordCount: 1)
            try await first.create(on: app.db)
            let duplicate = Article(authorId: authorId, code: "abcd2345", slug: "b", title: "T", bodyMarkdown: "B",
                                    bulletPoints: ["P"], tickers: ["NEXT"], disclosure: "D", coverImageId: nil,
                                    source: "web", wordCount: 1)
            await #expect(throws: (any Error).self) { try await duplicate.create(on: app.db) }

            let fetched = try #require(try await Article.query(on: app.db).filter(\.$code == "abcd2345").first())
            #expect(fetched.tickers == ["NEXT"] && fetched.status == "published" && fetched.viewCount == 0)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
```

> Check the `User` initializer in `Sources/StockPlanBackend/Models/User.swift` before running. If it differs from
> `User(email:passwordHash:)`, create the user through `POST v1/auth/register` instead, as `PilotControllerTests.registerTestUser` does.

- [ ] **Step 2: Run the test and check it fails**

Run: `swift test --filter ArticleSchemaTests`
Expected: FAIL to compile with "cannot find 'Article' in scope".

- [ ] **Step 3: Write the models**

```swift
import Fluent
import Foundation

/// A user-published, ticker-tagged write-up. Never hard-deleted: `status`
/// moves to `hidden` (moderator) or `deleted` (author).
final class Article: Model, @unchecked Sendable {
    static let schema = "articles"

    @ID(key: .id) var id: UUID?
    @Field(key: "code") var code: String
    @Field(key: "author_id") var authorId: UUID
    @Field(key: "slug") var slug: String
    @Field(key: "title") var title: String
    @Field(key: "body_markdown") var bodyMarkdown: String
    @Field(key: "bullet_points") var bulletPoints: [String]
    @Field(key: "tickers") var tickers: [String]
    @Field(key: "disclosure") var disclosure: String
    @OptionalField(key: "cover_image_id") var coverImageId: UUID?
    @Field(key: "status") var status: String
    @Field(key: "source") var source: String
    @Field(key: "view_count") var viewCount: Int
    @Field(key: "upvote_count") var upvoteCount: Int
    @Field(key: "word_count") var wordCount: Int
    @Field(key: "published_at") var publishedAt: Date
    @OptionalField(key: "edited_at") var editedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        authorId: UUID, code: String, slug: String, title: String, bodyMarkdown: String,
        bulletPoints: [String], tickers: [String], disclosure: String, coverImageId: UUID?,
        source: String, wordCount: Int, now: Date = Date()
    ) {
        self.authorId = authorId
        self.code = code
        self.slug = slug
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.bulletPoints = bulletPoints
        self.tickers = tickers
        self.disclosure = disclosure
        self.coverImageId = coverImageId
        status = "published"
        self.source = source
        viewCount = 0
        upvoteCount = 0
        self.wordCount = wordCount
        // Whole milliseconds, so the feed cursor (epoch ms) matches exactly.
        publishedAt = Date(timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }
}

final class ArticleVote: Model, @unchecked Sendable {
    static let schema = "article_votes"

    @ID(key: .id) var id: UUID?
    @Field(key: "article_id") var articleId: UUID
    @Field(key: "user_id") var userId: UUID
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
}

/// One row per viewer per UTC day. The first insert of the day counts a view.
final class ArticleView: Model, @unchecked Sendable {
    static let schema = "article_views"

    @ID(key: .id) var id: UUID?
    @Field(key: "article_id") var articleId: UUID
    @Field(key: "viewer_key") var viewerKey: String
    @Field(key: "day") var day: String

    init() {}
}

/// Cover images live in Postgres: Norviq has no object storage, and covers are
/// capped at 2 MB, one per article.
final class ArticleImage: Model, @unchecked Sendable {
    static let schema = "article_images"

    @ID(key: .id) var id: UUID?
    @Field(key: "owner_id") var ownerId: UUID
    @Field(key: "content_type") var contentType: String
    @Field(key: "bytes") var bytes: Data
    @Field(key: "width") var width: Int
    @Field(key: "height") var height: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(ownerId: UUID, image: SniffedImage, bytes: Data) {
        self.ownerId = ownerId
        contentType = image.contentType
        self.bytes = bytes
        width = image.width
        height = image.height
    }
}
```

- [ ] **Step 4: Write the migration**

```swift
import Fluent
import FluentSQL

/// Articles and their votes, daily view rows and cover images. Content
/// cascades with its author's account.
struct CreateArticlesTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("article_images")
            .id()
            .field("owner_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("content_type", .string, .required)
            .field("bytes", .data, .required)
            .field("width", .int, .required)
            .field("height", .int, .required)
            .field("created_at", .datetime, .required)
            .create()

        try await database.schema("articles")
            .id()
            .field("code", .string, .required)
            .field("author_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("slug", .string, .required)
            .field("title", .string, .required)
            .field("body_markdown", .string, .required)
            .field("bullet_points", .array(of: .string), .required)
            .field("tickers", .array(of: .string), .required)
            .field("disclosure", .string, .required)
            .field("cover_image_id", .uuid, .references("article_images", "id", onDelete: .setNull))
            .field("status", .string, .required)
            .field("source", .string, .required)
            .field("view_count", .int, .required)
            .field("upvote_count", .int, .required)
            .field("word_count", .int, .required)
            .field("published_at", .datetime, .required)
            .field("edited_at", .datetime)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "code")
            .create()

        try await database.schema("article_votes")
            .id()
            .field("article_id", .uuid, .required, .references("articles", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime, .required)
            .unique(on: "article_id", "user_id")
            .create()

        try await database.schema("article_views")
            .id()
            .field("article_id", .uuid, .required, .references("articles", "id", onDelete: .cascade))
            .field("viewer_key", .string, .required)
            .field("day", .string, .required)
            .unique(on: "article_id", "viewer_key", "day")
            .create()

        if let sql = database as? any SQLDatabase {
            try await sql.raw("CREATE INDEX articles_feed_idx ON articles (status, published_at DESC, id DESC)").run()
            try await sql.raw("CREATE INDEX articles_tickers_idx ON articles USING GIN (tickers)").run()
            try await sql.raw("CREATE INDEX articles_author_idx ON articles (author_id, published_at DESC)").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("article_views").delete()
        try await database.schema("article_votes").delete()
        try await database.schema("articles").delete()
        try await database.schema("article_images").delete()
    }
}
```

- [ ] **Step 5: Write the ticker verifier**

```swift
import Vapor

enum TickerCheck: Equatable {
    case exists
    case missing
    /// The provider could not answer (down, rate limited). Treated as valid so
    /// market-data quota never blocks publishing.
    case unknown
}

protocol ArticleTickerVerifier: Sendable {
    func check(_ symbol: String, on req: Request) async -> TickerCheck
}

struct MarketProfileTickerVerifier: ArticleTickerVerifier {
    func check(_ symbol: String, on req: Request) async -> TickerCheck {
        do {
            _ = try await req.application.marketDataService.profile(symbol: symbol, on: req)
            return .exists
        } catch let abort as any AbortError where abort.status == .notFound {
            return .missing
        } catch {
            req.logger.warning("articles.ticker_check_unavailable symbol=\(symbol) error=\(String(describing: error))")
            return .unknown
        }
    }
}

extension Application {
    private struct ArticleTickerVerifierKey: StorageKey {
        typealias Value = any ArticleTickerVerifier
    }

    var articleTickerVerifier: any ArticleTickerVerifier {
        get { storage[ArticleTickerVerifierKey.self] ?? MarketProfileTickerVerifier() }
        set { storage[ArticleTickerVerifierKey.self] = newValue }
    }
}
```

- [ ] **Step 6: Register the migration**

In `ConfigureBootstrap.swift`, directly after `app.migrations.add(CreateBoardNotifications())`:

```swift
    app.migrations.add(CreateArticlesTables())
```

- [ ] **Step 7: Run the tests and check they pass**

Run: `swift test --filter ArticleSchemaTests`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/StockPlanBackend/Articles/ArticleModels.swift Sources/StockPlanBackend/Articles/ArticleTickerVerifier.swift \
  Sources/StockPlanBackend/Migrations/CreateArticlesTables.swift Sources/StockPlanBackend/ConfigureBootstrap.swift \
  Tests/StockPlanBackendTests/ArticleSchemaTests.swift
git commit -m "feat(articles): add article tables, models and ticker verifier"
git show --stat HEAD
```

---

### Task 5: Controller — flag, create, read, list, update, delete

**Files:**
- Create: `norviq-backend/Sources/StockPlanBackend/Articles/ArticlesController.swift`
- Create: `norviq-backend/Sources/StockPlanBackend/Articles/ArticleService.swift`
- Create: `norviq-backend/Sources/StockPlanBackend/Articles/ArticlePresenter.swift`
- Modify: `norviq-backend/Sources/StockPlanBackend/routes.swift`. After `try api.register(collection: CommunityAdminController())` (line ~96), add `try api.register(collection: ArticlesController())`.
- Test: `norviq-backend/Tests/StockPlanBackendTests/ArticlesRouteTests.swift`

**Interfaces:**
- Consumes: `ArticleValidation` (Task 2); `Article`, `ArticleImage`, `ArticleTickerVerifier` (Task 4); `CommunityViewer`, `CommunityAccessMiddleware`, `ScopedBearerAuthenticator`, `FirstPartyOnlyMiddleware`, `ScopeRequirementMiddleware(.marketRead)`, `RateLimitMiddleware`, `CodedAbort`, `envBool`.
- Produces routes:
  - `GET /v1/articles` → `ArticleListResponse`
  - `GET /v1/articles/:ref` → `ArticleDetail`
  - `POST /v1/articles` → `ArticleDetail`
  - `PATCH /v1/articles/:ref` → `ArticleDetail`
  - `DELETE /v1/articles/:ref` → 204
- Produces helpers:
  - `ArticleService.find(ref:on:) async throws -> Article?`
  - `ArticleService.requireVisible(ref:viewer:on:) async throws -> Article`
  - `ArticleService.viewerId(_ req: Request) -> UUID?`
  - `ArticlePresenter.summaries(_:on:)`, `ArticlePresenter.detail(_:viewerId:on:)`
- Task 6 adds vote/view/report/image routes to the same `boot`.

- [ ] **Step 1: Write the failing tests**

```swift
import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

struct StubTickerVerifier: ArticleTickerVerifier {
    var missing: Set<String> = ["ZZZZ"]
    var unavailable: Set<String> = []

    func check(_ symbol: String, on _: Request) async -> TickerCheck {
        if missing.contains(symbol) { return .missing }
        if unavailable.contains(symbol) { return .unknown }
        return .exists
    }
}

/// Shared helpers for the article route suites (this task and the next three).
enum ArticleTestKit {
    static let adminEmail = "art+admin@example.com"

    struct Reply {
        let status: HTTPStatus
        let body: Data

        func decode<T: Decodable>(_: T.Type) throws -> T {
            try JSONDecoder.backendAPI.decode(T.self, from: body)
        }

        var code: String? { try? decode(APIErrorEnvelope.self).code }
    }

    static func withApp(enabled: Bool = true, _ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("NORVIQ_ADMIN_EMAILS", adminEmail, 1)
            if enabled { setenv("ARTICLES_ENABLED", "true", 1) } else { unsetenv("ARTICLES_ENABLED") }
            defer {
                unsetenv("NORVIQ_ADMIN_EMAILS")
                unsetenv("ARTICLES_ENABLED")
            }
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                app.articleTickerVerifier = StubTickerVerifier()
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    static func register(_ app: Application, _ id: String, email: String? = nil) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "art_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: email ?? "art+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })
        return try #require(response)
    }

    /// Registered and past the community guidelines, so they can publish.
    static func member(_ app: Application, _ id: String, email: String? = nil) async throws -> AuthResponse {
        let auth = try await register(app, id, email: email)
        #expect(try await send(app, .POST, "v1/community/guidelines/accept", as: auth).status == .noContent)
        return auth
    }

    static func send(
        _ app: Application, _ method: HTTPMethod, _ path: String, as auth: AuthResponse?,
        body: (any Content)? = nil, headers: HTTPHeaders = [:]
    ) async throws -> Reply {
        var reply: Reply?
        try await app.testing().test(method, path, beforeRequest: { req in
            if let auth { req.headers.bearerAuthorization = BearerAuthorization(token: auth.token) }
            for (name, value) in headers { req.headers.replaceOrAdd(name: name, value: value) }
            if let body { try req.content.encode(body) }
        }, afterResponse: { res async throws in
            reply = Reply(status: res.status, body: Data(res.body.readableBytesView))
        })
        return try #require(reply)
    }

    static func input(
        title: String = "Why 2027 could reprice NextDecade",
        tickers: [String] = ["$next"],
        bullets: [String] = ["First LNG from Train 1 is targeted for 1H 2027."],
        cover: UUID? = nil
    ) -> ArticleWriteRequest {
        ArticleWriteRequest(
            title: title,
            bodyMarkdown: String(repeating: "Revenue visibility is unusually long. ", count: 12),
            bulletPoints: bullets, tickers: tickers,
            disclosure: "I hold a position in $NEXT.", coverImageId: cover, source: .web
        )
    }

    static func publish(_ app: Application, as auth: AuthResponse, _ input: ArticleWriteRequest = input()) async throws -> ArticleDetail {
        let reply = try await send(app, .POST, "v1/articles", as: auth, body: input)
        #expect(reply.status == .ok)
        return try reply.decode(ArticleDetail.self)
    }
}

@Suite("Articles routes", .serialized)
struct ArticlesRouteTests {
    typealias Kit = ArticleTestKit

    @Test("flag off: every route 404s, even without a token")
    func flagOff() async throws {
        try await Kit.withApp(enabled: false) { app in
            let auth = try await Kit.member(app, "off")
            #expect(try await Kit.send(app, .GET, "v1/articles", as: auth).status == .notFound)
            #expect(try await Kit.send(app, .POST, "v1/articles", as: auth, body: Kit.input()).status == .notFound)
            #expect(try await Kit.send(app, .GET, "v1/articles", as: nil).status == .notFound)
        }
    }

    @Test("publish normalises fields, assigns a code and slug, and reads back by code and by id")
    func publishAndRead() async throws {
        try await Kit.withApp { app in
            let auth = try await Kit.member(app, "pub")
            let detail = try await Kit.publish(app, as: auth)
            #expect(detail.article.tickers == ["NEXT"])
            #expect(detail.article.slug == "why-2027-could-reprice-nextdecade")
            #expect(detail.article.code.count == 8)
            #expect(detail.article.author.username == "art_pub")
            #expect(detail.article.wordCount == 60)
            #expect(detail.viewerIsAuthor)

            let byCode = try await Kit.send(app, .GET, "v1/articles/\(detail.article.code)", as: auth)
            #expect(byCode.status == .ok)
            let byId = try await Kit.send(app, .GET, "v1/articles/\(detail.article.id)", as: auth)
            #expect(try byId.decode(ArticleDetail.self).article.code == detail.article.code)
        }
    }

    @Test("validation errors are 400; an unknown ticker is rejected")
    func validation() async throws {
        try await Kit.withApp { app in
            let auth = try await Kit.member(app, "val")
            #expect(try await Kit.send(app, .POST, "v1/articles", as: auth, body: Kit.input(title: "short")).status == .badRequest)
            #expect(try await Kit.send(app, .POST, "v1/articles", as: auth, body: Kit.input(bullets: [])).status == .badRequest)
            let unknown = try await Kit.send(app, .POST, "v1/articles", as: auth, body: Kit.input(tickers: ["ZZZZ"]))
            #expect(unknown.status == .badRequest)
        }
    }

    @Test("a ticker the provider can't check is accepted")
    func unavailableTickerIsAccepted() async throws {
        try await Kit.withApp { app in
            app.articleTickerVerifier = StubTickerVerifier(missing: [], unavailable: ["NEXT"])
            let auth = try await Kit.member(app, "unav")
            _ = try await Kit.publish(app, as: auth)
        }
    }

    @Test("publishing needs accepted guidelines")
    func needsGuidelines() async throws {
        try await Kit.withApp { app in
            let fresh = try await Kit.register(app, "fresh")
            let reply = try await Kit.send(app, .POST, "v1/articles", as: fresh, body: Kit.input())
            #expect(reply.status == .forbidden && reply.code == "guidelines_required")
        }
    }

    @Test("three articles a day, then 429 article_daily_limit")
    func dailyLimit() async throws {
        try await Kit.withApp { app in
            let auth = try await Kit.member(app, "cap")
            for n in 1 ... 3 {
                _ = try await Kit.publish(app, as: auth, Kit.input(title: "Article number \(n) about NEXT"))
            }
            let fourth = try await Kit.send(app, .POST, "v1/articles", as: auth, body: Kit.input(title: "Article number 4 about NEXT"))
            #expect(fourth.status == .tooManyRequests && fourth.code == "article_daily_limit")
        }
    }

    @Test("feed is newest first, filters by ticker and author, and pages with a cursor")
    func feed() async throws {
        try await Kit.withApp { app in
            let ana = try await Kit.member(app, "ana")
            let bo = try await Kit.member(app, "bo")
            let first = try await Kit.publish(app, as: ana, Kit.input(title: "First article about NEXT"))
            let second = try await Kit.publish(app, as: bo, Kit.input(title: "Second article on NVDA", tickers: ["NVDA"]))
            let third = try await Kit.publish(app, as: ana, Kit.input(title: "Third article on NVDA too", tickers: ["NVDA", "NEXT"]))

            let all = try await Kit.send(app, .GET, "v1/articles", as: ana).decode(ArticleListResponse.self)
            #expect(all.items.map(\.code) == [third, second, first].map(\.article.code))

            let nvda = try await Kit.send(app, .GET, "v1/articles?ticker=nvda", as: ana).decode(ArticleListResponse.self)
            #expect(nvda.items.map(\.code) == [third, second].map(\.article.code))

            let byAna = try await Kit.send(app, .GET, "v1/articles?author=art_ana", as: bo).decode(ArticleListResponse.self)
            #expect(byAna.items.map(\.code) == [third, first].map(\.article.code))

            let page1 = try await Kit.send(app, .GET, "v1/articles?limit=2", as: ana).decode(ArticleListResponse.self)
            let cursor = try #require(page1.nextCursor)
            let page2 = try await Kit.send(app, .GET, "v1/articles?limit=2&cursor=\(cursor)", as: ana).decode(ArticleListResponse.self)
            #expect(page2.items.map(\.code) == [first.article.code] && page2.nextCursor == nil)
        }
    }

    @Test("only the author edits; edits set editedAt and a new slug; delete hides it from everyone")
    func editAndDelete() async throws {
        try await Kit.withApp { app in
            let ana = try await Kit.member(app, "ed_ana")
            let bo = try await Kit.member(app, "ed_bo")
            let detail = try await Kit.publish(app, as: ana)
            let code = detail.article.code

            #expect(try await Kit.send(app, .PATCH, "v1/articles/\(code)", as: bo, body: Kit.input(title: "Hijacked title here")).status == .forbidden)

            let edited = try await Kit.send(app, .PATCH, "v1/articles/\(code)", as: ana, body: Kit.input(title: "A better title for NEXT"))
            let updated = try edited.decode(ArticleDetail.self)
            #expect(updated.article.slug == "a-better-title-for-next" && updated.article.editedAt != nil)
            #expect(updated.article.code == code)

            #expect(try await Kit.send(app, .DELETE, "v1/articles/\(code)", as: bo).status == .forbidden)
            #expect(try await Kit.send(app, .DELETE, "v1/articles/\(code)", as: ana).status == .noContent)
            #expect(try await Kit.send(app, .GET, "v1/articles/\(code)", as: bo).status == .notFound)
            #expect(try await Kit.send(app, .GET, "v1/articles", as: bo).decode(ArticleListResponse.self).items.isEmpty)
        }
    }

    @Test("a muted member can't publish")
    func mutedCannotPublish() async throws {
        try await Kit.withApp { app in
            let admin = try await Kit.member(app, "adm", email: Kit.adminEmail)
            let ana = try await Kit.member(app, "mute_ana")
            let sanction = try await Kit.send(
                app, .POST, "v1/admin/community/sanctions", as: admin,
                body: CreateSanctionRequest(username: "art_mute_ana", kind: .mute, reason: "Testing", durationHours: 1)
            )
            #expect(sanction.status == .ok || sanction.status == .created)
            let reply = try await Kit.send(app, .POST, "v1/articles", as: ana, body: Kit.input())
            #expect(reply.status == .forbidden && reply.code == "community_muted")
        }
    }
}
```

> `JSONDecoder.backendAPI`, `APIErrorEnvelope`, `CreateSanctionRequest`, `DatabaseTestLock` and `AuthRegisterRequest`
> already exist; `BoardsTests.swift` uses all of them. If `withLock` is unavailable, use
> `DatabaseTestLock.withSharedAccess` as `PilotControllerTests` does.

- [ ] **Step 2: Run the tests and check they fail**

Run: `swift test --filter ArticlesRouteTests`
Expected: FAIL to compile with "cannot find 'ArticleService'…". Once stubs exist, it fails with 404s.

- [ ] **Step 3: Write `ArticleService.swift`**

```swift
import Fluent
import FluentSQL
import StockPlanShared
import Vapor

/// Lookups and rules shared by every article handler.
enum ArticleService {
    /// `ref` is the article's uuid or its 8-character code.
    static func find(ref: String, on db: any Database) async throws -> Article? {
        if let id = UUID(uuidString: ref) {
            return try await Article.find(id, on: db)
        }
        let code = ref.lowercased()
        guard code.count == 8 else { return nil }
        return try await Article.query(on: db).filter(\.$code == code).first()
    }

    /// The signed-in person behind a first-party session. A third-party token
    /// (the web's public token, a PAT) is nobody: it reads anonymously.
    static func viewerId(_ req: Request) -> UUID? {
        guard !req.auth.has(ScopeContext.self) else { return nil }
        return req.auth.get(SessionToken.self)?.userId
    }

    static func isAdmin(_ userId: UUID, on db: any Database) async -> Bool {
        (try? await CommunityAccess.viewer(for: userId, on: db).isAdmin) ?? false
    }

    /// Published articles are visible to all. Hidden ones only to their author
    /// and admins. Deleted ones only to admins. Everyone else gets a 404, so a
    /// hidden article is indistinguishable from one that never existed.
    static func requireVisible(ref: String, viewer: UUID?, on db: any Database) async throws -> Article {
        guard let article = try await find(ref: ref, on: db) else {
            throw Abort(.notFound, reason: "Article not found")
        }
        switch article.status {
        case ArticleStatus.published.rawValue:
            return article
        case ArticleStatus.hidden.rawValue:
            if let viewer, viewer == article.authorId { return article }
            if let viewer, await isAdmin(viewer, on: db) { return article }
        default:
            if let viewer, await isAdmin(viewer, on: db) { return article }
        }
        throw Abort(.notFound, reason: "Article not found")
    }

    struct Fields {
        let title: String
        let slug: String
        let body: String
        let bulletPoints: [String]
        let tickers: [String]
        let disclosure: String
        let coverImageId: UUID?
        let wordCount: Int
    }

    static func validate(_ input: ArticleWriteRequest, authorId: UUID, on req: Request) async throws -> Fields {
        let title = try ArticleValidation.title(input.title)
        let body = try ArticleValidation.body(input.bodyMarkdown)
        let bullets = try ArticleValidation.bulletPoints(input.bulletPoints)
        let tickers = try ArticleValidation.tickers(input.tickers)
        let disclosure = try ArticleValidation.disclosure(input.disclosure)
        for ticker in tickers {
            if await req.application.articleTickerVerifier.check(ticker, on: req) == .missing {
                throw Abort(.badRequest, reason: "We couldn't find the ticker \(ticker).")
            }
        }
        if let coverId = input.coverImageId {
            guard let image = try await ArticleImage.find(coverId, on: req.db), image.ownerId == authorId else {
                throw Abort(.badRequest, reason: "Upload the cover image again.")
            }
        }
        return Fields(
            title: title, slug: ArticleValidation.slug(from: title), body: body, bulletPoints: bullets,
            tickers: tickers, disclosure: disclosure, coverImageId: input.coverImageId,
            wordCount: ArticleValidation.wordCount(markdown: body)
        )
    }

    /// Inserts with a fresh code, retrying on the rare collision.
    static func insert(_ article: Article, on db: any Database) async throws {
        for attempt in 1 ... 5 {
            article.code = ArticleValidation.makeCode()
            do {
                try await article.create(on: db)
                return
            } catch let error as any DatabaseError where error.isConstraintFailure && attempt < 5 {
                article.id = nil
                continue
            }
        }
    }

    static func sql(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Articles need a SQL database")
        }
        return sql
    }
}
```

- [ ] **Step 4: Write `ArticlePresenter.swift`**

```swift
import Fluent
import StockPlanShared
import Vapor

enum ArticlePresenter {
    static func summary(_ article: Article, author: User?) throws -> ArticleSummary {
        ArticleSummary(
            id: try article.requireID(),
            code: article.code,
            slug: article.slug,
            title: article.title,
            bulletPoints: article.bulletPoints,
            tickers: article.tickers,
            author: ArticleAuthor(id: article.authorId, username: author?.username, avatarURL: author?.avatarURLString),
            coverImageId: article.coverImageId,
            upvoteCount: article.upvoteCount,
            viewCount: article.viewCount,
            wordCount: article.wordCount,
            status: ArticleStatus(rawValue: article.status) ?? .unknown,
            source: ArticleSource(rawValue: article.source) ?? .unknown,
            publishedAt: article.publishedAt,
            editedAt: article.editedAt
        )
    }

    /// One users query for the whole page.
    static func summaries(_ articles: [Article], on db: any Database) async throws -> [ArticleSummary] {
        let authorIds = Array(Set(articles.map(\.authorId)))
        let authors = try await User.query(on: db).filter(\.$id ~~ authorIds).all()
        let byId = Dictionary(uniqueKeysWithValues: authors.compactMap { user in user.id.map { ($0, user) } })
        return try articles.map { try summary($0, author: byId[$0.authorId]) }
    }

    static func detail(_ article: Article, viewerId: UUID?, on db: any Database) async throws -> ArticleDetail {
        let author = try await User.find(article.authorId, on: db)
        var upvoted = false
        if let viewerId {
            upvoted = try await ArticleVote.query(on: db)
                .filter(\.$articleId == article.requireID())
                .filter(\.$userId == viewerId)
                .first() != nil
        }
        return ArticleDetail(
            article: try summary(article, author: author),
            bodyMarkdown: article.bodyMarkdown,
            disclosure: article.disclosure,
            viewerUpvoted: upvoted,
            viewerIsAuthor: viewerId == article.authorId
        )
    }
}
```

> If `User`'s avatar property isn't `avatarURLString`, use whatever `@OptionalField(key: "avatar_url")` is called in
> `Models/User.swift`.

- [ ] **Step 5: Write `ArticlesController.swift` (core routes)**

```swift
import Fluent
import FluentSQL
import StockPlanShared
import Vapor

/// 404s every article route while ARTICLES_ENABLED is off, before auth runs,
/// so the feature looks like it doesn't exist.
struct ArticlesFlagMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard envBool("ARTICLES_ENABLED", default: false) else { throw Abort(.notFound) }
        return try await next.respond(to: request)
    }
}

struct ArticlesController: RouteCollection {
    static let pageSize = 20
    static let maxPageSize = 100

    func boot(routes: any RoutesBuilder) throws {
        let articles = routes.grouped("articles").grouped(ArticlesFlagMiddleware())

        // Reads: first-party sessions, plus the web's public token (market:read)
        // for logged-out visitors.
        let read = articles.grouped(
            ScopedBearerAuthenticator(), SessionToken.guardMiddleware(), ScopeRequirementMiddleware(.marketRead)
        )
        read.get(use: list)
        read.get(":ref", use: get)

        // Writes: the same gate as Boards (bans, mutes, username, guidelines).
        let write = articles.grouped(
            ScopedBearerAuthenticator(), SessionToken.guardMiddleware(), FirstPartyOnlyMiddleware(), CommunityAccessMiddleware()
        )
        // The daily cap is enforced in the handler against the database; this
        // only stops a burst.
        write.grouped(RateLimitMiddleware(limit: 10, interval: 3600, keyPrefix: "ratelimit:article-create"))
            .post(use: create)
        write.grouped(RateLimitMiddleware(limit: 10, interval: 3600, keyPrefix: "ratelimit:article-edit"))
            .patch(":ref", use: update)
        write.delete(":ref", use: delete)
    }

    // MARK: - Reads

    @Sendable
    func list(req: Request) async throws -> ArticleListResponse {
        let limit = min(max(req.query[Int.self, at: "limit"] ?? Self.pageSize, 1), Self.maxPageSize)
        let query = Article.query(on: req.db).filter(\.$status == ArticleStatus.published.rawValue)

        if let rawTicker = req.query[String.self, at: "ticker"], !rawTicker.isEmpty {
            let ticker = try ArticleValidation.tickers([rawTicker])[0]
            query.filter(.sql(SQLBinaryExpression(left: SQLColumn("tickers"), op: SQLRaw("@>"), right: SQLBind([ticker]))))
        }
        if let username = req.query[String.self, at: "author"], !username.isEmpty {
            guard let author = try await User.query(on: req.db).filter(\.$username == username).first(),
                  let authorId = author.id
            else {
                return ArticleListResponse(items: [], nextCursor: nil)
            }
            query.filter(\.$authorId == authorId)
        }
        if let cursor = req.query[String.self, at: "cursor"], let (date, id) = Self.decodeCursor(cursor) {
            query.group(.or) { or in
                or.filter(\.$publishedAt < date)
                or.group(.and) { and in
                    and.filter(\.$publishedAt == date)
                    and.filter(\.$id < id)
                }
            }
        }

        let rows = try await query.sort(\.$publishedAt, .descending).sort(\.$id, .descending).limit(limit + 1).all()
        let page = Array(rows.prefix(limit))
        let next = rows.count > limit ? page.last.flatMap(Self.encodeCursor) : nil
        return try await ArticleListResponse(items: ArticlePresenter.summaries(page, on: req.db), nextCursor: next)
    }

    @Sendable
    func get(req: Request) async throws -> ArticleDetail {
        let viewer = ArticleService.viewerId(req)
        let article = try await ArticleService.requireVisible(ref: req.parameters.get("ref") ?? "", viewer: viewer, on: req.db)
        return try await ArticlePresenter.detail(article, viewerId: viewer, on: req.db)
    }

    // MARK: - Writes

    @Sendable
    func create(req: Request) async throws -> ArticleDetail {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let input = try req.content.decode(ArticleWriteRequest.self)
        let fields = try await ArticleService.validate(input, authorId: viewer.userId, on: req)

        if !viewer.isAdmin {
            let since = Date().addingTimeInterval(-86400)
            let recent = try await Article.query(on: req.db)
                .filter(\.$authorId == viewer.userId)
                .filter(\.$publishedAt > since)
                .count()
            guard recent < ArticleValidation.maxPerDay else {
                throw CodedAbort(status: .tooManyRequests, code: "article_daily_limit", reason: "You can publish 3 articles a day.")
            }
        }

        let source = input.source.flatMap { $0 == .unknown ? nil : $0 } ?? .web
        let article = Article(
            authorId: viewer.userId, code: "", slug: fields.slug, title: fields.title, bodyMarkdown: fields.body,
            bulletPoints: fields.bulletPoints, tickers: fields.tickers, disclosure: fields.disclosure,
            coverImageId: fields.coverImageId, source: source.rawValue, wordCount: fields.wordCount
        )
        try await ArticleService.insert(article, on: req.db)
        req.logger.notice("articles.published code=\(article.code) source=\(source.rawValue)")
        return try await ArticlePresenter.detail(article, viewerId: viewer.userId, on: req.db)
    }

    @Sendable
    func update(req: Request) async throws -> ArticleDetail {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let article = try await ArticleService.requireVisible(ref: req.parameters.get("ref") ?? "", viewer: viewer.userId, on: req.db)
        guard article.authorId == viewer.userId else {
            throw Abort(.forbidden, reason: "You can only edit your own articles.")
        }
        let fields = try await ArticleService.validate(req.content.decode(ArticleWriteRequest.self), authorId: viewer.userId, on: req)
        article.title = fields.title
        article.slug = fields.slug
        article.bodyMarkdown = fields.body
        article.bulletPoints = fields.bulletPoints
        article.tickers = fields.tickers
        article.disclosure = fields.disclosure
        article.coverImageId = fields.coverImageId
        article.wordCount = fields.wordCount
        article.editedAt = Date()
        try await article.save(on: req.db)
        return try await ArticlePresenter.detail(article, viewerId: viewer.userId, on: req.db)
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let article = try await ArticleService.requireVisible(ref: req.parameters.get("ref") ?? "", viewer: viewer.userId, on: req.db)
        guard article.authorId == viewer.userId || viewer.isAdmin else {
            throw Abort(.forbidden, reason: "You can only delete your own articles.")
        }
        article.status = ArticleStatus.deleted.rawValue
        try await article.save(on: req.db)
        return .noContent
    }

    // MARK: - Cursor

    /// `<epoch milliseconds>_<uuid>`: stable across equal timestamps.
    static func encodeCursor(_ article: Article) -> String? {
        guard let id = article.id else { return nil }
        return "\(Int64((article.publishedAt.timeIntervalSince1970 * 1000).rounded()))_\(id.uuidString)"
    }

    static func decodeCursor(_ raw: String) -> (Date, UUID)? {
        let parts = raw.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, let millis = Int64(parts[0]), let id = UUID(uuidString: String(parts[1])) else { return nil }
        return (Date(timeIntervalSince1970: Double(millis) / 1000), id)
    }
}
```

> If `.filter(.sql(SQLBinaryExpression(...)))` doesn't resolve, use the equivalent `.filter(.custom(...))` in your
> FluentSQL version.

- [ ] **Step 6: Register the controller**

In `routes.swift`, after `try api.register(collection: CommunityAdminController())`:

```swift
    try api.register(collection: ArticlesController())
```

- [ ] **Step 7: Run the tests and check they pass**

Run: `swift test --filter "ArticlesRouteTests|ArticleValidationTests|ArticleSchemaTests"`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/StockPlanBackend/Articles Sources/StockPlanBackend/routes.swift Tests/StockPlanBackendTests/ArticlesRouteTests.swift
git commit -m "feat(articles): publish, read, list, edit and delete articles behind ARTICLES_ENABLED"
git show --stat HEAD
```

---

### Task 6: Votes, views and reports

**Files:**
- Modify: `norviq-backend/Sources/StockPlanBackend/Articles/ArticlesController.swift` (boot + handlers)
- Test: `norviq-backend/Tests/StockPlanBackendTests/ArticleEngagementTests.swift`

**Interfaces:**
- Consumes: `ArticleTestKit` (Task 5), `ArticleService`, `SocialReport` (`Social/SocialModels.swift`), `req.discord.send`.
- Produces:
  - `POST /v1/articles/:ref/vote` → `ArticleVoteResponse(voted: true)`
  - `DELETE /v1/articles/:ref/vote` → `ArticleVoteResponse(voted: false)`
  - `POST /v1/articles/:ref/view` → 204. Reads `X-Norviq-Viewer` for third-party tokens.
  - `POST /v1/articles/:ref/report` → 204

- [ ] **Step 1: Write the failing tests**

```swift
import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("Article engagement", .serialized)
struct ArticleEngagementTests {
    typealias Kit = ArticleTestKit

    @Test("voting is idempotent and the count always equals the rows")
    func votes() async throws {
        try await Kit.withApp { app in
            let ana = try await Kit.member(app, "v_ana")
            let bo = try await Kit.member(app, "v_bo")
            let code = try await Kit.publish(app, as: ana).article.code

            let first = try await Kit.send(app, .POST, "v1/articles/\(code)/vote", as: bo).decode(ArticleVoteResponse.self)
            let again = try await Kit.send(app, .POST, "v1/articles/\(code)/vote", as: bo).decode(ArticleVoteResponse.self)
            #expect(first == ArticleVoteResponse(upvoteCount: 1, voted: true))
            #expect(again == ArticleVoteResponse(upvoteCount: 1, voted: true))
            #expect(try await Kit.send(app, .GET, "v1/articles/\(code)", as: bo).decode(ArticleDetail.self).viewerUpvoted)

            let removed = try await Kit.send(app, .DELETE, "v1/articles/\(code)/vote", as: bo).decode(ArticleVoteResponse.self)
            let removedAgain = try await Kit.send(app, .DELETE, "v1/articles/\(code)/vote", as: bo).decode(ArticleVoteResponse.self)
            #expect(removed == ArticleVoteResponse(upvoteCount: 0, voted: false))
            #expect(removedAgain == ArticleVoteResponse(upvoteCount: 0, voted: false))
        }
    }

    @Test("a viewer counts once per day; a first-party session ignores the viewer header")
    func views() async throws {
        try await Kit.withApp { app in
            let ana = try await Kit.member(app, "w_ana")
            let bo = try await Kit.member(app, "w_bo")
            let code = try await Kit.publish(app, as: ana).article.code

            #expect(try await Kit.send(app, .POST, "v1/articles/\(code)/view", as: bo).status == .noContent)
            #expect(try await Kit.send(app, .POST, "v1/articles/\(code)/view", as: bo).status == .noContent)
            #expect(try await Kit.send(app, .POST, "v1/articles/\(code)/view", as: bo, headers: ["X-Norviq-Viewer": "0123456789abcdef0123456789abcdef"]).status == .noContent)
            #expect(try await Kit.send(app, .POST, "v1/articles/\(code)/view", as: ana).status == .noContent)

            let detail = try await Kit.send(app, .GET, "v1/articles/\(code)", as: bo).decode(ArticleDetail.self)
            #expect(detail.article.viewCount == 2)
        }
    }

    @Test("a report writes a social_reports row with target_type article; muted people can still report")
    func reports() async throws {
        try await Kit.withApp { app in
            let ana = try await Kit.member(app, "r_ana")
            let bo = try await Kit.member(app, "r_bo")
            let detail = try await Kit.publish(app, as: ana)
            let reply = try await Kit.send(
                app, .POST, "v1/articles/\(detail.article.code)/report", as: bo,
                body: ArticleReportRequest(reason: .scam, note: "Pump and dump")
            )
            #expect(reply.status == .noContent)
            let report = try #require(try await SocialReport.query(on: app.db).filter(\.$targetType == "article").first())
            #expect(report.targetId == detail.article.id.uuidString && report.reason == "scam")
        }
    }
}
```

- [ ] **Step 2: Run the tests and check they fail**

Run: `swift test --filter ArticleEngagementTests`
Expected: FAIL with 404 on `/vote` and `/view`.

- [ ] **Step 3: Add the routes to `boot`**

In `ArticlesController.boot`, after `read.get(":ref", use: get)`:

```swift
        read.grouped(RateLimitMiddleware(limit: 120, interval: 60, keyPrefix: "ratelimit:article-view"))
            .post(":ref", "view", use: view)
```

After `write.delete(":ref", use: delete)`:

```swift
        let votes = write.grouped(RateLimitMiddleware(limit: 60, interval: 60, keyPrefix: "ratelimit:article-vote"))
        votes.post(":ref", "vote", use: vote)
        votes.delete(":ref", "vote", use: unvote)
        write.grouped(RateLimitMiddleware(limit: 20, interval: 3600, keyPrefix: "ratelimit:article-report"))
            .post(":ref", "report", use: report)
```

- [ ] **Step 4: Add the handlers**

Add to `ArticlesController`:

```swift
    // MARK: - Engagement

    static let viewerHeader = "X-Norviq-Viewer"

    /// Counts at most one view per viewer per UTC day. A first-party session is
    /// keyed by user; the web's public token forwards a hashed visitor key.
    /// Without either, nothing is counted.
    @Sendable
    func view(req: Request) async throws -> HTTPStatus {
        let article = try await ArticleService.requireVisible(ref: req.parameters.get("ref") ?? "", viewer: nil, on: req.db)
        let key: String
        if let viewer = ArticleService.viewerId(req) {
            key = "u:\(viewer.uuidString)"
        } else if let header = req.headers.first(name: Self.viewerHeader),
                  (16 ... 64).contains(header.count), header.allSatisfy(\.isHexDigit)
        {
            key = "v:\(header.lowercased())"
        } else {
            return .noContent
        }
        let articleId = try article.requireID()
        let day = Self.utcDay(Date())
        let sql = try ArticleService.sql(req.db)
        let inserted = try await sql.raw("""
        INSERT INTO article_views (id, article_id, viewer_key, day)
        VALUES (\(bind: UUID()), \(bind: articleId), \(bind: key), \(bind: day))
        ON CONFLICT (article_id, viewer_key, day) DO NOTHING
        RETURNING id
        """).all()
        if !inserted.isEmpty {
            try await sql.raw("UPDATE articles SET view_count = view_count + 1 WHERE id = \(bind: articleId)").run()
        }
        return .noContent
    }

    @Sendable
    func vote(req: Request) async throws -> ArticleVoteResponse {
        try await setVote(true, req: req)
    }

    @Sendable
    func unvote(req: Request) async throws -> ArticleVoteResponse {
        try await setVote(false, req: req)
    }

    /// The vote row and the counter move in one transaction, so the counter is
    /// always the row count.
    private func setVote(_ on: Bool, req: Request) async throws -> ArticleVoteResponse {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let article = try await ArticleService.requireVisible(ref: req.parameters.get("ref") ?? "", viewer: nil, on: req.db)
        let articleId = try article.requireID()
        return try await req.db.transaction { tx in
            let sql = try ArticleService.sql(tx)
            let changed: Bool
            if on {
                changed = try await !sql.raw("""
                INSERT INTO article_votes (id, article_id, user_id, created_at)
                VALUES (\(bind: UUID()), \(bind: articleId), \(bind: viewer.userId), \(bind: Date()))
                ON CONFLICT (article_id, user_id) DO NOTHING
                RETURNING id
                """).all().isEmpty
            } else {
                changed = try await !sql.raw("""
                DELETE FROM article_votes WHERE article_id = \(bind: articleId) AND user_id = \(bind: viewer.userId)
                RETURNING id
                """).all().isEmpty
            }
            let delta = changed ? (on ? 1 : -1) : 0
            let row = try await sql.raw("""
            UPDATE articles SET upvote_count = GREATEST(upvote_count + \(bind: delta), 0)
            WHERE id = \(bind: articleId) RETURNING upvote_count
            """).first()
            let count = try row?.decode(column: "upvote_count", as: Int.self) ?? article.upvoteCount
            return ArticleVoteResponse(upvoteCount: count, voted: on)
        }
    }

    /// Reporting skips requireCanContribute on purpose: a muted person must
    /// still be able to flag a scam.
    @Sendable
    func report(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let article = try await ArticleService.requireVisible(ref: req.parameters.get("ref") ?? "", viewer: nil, on: req.db)
        let body = try req.content.decode(ArticleReportRequest.self)
        let note = body.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (note?.count ?? 0) <= 1000 else {
            throw Abort(.badRequest, reason: "Keep the details under 1,000 characters.")
        }
        try await SocialReport(
            reporterId: viewer.userId,
            targetType: "article",
            targetId: article.requireID().uuidString,
            reason: body.reason.rawValue,
            note: (note?.isEmpty ?? true) ? nil : note
        ).save(on: req.db)
        req.logger.notice("articles.report filed code=\(article.code) reason=\(body.reason.rawValue)")

        let reason = body.reason.rawValue
        let excerpt = "\(article.code) · \(article.title)"
        Task {
            do {
                try await req.discord.send("🚩 Article report (\(reason)):\n```\(excerpt.prefix(300))```", on: req)
            } catch {
                req.logger.warning("articles.report discord ping failed: \(String(describing: error))")
            }
        }
        return .noContent
    }

    static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
```

> Copy the `SocialReport(...)` initializer labels from `BoardsController.report` (lines ~481–487). They are
> `reporterId:targetType:targetId:reason:note:`.

- [ ] **Step 5: Run the tests and check they pass**

Run: `swift test --filter "ArticleEngagementTests|ArticlesRouteTests"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/StockPlanBackend/Articles/ArticlesController.swift Tests/StockPlanBackendTests/ArticleEngagementTests.swift
git commit -m "feat(articles): votes, daily-deduped views and reports"
git show --stat HEAD
```

---

### Task 7: Cover images and admin hide/unhide

**Files:**
- Modify: `norviq-backend/Sources/StockPlanBackend/Articles/ArticlesController.swift`
- Test: `norviq-backend/Tests/StockPlanBackendTests/ArticleImagesAndModerationTests.swift`

**Interfaces:**
- Consumes: `ArticleImageSniffer` (Task 3), `ArticleImage` (Task 4), `ArticleTestKit`.
- Produces:
  - `POST /v1/articles/images` (multipart field `file`) → `ArticleImageUploadResponse`
  - `GET /v1/articles/images/:imageId` → bytes with `Cache-Control: public, max-age=31536000, immutable`
  - `PUT /v1/admin/articles/:ref/visibility` with `ArticleVisibilityRequest` → 204 (admin only, else 403)

- [ ] **Step 1: Write the failing tests**

```swift
import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Article images and moderation", .serialized)
struct ArticleImagesAndModerationTests {
    typealias Kit = ArticleTestKit

    private func upload(_ app: Application, _ bytes: [UInt8], as auth: AuthResponse) async throws -> Kit.Reply {
        let boundary = "norviq-test-boundary"
        var body = ByteBuffer()
        body.writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"c.png\"\r\nContent-Type: image/png\r\n\r\n")
        body.writeBytes(bytes)
        body.writeString("\r\n--\(boundary)--\r\n")
        var reply: Kit.Reply?
        try await app.testing().test(.POST, "v1/articles/images", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: auth.token)
            req.headers.contentType = HTTPMediaType(type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
            req.body = body
        }, afterResponse: { res async throws in
            reply = Kit.Reply(status: res.status, body: Data(res.body.readableBytesView))
        })
        return try #require(reply)
    }

    @Test("upload a PNG, attach it as the cover, and fetch it back with immutable caching")
    func coverRoundTrip() async throws {
        try await Kit.withApp { app in
            let ana = try await Kit.member(app, "img_ana")
            let png = ArticleImageSnifferTests.png(width: 1200, height: 630)
            let uploaded = try await upload(app, png, as: ana)
            #expect(uploaded.status == .ok)
            let imageId = try uploaded.decode(ArticleImageUploadResponse.self).id

            let detail = try await Kit.publish(app, as: ana, Kit.input(cover: imageId))
            #expect(detail.article.coverImageId == imageId)

            try await app.testing().test(.GET, "v1/articles/images/\(imageId)", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: ana.token)
            }) { res in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.description == "image/png")
                #expect(res.headers.first(name: .cacheControl) == "public, max-age=31536000, immutable")
                #expect(Array(res.body.readableBytesView) == png)
            }
        }
    }

    @Test("an SVG upload is 415; someone else's image can't be used as a cover")
    func rejects() async throws {
        try await Kit.withApp { app in
            let ana = try await Kit.member(app, "rej_ana")
            let bo = try await Kit.member(app, "rej_bo")
            #expect(try await upload(app, Array("<svg onload=alert(1)>".utf8), as: ana).status == .unsupportedMediaType)
            let imageId = try await upload(app, ArticleImageSnifferTests.png(width: 10, height: 10), as: ana)
                .decode(ArticleImageUploadResponse.self).id
            #expect(try await Kit.send(app, .POST, "v1/articles", as: bo, body: Kit.input(cover: imageId)).status == .badRequest)
        }
    }

    @Test("hidden articles are visible to their author and admins only, and leave the feed")
    func hiddenIsAuthorAndAdminOnly() async throws {
        try await Kit.withApp { app in
            let admin = try await Kit.member(app, "mod_admin", email: Kit.adminEmail)
            let ana = try await Kit.member(app, "mod_ana")
            let bo = try await Kit.member(app, "mod_bo")
            let code = try await Kit.publish(app, as: ana).article.code

            #expect(try await Kit.send(app, .PUT, "v1/admin/articles/\(code)/visibility", as: bo, body: ArticleVisibilityRequest(hidden: true)).status == .forbidden)
            #expect(try await Kit.send(app, .PUT, "v1/admin/articles/\(code)/visibility", as: admin, body: ArticleVisibilityRequest(hidden: true)).status == .noContent)

            #expect(try await Kit.send(app, .GET, "v1/articles/\(code)", as: bo).status == .notFound)
            #expect(try await Kit.send(app, .GET, "v1/articles/\(code)", as: ana).status == .ok)
            #expect(try await Kit.send(app, .GET, "v1/articles/\(code)", as: admin).status == .ok)
            #expect(try await Kit.send(app, .GET, "v1/articles", as: bo).decode(ArticleListResponse.self).items.isEmpty)

            #expect(try await Kit.send(app, .PUT, "v1/admin/articles/\(code)/visibility", as: admin, body: ArticleVisibilityRequest(hidden: false)).status == .noContent)
            #expect(try await Kit.send(app, .GET, "v1/articles/\(code)", as: bo).status == .ok)
        }
    }
}
```

- [ ] **Step 2: Run the tests and check they fail**

Run: `swift test --filter ArticleImagesAndModerationTests`
Expected: FAIL with 404s.

- [ ] **Step 3: Add the routes**

In `boot`, after the `read.get(":ref", use: get)` line (Vapor matches the constant `images` before `:ref`):

```swift
        read.get("images", ":imageId", use: image)
```

After the report route:

```swift
        write.grouped(RateLimitMiddleware(limit: 20, interval: 3600, keyPrefix: "ratelimit:article-image"))
            .on(.POST, "images", body: .collect(maxSize: "3mb"), use: uploadImage)

        routes.grouped("admin", "articles")
            .grouped(ArticlesFlagMiddleware(), ScopedBearerAuthenticator(), SessionToken.guardMiddleware(),
                     FirstPartyOnlyMiddleware(), CommunityAccessMiddleware())
            .put(":ref", "visibility", use: setVisibility)
```

- [ ] **Step 4: Add the handlers**

```swift
    // MARK: - Images

    private struct ImageUpload: Content {
        var file: File
    }

    @Sendable
    func uploadImage(req: Request) async throws -> ArticleImageUploadResponse {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let upload = try req.content.decode(ImageUpload.self)
        let bytes = Array(upload.file.data.readableBytesView)
        let sniffed = try ArticleImageSniffer.sniff(bytes)
        let image = ArticleImage(ownerId: viewer.userId, image: sniffed, bytes: Data(bytes))
        try await image.create(on: req.db)
        return try ArticleImageUploadResponse(id: image.requireID())
    }

    @Sendable
    func image(req: Request) async throws -> Response {
        guard let id = req.parameters.get("imageId", as: UUID.self),
              let image = try await ArticleImage.find(id, on: req.db)
        else {
            throw Abort(.notFound)
        }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: image.contentType)
        // Image ids are never reused and the bytes never change.
        headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=31536000, immutable")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        return Response(status: .ok, headers: headers, body: .init(data: image.bytes))
    }

    // MARK: - Moderation

    @Sendable
    func setVisibility(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        guard viewer.isAdmin else { throw Abort(.forbidden, reason: "Admin access required.") }
        guard let article = try await ArticleService.find(ref: req.parameters.get("ref") ?? "", on: req.db),
              article.status != ArticleStatus.deleted.rawValue
        else {
            throw Abort(.notFound, reason: "Article not found")
        }
        let body = try req.content.decode(ArticleVisibilityRequest.self)
        article.status = body.hidden ? ArticleStatus.hidden.rawValue : ArticleStatus.published.rawValue
        try await article.save(on: req.db)
        req.logger.notice("articles.visibility code=\(article.code) hidden=\(body.hidden) by=\(viewer.userId)")
        return .noContent
    }
```

- [ ] **Step 5: Run the tests and check they pass**

Run: `swift test --filter "Article"`
Expected: PASS across all article suites.

- [ ] **Step 6: Commit**

```bash
git add Sources/StockPlanBackend/Articles/ArticlesController.swift Tests/StockPlanBackendTests/ArticleImagesAndModerationTests.swift
git commit -m "feat(articles): cover image upload/serve and admin hide/unhide"
git show --stat HEAD
```

---

### Task 8: OpenAPI documentation

**Files:**
- Modify: `norviq-backend/Sources/StockPlanBackend/openapi.yaml`. Add an `Articles` tag, the paths below, and schemas mirroring Task 1's DTOs.

**Interfaces:**
- Consumes: the routes from Tasks 5–7. Produces documentation only.

- [ ] **Step 1: Check how pilots are documented**

Run: `sed -n 15,30p Sources/StockPlanBackend/openapi.yaml && grep -n "/v1/pilots:" -A40 Sources/StockPlanBackend/openapi.yaml | head -60`
Copy the shapes from there: tag, security, the 404 wording "or the articles feature is disabled (`ARTICLES_ENABLED` off)", and the `$ref` style.

- [ ] **Step 2: Add the tag and paths**

Add the tag:

```yaml
  - name: Articles
    description: User-published, ticker-tagged stock articles. Gated by `ARTICLES_ENABLED`; every route returns 404 when it is off.
```

Document these paths. Each gets `tags: [Articles]`, `security: [{bearerAuth: []}]`, a `404` response with the flag wording, and an operationId:

| path | method | operationId | request | 200/204 response |
|---|---|---|---|---|
| `/v1/articles` | get | `listArticles` | query `ticker`, `author`, `cursor`, `limit` | `ArticleListResponse` |
| `/v1/articles` | post | `createArticle` | `ArticleWriteRequest` | `ArticleDetail`; also `400`, `403` (codes `community_muted`, `username_required`, `guidelines_required`), `429` (`article_daily_limit`) |
| `/v1/articles/{ref}` | get | `getArticle` | path `ref` (uuid or 8-char code) | `ArticleDetail` |
| `/v1/articles/{ref}` | patch | `updateArticle` | `ArticleWriteRequest` | `ArticleDetail`; `403` when not the author |
| `/v1/articles/{ref}` | delete | `deleteArticle` | — | `204` |
| `/v1/articles/{ref}/vote` | post | `voteArticle` | — | `ArticleVoteResponse` |
| `/v1/articles/{ref}/vote` | delete | `unvoteArticle` | — | `ArticleVoteResponse` |
| `/v1/articles/{ref}/view` | post | `recordArticleView` | header `X-Norviq-Viewer` (optional, 16–64 hex) | `204` |
| `/v1/articles/{ref}/report` | post | `reportArticle` | `ArticleReportRequest` | `204` |
| `/v1/articles/images` | post | `uploadArticleImage` | `multipart/form-data` field `file` (binary) | `ArticleImageUploadResponse`; `413`, `415` |
| `/v1/articles/images/{imageId}` | get | `getArticleImage` | — | `image/png`, `image/jpeg`, `image/webp` binary |
| `/v1/admin/articles/{ref}/visibility` | put | `setArticleVisibility` | `ArticleVisibilityRequest` | `204`; `403` |

Schemas: `ArticleAuthor`, `ArticleSummary`, `ArticleDetail`, `ArticleListResponse`, `ArticleWriteRequest`, `ArticleVoteResponse`, `ArticleReportRequest` (with `reason` referencing the existing board report reason enum if the spec has one, else inline the 7 values), `ArticleImageUploadResponse`, `ArticleVisibilityRequest`. Field names and types match Task 1 exactly. Dates are `format: date-time`, ids `format: uuid`.

- [ ] **Step 3: Run the docs check**

Run: `make backend-openapi-check` (or `swift test --filter OpenAPIDocsTests`)
Expected: PASS. If it complains that a route isn't documented, or that a path doesn't exist, fix the yaml, not the routes.

- [ ] **Step 4: Run the full suite**

Run: `make backend-test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/StockPlanBackend/openapi.yaml
git commit -m "docs(articles): document article endpoints in openapi.yaml"
git show --stat HEAD
```

---

# Part C — norviq-web (branch `feat/articles` from `main`; leave the unrelated `Dockerfile` change alone)

Before Task 9:

```bash
cd ~/Work/production/apps/norviq/norviq-web && git checkout main && git pull && git checkout -b feat/articles
go get github.com/yuin/goldmark@latest github.com/microcosm-cc/bluemonday@latest golang.org/x/image@latest
go mod tidy && go mod vendor
git add go.mod go.sum vendor && git commit -m "chore(deps): add goldmark, bluemonday and x/image for articles"
```

`make test` runs `go test ./... -count=1`. Generated `*_templ.go` files must be regenerated with `templ generate` after every `.templ` edit, and committed (the repo commits them).

### Task 9: Backend client for articles

**Files:**
- Create: `norviq-web/internal/api/articles.go`
- Test: `norviq-web/internal/api/articles_test.go`

**Interfaces:**
- Consumes: `Service.BaseURL`, `doBoardsRequest`, `BoardsError`, `BackendHTTPTimeout`, `RequestEditorFn` (`func(ctx, *http.Request) error`).
- Produces types: `ArticleAuthor`, `ArticleSummary`, `ArticleDetail`, `ArticlePage`, `ArticleWriteRequest`, `ArticleVoteResponse`, `ArticleListQuery{Ticker, Author, Cursor string; Limit int}`.
- Produces methods on `*Service`:
  - `ListArticles(ctx, ArticleListQuery, editor) (*ArticlePage, error)`
  - `GetArticle(ctx, ref, editor) (*ArticleDetail, error)`
  - `CreateArticle(ctx, ArticleWriteRequest, editor) (*ArticleDetail, error)`
  - `UpdateArticle(ctx, ref, ArticleWriteRequest, editor) (*ArticleDetail, error)`
  - `DeleteArticle(ctx, ref, editor) error`
  - `VoteArticle(ctx, ref, on bool, editor) (*ArticleVoteResponse, error)`
  - `ReportArticle(ctx, ref, reason, note string, editor) error`
  - `RecordArticleView(ctx, ref, viewerKey string, editor) error`
  - `UploadArticleImage(ctx, filename string, data []byte, editor) (string, error)`
  - `FetchArticleImage(ctx, id string, editor) ([]byte, string, error)`
  - `SetArticleVisibility(ctx, ref string, hidden bool, editor) error`

- [ ] **Step 1: Write the failing test**

```go
package api

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func articlesTestService(t *testing.T, handler http.HandlerFunc) *Service {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	svc, err := NewService(srv.URL)
	require.NoError(t, err)
	return svc
}

func TestListArticlesSendsFiltersAndDecodes(t *testing.T) {
	t.Parallel()
	var got *http.Request
	svc := articlesTestService(t, func(w http.ResponseWriter, r *http.Request) {
		got = r
		_, _ = w.Write([]byte(`{"items":[{"id":"x","code":"abcd2345","slug":"why","title":"Why","bulletPoints":["b"],"tickers":["NVDA"],"author":{"id":"a","username":"ana","avatarURL":null},"coverImageId":null,"upvoteCount":2,"viewCount":9,"wordCount":300,"status":"published","source":"web","publishedAt":"2026-10-01T04:41:27Z","editedAt":null}],"nextCursor":"1_x"}`))
	})
	page, err := svc.ListArticles(context.Background(), ArticleListQuery{Ticker: "NVDA", Cursor: "1_x", Limit: 20}, WithBearerToken("tok"))
	require.NoError(t, err)
	assert.Equal(t, "/v1/articles", got.URL.Path)
	assert.Equal(t, "NVDA", got.URL.Query().Get("ticker"))
	assert.Equal(t, "1_x", got.URL.Query().Get("cursor"))
	assert.Equal(t, "20", got.URL.Query().Get("limit"))
	assert.Equal(t, "Bearer tok", got.Header.Get("Authorization"))
	require.Len(t, page.Items, 1)
	assert.Equal(t, "abcd2345", page.Items[0].Code)
	assert.Equal(t, "ana", *page.Items[0].Author.Username)
	require.NotNil(t, page.NextCursor)
}

func TestVoteArticleUsesPostAndDelete(t *testing.T) {
	t.Parallel()
	var methods []string
	svc := articlesTestService(t, func(w http.ResponseWriter, r *http.Request) {
		methods = append(methods, r.Method+" "+r.URL.Path)
		_, _ = w.Write([]byte(`{"upvoteCount":1,"voted":true}`))
	})
	_, err := svc.VoteArticle(context.Background(), "abcd2345", true, nil)
	require.NoError(t, err)
	_, err = svc.VoteArticle(context.Background(), "abcd2345", false, nil)
	require.NoError(t, err)
	assert.Equal(t, []string{"POST /v1/articles/abcd2345/vote", "DELETE /v1/articles/abcd2345/vote"}, methods)
}

func TestRecordArticleViewForwardsViewerKey(t *testing.T) {
	t.Parallel()
	var viewer, auth string
	svc := articlesTestService(t, func(w http.ResponseWriter, r *http.Request) {
		viewer, auth = r.Header.Get("X-Norviq-Viewer"), r.Header.Get("Authorization")
		w.WriteHeader(http.StatusNoContent)
	})
	require.NoError(t, svc.RecordArticleView(context.Background(), "abcd2345", "0123456789abcdef", WithBearerToken("pub")))
	assert.Equal(t, "0123456789abcdef", viewer)
	assert.Equal(t, "Bearer pub", auth)
}

func TestUploadArticleImageSendsMultipart(t *testing.T) {
	t.Parallel()
	var filePart []byte
	svc := articlesTestService(t, func(w http.ResponseWriter, r *http.Request) {
		file, _, err := r.FormFile("file")
		require.NoError(t, err)
		filePart, _ = io.ReadAll(file)
		_, _ = w.Write([]byte(`{"id":"11111111-1111-1111-1111-111111111111"}`))
	})
	id, err := svc.UploadArticleImage(context.Background(), "cover.png", []byte("PNGDATA"), nil)
	require.NoError(t, err)
	assert.Equal(t, "11111111-1111-1111-1111-111111111111", id)
	assert.Equal(t, "PNGDATA", string(filePart))
}

func TestArticleErrorsCarryTheEnvelope(t *testing.T) {
	t.Parallel()
	svc := articlesTestService(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"error":true,"code":"article_daily_limit","reason":"You can publish 3 articles a day."}`))
	})
	_, err := svc.CreateArticle(context.Background(), ArticleWriteRequest{Title: "t"}, nil)
	require.Error(t, err)
	assert.True(t, IsBoardsCode(err, "article_daily_limit"))
	assert.True(t, strings.Contains(BoardsErrorFrom(err).Reason, "3 articles"))
}
```

- [ ] **Step 2: Run the test and check it fails**

Run: `go test ./internal/api -run 'Article' -count=1`
Expected: FAIL with "undefined: ArticleListQuery".

- [ ] **Step 3: Write the client**

```go
package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

// Articles. Called directly like boards.go; shapes match StockPlanShared
// ArticlesDTOs, and refusals come back as *BoardsError (same envelope).

type ArticleAuthor struct {
	ID        string  `json:"id"`
	Username  *string `json:"username"`
	AvatarURL *string `json:"avatarURL"`
}

type ArticleSummary struct {
	ID           string        `json:"id"`
	Code         string        `json:"code"`
	Slug         string        `json:"slug"`
	Title        string        `json:"title"`
	BulletPoints []string      `json:"bulletPoints"`
	Tickers      []string      `json:"tickers"`
	Author       ArticleAuthor `json:"author"`
	CoverImageID *string       `json:"coverImageId"`
	UpvoteCount  int           `json:"upvoteCount"`
	ViewCount    int           `json:"viewCount"`
	WordCount    int           `json:"wordCount"`
	Status       string        `json:"status"`
	Source       string        `json:"source"`
	PublishedAt  time.Time     `json:"publishedAt"`
	EditedAt     *time.Time    `json:"editedAt"`
}

type ArticleDetail struct {
	Article        ArticleSummary `json:"article"`
	BodyMarkdown   string         `json:"bodyMarkdown"`
	Disclosure     string         `json:"disclosure"`
	ViewerUpvoted  bool           `json:"viewerUpvoted"`
	ViewerIsAuthor bool           `json:"viewerIsAuthor"`
}

type ArticlePage struct {
	Items      []ArticleSummary `json:"items"`
	NextCursor *string          `json:"nextCursor"`
}

type ArticleWriteRequest struct {
	Title        string   `json:"title"`
	BodyMarkdown string   `json:"bodyMarkdown"`
	BulletPoints []string `json:"bulletPoints"`
	Tickers      []string `json:"tickers"`
	Disclosure   string   `json:"disclosure"`
	CoverImageID *string  `json:"coverImageId"`
	Source       string   `json:"source,omitempty"`
}

type ArticleVoteResponse struct {
	UpvoteCount int  `json:"upvoteCount"`
	Voted       bool `json:"voted"`
}

type ArticleListQuery struct {
	Ticker string
	Author string
	Cursor string
	Limit  int
}

func articlePath(ref string, rest ...string) string {
	path := "/v1/articles/" + url.PathEscape(ref)
	for _, segment := range rest {
		path += "/" + segment
	}
	return path
}

func (s *Service) ListArticles(ctx context.Context, q ArticleListQuery, editor RequestEditorFn) (*ArticlePage, error) {
	values := url.Values{}
	if q.Ticker != "" {
		values.Set("ticker", q.Ticker)
	}
	if q.Author != "" {
		values.Set("author", q.Author)
	}
	if q.Cursor != "" {
		values.Set("cursor", q.Cursor)
	}
	if q.Limit > 0 {
		values.Set("limit", strconv.Itoa(q.Limit))
	}
	path := "/v1/articles"
	if encoded := values.Encode(); encoded != "" {
		path += "?" + encoded
	}
	var out ArticlePage
	return &out, s.doBoardsRequest(ctx, http.MethodGet, path, nil, &out, editor)
}

func (s *Service) GetArticle(ctx context.Context, ref string, editor RequestEditorFn) (*ArticleDetail, error) {
	var out ArticleDetail
	return &out, s.doBoardsRequest(ctx, http.MethodGet, articlePath(ref), nil, &out, editor)
}

func (s *Service) CreateArticle(ctx context.Context, req ArticleWriteRequest, editor RequestEditorFn) (*ArticleDetail, error) {
	var out ArticleDetail
	return &out, s.doBoardsRequest(ctx, http.MethodPost, "/v1/articles", req, &out, editor)
}

func (s *Service) UpdateArticle(ctx context.Context, ref string, req ArticleWriteRequest, editor RequestEditorFn) (*ArticleDetail, error) {
	var out ArticleDetail
	return &out, s.doBoardsRequest(ctx, http.MethodPatch, articlePath(ref), req, &out, editor)
}

func (s *Service) DeleteArticle(ctx context.Context, ref string, editor RequestEditorFn) error {
	return s.doBoardsRequest(ctx, http.MethodDelete, articlePath(ref), nil, nil, editor)
}

func (s *Service) VoteArticle(ctx context.Context, ref string, on bool, editor RequestEditorFn) (*ArticleVoteResponse, error) {
	method := http.MethodPost
	if !on {
		method = http.MethodDelete
	}
	var out ArticleVoteResponse
	return &out, s.doBoardsRequest(ctx, method, articlePath(ref, "vote"), nil, &out, editor)
}

func (s *Service) ReportArticle(ctx context.Context, ref, reason, note string, editor RequestEditorFn) error {
	payload := struct {
		Reason string  `json:"reason"`
		Note   *string `json:"note"`
	}{Reason: reason}
	if note != "" {
		payload.Note = &note
	}
	return s.doBoardsRequest(ctx, http.MethodPost, articlePath(ref, "report"), payload, nil, editor)
}

// RecordArticleView forwards a hashed visitor key. The backend only reads it
// for the public token; a signed-in session is keyed by user instead.
func (s *Service) RecordArticleView(ctx context.Context, ref, viewerKey string, editor RequestEditorFn) error {
	withViewer := func(ctx context.Context, req *http.Request) error {
		req.Header.Set("X-Norviq-Viewer", viewerKey)
		if editor != nil {
			return editor(ctx, req)
		}
		return nil
	}
	return s.doBoardsRequest(ctx, http.MethodPost, articlePath(ref, "view"), nil, nil, withViewer)
}

func (s *Service) SetArticleVisibility(ctx context.Context, ref string, hidden bool, editor RequestEditorFn) error {
	payload := struct {
		Hidden bool `json:"hidden"`
	}{hidden}
	return s.doBoardsRequest(ctx, http.MethodPut, "/v1/admin/articles/"+url.PathEscape(ref)+"/visibility", payload, nil, editor)
}

// UploadArticleImage posts one cover image as multipart field "file" and
// returns the new image id.
func (s *Service) UploadArticleImage(ctx context.Context, filename string, data []byte, editor RequestEditorFn) (string, error) {
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", filename)
	if err != nil {
		return "", fmt.Errorf("build image upload: %w", err)
	}
	if _, err := part.Write(data); err != nil {
		return "", fmt.Errorf("build image upload: %w", err)
	}
	if err := writer.Close(); err != nil {
		return "", fmt.Errorf("build image upload: %w", err)
	}
	resp, err := s.doArticleRaw(ctx, http.MethodPost, "/v1/articles/images", &body, writer.FormDataContentType(), editor)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var out struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&out); err != nil {
		return "", fmt.Errorf("decode image upload: %w", err)
	}
	return out.ID, nil
}

// FetchArticleImage returns a cover's bytes and content type.
func (s *Service) FetchArticleImage(ctx context.Context, id string, editor RequestEditorFn) ([]byte, string, error) {
	resp, err := s.doArticleRaw(ctx, http.MethodGet, "/v1/articles/images/"+url.PathEscape(id), nil, "", editor)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 3<<20))
	if err != nil {
		return nil, "", fmt.Errorf("read article image: %w", err)
	}
	return data, resp.Header.Get("Content-Type"), nil
}

// doArticleRaw is doBoardsRequest for bodies that aren't JSON. The caller
// closes the response body on success.
func (s *Service) doArticleRaw(ctx context.Context, method, path string, body io.Reader, contentType string, editor RequestEditorFn) (*http.Response, error) {
	if s == nil || s.BaseURL == "" {
		return nil, fmt.Errorf("api service unavailable")
	}
	if body == nil {
		body = http.NoBody
	}
	req, err := http.NewRequestWithContext(ctx, method, s.BaseURL+path, body)
	if err != nil {
		return nil, fmt.Errorf("build articles request: %w", err)
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	if editor != nil {
		if err := editor(ctx, req); err != nil {
			return nil, fmt.Errorf("authorize articles request: %w", err)
		}
	}
	resp, err := (&http.Client{Timeout: BackendHTTPTimeout}).Do(req)
	if err != nil {
		return nil, fmt.Errorf("articles request: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		defer resp.Body.Close()
		var envelope struct {
			Code    string            `json:"code"`
			Reason  string            `json:"reason"`
			Details map[string]string `json:"details"`
		}
		_ = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&envelope)
		return nil, &BoardsError{Status: resp.StatusCode, Code: envelope.Code, Reason: envelope.Reason, Details: envelope.Details}
	}
	return resp, nil
}
```

> Check that `RequestEditorFn` in package `api` (see `service.go:217`) has the signature `func(ctx context.Context, req *http.Request) error`.
> If its name or shape differs, adapt `withViewer`.

- [ ] **Step 4: Run the tests and check they pass**

Run: `go test ./internal/api -run 'Article' -count=1`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add internal/api/articles.go internal/api/articles_test.go
git commit -m "feat(articles): backend client for articles"
```

---

### Task 10: Safe Markdown rendering

**Files:**
- Create: `norviq-web/internal/markdown/markdown.go`
- Test: `norviq-web/internal/markdown/markdown_test.go`

**Interfaces:**
- Produces `markdown.Render(src string) string`. The output is sanitised HTML and safe for `templ.Raw`.

- [ ] **Step 1: Write the failing test**

```go
package markdown

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestRenderStripsDangerousMarkup(t *testing.T) {
	t.Parallel()
	cases := map[string][]string{
		"<script>alert(1)</script>\n\nhello":      {"<script", "alert(1)"},
		`<img src=x onerror="alert(1)">`:          {"<img", "onerror"},
		"[click](javascript:alert(1))":            {"javascript:"},
		`<iframe src="https://evil.example"></iframe>`: {"<iframe"},
		`<a href="https://x.com" onclick="steal()">x</a>`: {"onclick"},
		"![pixel](https://tracker.example/p.gif)":   {"<img"},
	}
	for input, banned := range cases {
		html := Render(input)
		for _, b := range banned {
			assert.NotContains(t, html, b, "input %q", input)
		}
	}
}

func TestRenderKeepsFormattingAndHardensExternalLinks(t *testing.T) {
	t.Parallel()
	html := Render("**Bold** and [site](https://example.com)\n\n- one\n- two")
	assert.Contains(t, html, "<strong>Bold</strong>")
	assert.Contains(t, html, `href="https://example.com"`)
	assert.Contains(t, html, "nofollow")
	assert.Contains(t, html, `target="_blank"`)
	assert.Contains(t, html, "<li>one</li>")
}

func TestRenderLinksCashtagsOutsideCode(t *testing.T) {
	t.Parallel()
	html := Render("I like $NVDA and ($BRK.B). Not $lower.\n\n```\n$AMD\n```")
	assert.Contains(t, html, `<a href="/articles/ticker/NVDA">$NVDA</a>`)
	assert.Contains(t, html, `<a href="/articles/ticker/BRK.B">$BRK.B</a>`)
	assert.NotContains(t, html, "/articles/ticker/LOWER")
	assert.NotContains(t, html, "/articles/ticker/AMD", "code blocks stay literal")
}
```

- [ ] **Step 2: Run the test and check it fails**

Run: `go test ./internal/markdown -count=1`
Expected: FAIL with "undefined: Render".

- [ ] **Step 3: Write the renderer**

```go
// Package markdown renders user-written article bodies to HTML that is safe to
// embed: goldmark with raw HTML left disabled, then a bluemonday allowlist.
package markdown

import (
	"bytes"
	"regexp"
	"strings"

	"github.com/microcosm-cc/bluemonday"
	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
)

var (
	// goldmark omits raw HTML unless WithUnsafe is set; it is never set here.
	converter = goldmark.New(goldmark.WithExtensions(extension.GFM))
	policy    = newPolicy()
	cashtag   = regexp.MustCompile(`(^|[\s(])\$([A-Z][A-Z0-9.\-]{0,9})\b`)
)

// newPolicy allows text formatting, lists, quotes, code, tables and links.
// No images: article bodies are text, and a remote <img> is a tracking pixel.
func newPolicy() *bluemonday.Policy {
	p := bluemonday.NewPolicy()
	p.AllowElements("p", "br", "strong", "em", "del", "blockquote", "ul", "ol", "li",
		"h2", "h3", "h4", "pre", "code", "hr", "table", "thead", "tbody", "tr", "th", "td", "a")
	p.AllowAttrs("href").OnElements("a")
	p.AllowURLSchemes("http", "https", "mailto")
	p.AllowRelativeURLs(true)
	p.RequireParseableURLs(true)
	p.RequireNoFollowOnFullyQualifiedLinks(true)
	p.RequireNoReferrerOnFullyQualifiedLinks(true)
	p.AddTargetBlankToFullyQualifiedLinks(true)
	return p
}

// Render returns sanitised HTML for an article body.
func Render(src string) string {
	var buf bytes.Buffer
	if err := converter.Convert([]byte(linkCashtags(src)), &buf); err != nil {
		return ""
	}
	return policy.Sanitize(buf.String())
}

// linkCashtags turns $NVDA into a link to that ticker's articles, leaving
// fenced and indented code alone.
func linkCashtags(src string) string {
	lines := strings.Split(src, "\n")
	inFence := false
	for i, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), "```") {
			inFence = !inFence
			continue
		}
		if inFence || strings.HasPrefix(line, "    ") || strings.HasPrefix(line, "\t") {
			continue
		}
		lines[i] = cashtag.ReplaceAllString(line, "${1}[$$${2}](/articles/ticker/${2})")
	}
	return strings.Join(lines, "\n")
}
```

- [ ] **Step 4: Run the tests and check they pass**

Run: `go test ./internal/markdown -count=1`
Expected: PASS. If the external-link test shows `rel` without `nofollow`, check the bluemonday version's method names (`RequireNoFollowOnFullyQualifiedLinks`) and adjust.

- [ ] **Step 5: Commit**

```bash
git add internal/markdown
git commit -m "feat(articles): sanitised markdown rendering with cashtag links"
```

---

### Task 11: Articles feature gate

**Files:**
- Create: `norviq-web/internal/articlegate/articlegate.go`
- Create: `norviq-web/internal/middleware/articles.go`
- Test: `norviq-web/internal/middleware/articles_test.go`

**Interfaces:**
- Consumes: `api.Service.DoJSON`, `api.WithBearerToken`, `api.APIError`, `config.Config.PublicAPIToken`, `config.PublicPagesEnabled()`.
- Produces:
  - `articlegate.WithEnabled(ctx, bool)`
  - `articlegate.Enabled(ctx) bool`
  - `middleware.AttachArticlesAvailability(*api.Service, *config.Config) func(http.Handler) http.Handler`
  - `middleware.RequireArticles(http.Handler) http.Handler`

- [ ] **Step 1: Write `articlegate.go`**

This file has no logic beyond context storage, so it has no test of its own.

```go
// Package articlegate carries "is the articles feature on" through a request.
//
// The backend owns the switch (ARTICLES_ENABLED) and 404s every /v1/articles
// route while it is off. The probe lives in internal/middleware; this leaf
// package only stores the answer so templates can read it without importing
// the API client.
package articlegate

import "context"

type enabledKey struct{}

func WithEnabled(ctx context.Context, enabled bool) context.Context {
	return context.WithValue(ctx, enabledKey{}, enabled)
}

// Enabled is false when nothing stored an answer.
func Enabled(ctx context.Context) bool {
	if ctx == nil {
		return false
	}
	enabled, _ := ctx.Value(enabledKey{}).(bool)
	return enabled
}
```

- [ ] **Step 2: Write the failing middleware test**

```go
package middleware

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/FinancePlanner/StockPlanWeb/internal/api"
	"github.com/FinancePlanner/StockPlanWeb/internal/articlegate"
	"github.com/FinancePlanner/StockPlanWeb/internal/config"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func articlesProbeBackend(t *testing.T, status int) (*api.Service, *atomic.Int32) {
	t.Helper()
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		assert.Equal(t, "/v1/articles", r.URL.Path)
		assert.Equal(t, "Bearer public-token", r.Header.Get("Authorization"))
		w.WriteHeader(status)
		if status == http.StatusOK {
			_, _ = w.Write([]byte(`{"items":[],"nextCursor":null}`))
		}
	}))
	t.Cleanup(srv.Close)
	svc, err := api.NewService(srv.URL)
	require.NoError(t, err)
	return svc, &calls
}

func probeArticlesGate(t *testing.T, mw func(http.Handler) http.Handler) bool {
	t.Helper()
	var enabled bool
	h := mw(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) { enabled = articlegate.Enabled(r.Context()) }))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/", nil))
	return enabled
}

func TestArticlesGateOnAndCached(t *testing.T) {
	t.Parallel()
	svc, calls := articlesProbeBackend(t, http.StatusOK)
	mw := AttachArticlesAvailability(svc, &config.Config{PublicAPIToken: "public-token"})
	assert.True(t, probeArticlesGate(t, mw))
	assert.True(t, probeArticlesGate(t, mw))
	assert.Equal(t, int32(1), calls.Load(), "the answer is cached")
}

func TestArticlesGateOffOn404(t *testing.T) {
	t.Parallel()
	svc, _ := articlesProbeBackend(t, http.StatusNotFound)
	assert.False(t, probeArticlesGate(t, AttachArticlesAvailability(svc, &config.Config{PublicAPIToken: "public-token"})))
}

func TestArticlesGateOffWithoutPublicToken(t *testing.T) {
	t.Parallel()
	svc, calls := articlesProbeBackend(t, http.StatusOK)
	assert.False(t, probeArticlesGate(t, AttachArticlesAvailability(svc, &config.Config{})))
	assert.Equal(t, int32(0), calls.Load())
}

func TestRequireArticles404sWhenOff(t *testing.T) {
	t.Parallel()
	rec := httptest.NewRecorder()
	RequireArticles(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusTeapot) })).
		ServeHTTP(rec, httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/articles", nil))
	assert.Equal(t, http.StatusNotFound, rec.Code)
}
```

- [ ] **Step 3: Run the test and check it fails**

Run: `go test ./internal/middleware -run Articles -count=1`
Expected: FAIL with "undefined: AttachArticlesAvailability".

- [ ] **Step 4: Write the middleware**

```go
package middleware

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/FinancePlanner/StockPlanWeb/internal/api"
	"github.com/FinancePlanner/StockPlanWeb/internal/articlegate"
	"github.com/FinancePlanner/StockPlanWeb/internal/config"
	"golang.org/x/sync/singleflight"
)

const (
	articlesProbeTTL        = 60 * time.Second
	articlesProbeFailureTTL = 10 * time.Second
	articlesProbeTimeout    = 3 * time.Second
)

type articlesProbeCache struct {
	mu      sync.Mutex
	enabled bool
	expires time.Time
	group   singleflight.Group
}

// AttachArticlesAvailability puts "articles on" on the request context. Like
// the pilots probe, there is no config route: GET /v1/articles is the probe,
// 2xx is on and 404 is off (both cached for a minute); anything else is off
// and cached briefly. Articles are public, so the probe uses the public token,
// never a visitor's session, and the feature is off without that token.
func AttachArticlesAvailability(apiService *api.Service, cfg *config.Config) func(http.Handler) http.Handler {
	cache := &articlesProbeCache{}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			enabled := cache.load(r.Context(), apiService, cfg)
			next.ServeHTTP(w, r.WithContext(articlegate.WithEnabled(r.Context(), enabled)))
		})
	}
}

func (c *articlesProbeCache) load(ctx context.Context, apiService *api.Service, cfg *config.Config) bool {
	if apiService == nil || apiService.BaseURL == "" || !cfg.PublicPagesEnabled() {
		return false
	}
	c.mu.Lock()
	if time.Now().Before(c.expires) {
		enabled := c.enabled
		c.mu.Unlock()
		return enabled
	}
	c.mu.Unlock()

	shared, _, _ := c.group.Do("probe", func() (any, error) {
		probeCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), articlesProbeTimeout)
		defer cancel()
		var page json.RawMessage
		err := apiService.DoJSON(probeCtx, http.MethodGet, "/v1/articles?limit=1", nil, &page, api.WithBearerToken(cfg.PublicAPIToken))
		enabled, ttl := false, articlesProbeFailureTTL
		var apiErr *api.APIError
		switch {
		case err == nil:
			enabled, ttl = true, articlesProbeTTL
		case errors.As(err, &apiErr) && apiErr.StatusCode == http.StatusNotFound:
			ttl = articlesProbeTTL
		default:
			slog.Warn("articles probe failed; article surfaces hidden", "error", err)
		}
		c.mu.Lock()
		c.enabled, c.expires = enabled, time.Now().Add(ttl)
		c.mu.Unlock()
		return enabled, nil
	})
	enabled, _ := shared.(bool)
	return enabled
}

// RequireArticles 404s article routes while the backend has them off.
func RequireArticles(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !articlegate.Enabled(r.Context()) {
			http.NotFound(w, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}
```

> Check that `DoJSON` accepts a path with a query string (`portfolio_reporting.go:242`). If it escapes the path,
> probe `/v1/articles` without the query instead.

- [ ] **Step 5: Run the tests and check they pass**

Run: `go test ./internal/middleware -run Articles -count=1 -race`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/articlegate internal/middleware/articles.go internal/middleware/articles_test.go
git commit -m "feat(articles): feature gate probed with the public token"
```

---

### Task 12: Share cards (og.png and Instagram card.png)

**Files:**
- Create: `norviq-web/internal/sharecard/sharecard.go`
- Test: `norviq-web/internal/sharecard/sharecard_test.go`

**Interfaces:**
- Produces:
  - `sharecard.Card{Title string; Tickers, Bullets []string; Author, Date, ShortURL string}`
  - `sharecard.Format{Width, Height int; Bullets bool}`, with `sharecard.OG` (1200×630, no bullets) and `sharecard.Instagram` (1080×1350, bullets)
  - `sharecard.Render(Card, Format) ([]byte, error)` returns PNG bytes
  - `sharecard.Disclaimer`

- [ ] **Step 1: Write the failing test**

```go
package sharecard

import (
	"bytes"
	"image/png"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func sample() Card {
	return Card{
		Title:    "Before the Next Phase: Why 2027 Could Reprice NextDecade",
		Tickers:  []string{"NEXT", "LNG"},
		Bullets:  []string{"First LNG from Train 1 is targeted for 1H 2027.", "Revenue visibility is unusually long: 25.3 MTPA under contract."},
		Author:   "@ana",
		Date:     "Oct 1, 2026",
		ShortURL: "norviq.org/a/abcd2345",
	}
}

func TestRenderSizes(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		format Format
		w, h   int
	}{{OG, 1200, 630}, {Instagram, 1080, 1350}} {
		data, err := Render(sample(), tc.format)
		require.NoError(t, err)
		cfg, err := png.DecodeConfig(bytes.NewReader(data))
		require.NoError(t, err)
		assert.Equal(t, tc.w, cfg.Width)
		assert.Equal(t, tc.h, cfg.Height)
	}
}

func TestRenderSurvivesExtremeInput(t *testing.T) {
	t.Parallel()
	c := Card{
		Title:   strings.Repeat("Supercalifragilistic ", 40),
		Tickers: []string{"A", "BB", "CCC", "DDDD", "EEEEE"},
		Bullets: []string{strings.Repeat("long ", 200), strings.Repeat("x", 300), "short one"},
	}
	_, err := Render(c, Instagram)
	require.NoError(t, err)
	_, err = Render(Card{}, OG)
	require.NoError(t, err)
}

func TestWrapCapsLinesWithEllipsis(t *testing.T) {
	t.Parallel()
	f := face(regularFont, 40)
	lines := wrap(f, strings.Repeat("word ", 100), 400, 2)
	require.Len(t, lines, 2)
	assert.True(t, strings.HasSuffix(lines[1], "…"))
	assert.Equal(t, []string{"short text"}, wrap(f, "short text", 400, 2))
}
```

- [ ] **Step 2: Run the test and check it fails**

Run: `go test ./internal/sharecard -count=1`
Expected: FAIL with "undefined: Render".

- [ ] **Step 3: Write the renderer**

```go
// Package sharecard draws an article's social preview images: the 1200×630
// og:image and the 1080×1350 portrait card for Instagram.
package sharecard

import (
	"bytes"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"strings"

	"golang.org/x/image/font"
	"golang.org/x/image/font/gofont/gobold"
	"golang.org/x/image/font/gofont/goregular"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/math/fixed"
)

const Disclaimer = "User-generated opinion. Not investment advice."

type Card struct {
	Title    string
	Tickers  []string
	Bullets  []string
	Author   string
	Date     string
	ShortURL string
}

type Format struct {
	Width   int
	Height  int
	Bullets bool
}

var (
	OG        = Format{Width: 1200, Height: 630}
	Instagram = Format{Width: 1080, Height: 1350, Bullets: true}

	boldFont    = mustParse(gobold.TTF)
	regularFont = mustParse(goregular.TTF)

	background = color.RGBA{0x0b, 0x12, 0x20, 0xff}
	foreground = color.RGBA{0xf8, 0xfa, 0xfc, 0xff}
	muted      = color.RGBA{0x94, 0xa3, 0xb8, 0xff}
	accent     = color.RGBA{0x34, 0xd3, 0x99, 0xff}
)

func mustParse(ttf []byte) *opentype.Font {
	f, err := opentype.Parse(ttf)
	if err != nil {
		panic(err)
	}
	return f
}

func face(f *opentype.Font, size float64) font.Face {
	fc, err := opentype.NewFace(f, &opentype.FaceOptions{Size: size, DPI: 72, Hinting: font.HintingFull})
	if err != nil {
		panic(err)
	}
	return fc
}

func drawText(dst draw.Image, f font.Face, x, y int, s string, c color.Color) {
	d := font.Drawer{Dst: dst, Src: image.NewUniform(c), Face: f, Dot: fixed.P(x, y)}
	d.DrawString(s)
}

// Render draws the card. Sizes scale with the format width.
func Render(c Card, f Format) ([]byte, error) {
	img := image.NewRGBA(image.Rect(0, 0, f.Width, f.Height))
	draw.Draw(img, img.Bounds(), image.NewUniform(background), image.Point{}, draw.Src)

	s := float64(f.Width) / 1200
	px := func(v float64) int { return int(v * s) }
	pad := px(80)
	width := f.Width - 2*pad
	footer := f.Height - pad

	y := pad + px(30)
	drawText(img, face(boldFont, 34*s), pad, y, "NORVIQ", accent)
	if len(c.Tickers) > 0 {
		y += px(70)
		drawText(img, face(boldFont, 38*s), pad, y, "$"+strings.Join(c.Tickers, "  $"), accent)
	}

	titleSize, titleLines := 60*s, 3
	if f.Bullets {
		titleSize, titleLines = 66*s, 4
	}
	titleFace := face(boldFont, titleSize)
	y += px(20)
	for _, line := range wrap(titleFace, c.Title, width, titleLines) {
		y += int(titleSize * 1.2)
		drawText(img, titleFace, pad, y, line, foreground)
	}

	if f.Bullets {
		bulletFace := face(regularFont, 38*s)
		limit := footer - px(190)
		y += px(30)
	bullets:
		for _, b := range c.Bullets {
			y += px(20)
			for i, line := range wrap(bulletFace, b, width-px(44), 3) {
				if y+px(52) > limit {
					break bullets
				}
				y += px(52)
				if i == 0 {
					drawText(img, bulletFace, pad, y, "•", accent)
				}
				drawText(img, bulletFace, pad+px(44), y, line, foreground)
			}
		}
	}

	if c.ShortURL != "" {
		drawText(img, face(boldFont, 32*s), pad, footer-px(100), c.ShortURL, accent)
	}
	byline := c.Author
	if c.Date != "" {
		if byline != "" {
			byline += " · "
		}
		byline += c.Date
	}
	drawText(img, face(regularFont, 32*s), pad, footer-px(50), byline, foreground)
	drawText(img, face(regularFont, 26*s), pad, footer, Disclaimer, muted)

	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// wrap breaks s into at most maxLines lines no wider than width. When text is
// cut, the last line ends with an ellipsis.
func wrap(f font.Face, s string, width, maxLines int) []string {
	var lines []string
	current := ""
	for _, word := range strings.Fields(s) {
		candidate := word
		if current != "" {
			candidate = current + " " + word
		}
		if current == "" || font.MeasureString(f, candidate).Ceil() <= width {
			current = candidate
			continue
		}
		if len(lines) == maxLines-1 {
			return append(lines, ellipsize(f, candidate, width))
		}
		lines = append(lines, fit(f, current, width))
		current = word
	}
	if current != "" {
		lines = append(lines, fit(f, current, width))
	}
	return lines
}

func fit(f font.Face, s string, width int) string {
	if font.MeasureString(f, s).Ceil() <= width {
		return s
	}
	return ellipsize(f, s, width)
}

func ellipsize(f font.Face, s string, width int) string {
	runes := []rune(s)
	for len(runes) > 0 && font.MeasureString(f, string(runes)+"…").Ceil() > width {
		runes = runes[:len(runes)-1]
	}
	return strings.TrimRight(string(runes), " ") + "…"
}
```

- [ ] **Step 4: Run the tests and check they pass**

Run: `go test ./internal/sharecard -count=1`
Expected: PASS.

Then check the layout by eye:
1. Add a temporary test that writes `Render(sample(), OG)` and `Render(sample(), Instagram)` to `os.TempDir()`.
2. Run it.
3. Open both PNGs with the Read tool. Look for overlapping text, the title cut off on the wrong line, and footer collisions.
4. Adjust offsets if needed.
5. Delete the temporary test.

- [ ] **Step 5: Commit**

```bash
git add internal/sharecard
git commit -m "feat(articles): render og and instagram share cards"
```

---

### Task 13: Article view models, URLs and share links

**Files:**
- Create: `norviq-web/internal/pages/articles/viewmodel.go`
- Create: `norviq-web/internal/pages/articles/share.go`
- Test: `norviq-web/internal/pages/articles/share_test.go`

**Interfaces:**
- Produces:
  - `articles.Path(slug, code string) string` returns `/articles/{slug}-{code}`
  - `articles.ParseSlugCode(segment string) (code string, ok bool)`
  - `articles.NormalizeTicker(raw string) (string, bool)`
  - `articles.BuildShareLinks(canonical, title string, tickers, bullets []string) ShareLinks`
  - View model structs: `Card`, `FeedVM`, `DetailVM`, `TickerLink`, `ShareLinks`, `ComposeVM`, `Form`
  - `articles.Disclaimer`

- [ ] **Step 1: Write the failing test**

```go
package articles

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestPathsRoundTrip(t *testing.T) {
	t.Parallel()
	assert.Equal(t, "/articles/why-2027-abcd2345", Path("why-2027", "abcd2345"))
	for segment, want := range map[string]string{
		"why-2027-abcd2345": "abcd2345",
		"abcd2345":          "abcd2345",
		"old-title-ABCD2345": "abcd2345",
	} {
		code, ok := ParseSlugCode(segment)
		assert.True(t, ok, segment)
		assert.Equal(t, want, code, segment)
	}
	for _, bad := range []string{"", "new", "why-2027", "why-abcd234i", "../etc"} {
		_, ok := ParseSlugCode(bad)
		assert.False(t, ok, bad)
	}
}

func TestNormalizeTicker(t *testing.T) {
	t.Parallel()
	got, ok := NormalizeTicker("brk.b")
	assert.True(t, ok)
	assert.Equal(t, "BRK.B", got)
	_, ok = NormalizeTicker("bad one")
	assert.False(t, ok)
	_, ok = NormalizeTicker("1ABC")
	assert.False(t, ok)
}

func TestShareLinksAreEncodedAndTagged(t *testing.T) {
	t.Parallel()
	links := BuildShareLinks("https://www.norviq.org/articles/why-abcd2345", "Why NEXT & co", []string{"NEXT"}, []string{"First point here"})
	assert.Equal(t,
		"https://x.com/intent/post?text=Why+NEXT+%26+co+%24NEXT&url=https%3A%2F%2Fwww.norviq.org%2Farticles%2Fwhy-abcd2345%3Futm_source%3Dx%26utm_medium%3Dshare",
		links.X)
	assert.Equal(t,
		"https://www.linkedin.com/sharing/share-offsite/?url=https%3A%2F%2Fwww.norviq.org%2Farticles%2Fwhy-abcd2345%3Futm_source%3Dlinkedin%26utm_medium%3Dshare",
		links.LinkedIn)
	assert.Equal(t, "**Why NEXT & co**\n• First point here\nhttps://www.norviq.org/articles/why-abcd2345?utm_source=discord&utm_medium=share", links.DiscordText)
	assert.Contains(t, links.InstagramCaption, "$NEXT")
	assert.Contains(t, links.InstagramCaption, Disclaimer)
	assert.Equal(t, "https://www.norviq.org/articles/why-abcd2345?utm_source=copy&utm_medium=share", links.Copy)
}
```

- [ ] **Step 2: Run the test and check it fails**

Run: `go test ./internal/pages/articles -count=1`
Expected: FAIL with "undefined: Path".

- [ ] **Step 3: Write `viewmodel.go`**

```go
package articles

const Disclaimer = "User-generated opinion. Not investment advice."

// Card is one feed row.
type Card struct {
	URL         string
	Title       string
	Tickers     []string
	FirstBullet string
	Byline      string
	Upvotes     int
	Views       int
}

type FeedVM struct {
	Heading         string
	Subheading      string
	CanonicalURL    string
	MetaDescription string
	Cards           []Card
	NextURL         string
	Notice          string
}

type TickerLink struct {
	Symbol   string
	FeedURL  string
	StockURL string // empty when the ticker has no public /s/ page
}

type ShareLinks struct {
	X                string
	LinkedIn         string
	Copy             string
	DiscordText      string
	InstagramCaption string
}

type DetailVM struct {
	Code            string
	Title           string
	CanonicalURL    string
	MetaDescription string
	OGImageURL      string
	CardImageURL    string
	CoverURL        string
	ViewURL         string
	LoginURL        string
	Tickers         []TickerLink
	Bullets         []string
	BodyHTML        string
	Disclosure      string
	Author          string
	AuthorURL       string
	PublishedISO    string
	ModifiedISO     string
	PublishedLabel  string
	Edited          bool
	ReadingMinutes  int
	Views           int
	Upvotes         int
	ViewerUpvoted   bool
	ViewerIsAuthor  bool
	SignedIn        bool
	IsAdmin         bool
	Hidden          bool
	Indexable       bool
	Share           ShareLinks
	More            []Card
	JSONLD          string
	Notice          string
}

type Form struct {
	Title        string
	Tickers      string
	Bullets      [3]string
	Body         string
	Disclosure   string
	CoverImageID string
}

type ComposeVM struct {
	Heading string
	Action  string
	Submit  string
	Form    Form
	Preview string
	Error   string
	Blocked bool
}
```

- [ ] **Step 4: Write `share.go`**

```go
package articles

import (
	"net/url"
	"regexp"
	"strings"
)

var (
	codePattern   = regexp.MustCompile(`^[abcdefghjkmnpqrstuvwxyz23456789]{8}$`)
	tickerPattern = regexp.MustCompile(`^[A-Z][A-Z0-9.\-]{0,9}$`)
)

// Path is an article's canonical path.
func Path(slug, code string) string {
	return "/articles/" + slug + "-" + code
}

// ParseSlugCode takes the last path segment of an article URL, either
// "{slug}-{code}" or a bare code, and returns the code.
func ParseSlugCode(segment string) (string, bool) {
	segment = strings.ToLower(segment)
	code := segment
	if i := strings.LastIndex(segment, "-"); i >= 0 {
		code = segment[i+1:]
	}
	if !codePattern.MatchString(code) {
		return "", false
	}
	return code, true
}

func NormalizeTicker(raw string) (string, bool) {
	t := strings.ToUpper(strings.TrimPrefix(strings.TrimSpace(raw), "$"))
	return t, tickerPattern.MatchString(t)
}

// BuildShareLinks builds every share target for an article. Each network gets
// its own utm_source so marketing can tell them apart.
func BuildShareLinks(canonical, title string, tickers, bullets []string) ShareLinks {
	tagged := func(source string) string {
		return canonical + "?utm_source=" + source + "&utm_medium=share"
	}
	var cashtags strings.Builder
	for _, t := range tickers {
		cashtags.WriteString(" $" + t)
	}
	var discord strings.Builder
	discord.WriteString("**" + title + "**\n")
	for _, b := range bullets {
		discord.WriteString("• " + b + "\n")
	}
	discord.WriteString(tagged("discord"))

	return ShareLinks{
		X:                "https://x.com/intent/post?text=" + url.QueryEscape(title+cashtags.String()) + "&url=" + url.QueryEscape(tagged("x")),
		LinkedIn:         "https://www.linkedin.com/sharing/share-offsite/?url=" + url.QueryEscape(tagged("linkedin")),
		Copy:             tagged("copy"),
		DiscordText:      discord.String(),
		InstagramCaption: title + "\n\n" + strings.TrimSpace(cashtags.String()) + "\n\nRead it on Norviq (link in bio).\n" + Disclaimer,
	}
}
```

- [ ] **Step 5: Run the tests and check they pass**

Run: `go test ./internal/pages/articles -count=1`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/pages/articles/viewmodel.go internal/pages/articles/share.go internal/pages/articles/share_test.go
git commit -m "feat(articles): article URLs, view models and share links"
```

---

### Task 14: Public pages — feed, ticker/author feeds, detail, short link, images, view beacon

**Files:**
- Create: `norviq-web/internal/pages/articles/articles.templ`. Run `templ generate` to produce `articles_templ.go`.
- Create: `norviq-web/internal/handlers/articles.go`
- Create: `norviq-web/internal/server/assets/article-share.js`
- Modify: `norviq-web/internal/server/assets/scripts.js`. Import and call `initArticleShare`, following how the other `init*` functions are called there.
- Test: `norviq-web/internal/handlers/articles_test.go`

**Interfaces:**
- Consumes:
  - Task 9 client
  - `markdown.Render` (Task 10)
  - `sharecard` (Task 12)
  - `articles.*` (Task 13)
  - `publicPageCache`, `stripPerVisitorHeaders`, `templates.PublicLayout`, `templates.DefaultPublicAssets`, `csrf.WithToken`
  - `publicsymbols.Allowed`, `session.AccessToken`, `middleware.BearerEditor`, `components.NorviqFullLogo`, `components.CSRFField`
- Produces:
  - `NewArticlesHandler(deps *Deps, app *AppHandler) *ArticlesHandler`
  - `(*ArticlesHandler).MountPublic(r chi.Router)` and `(*ArticlesHandler).MountSignedIn(r chi.Router)` (Task 15 fills the second)
  - `(*ArticlesHandler).SitemapPaths(ctx) []string` (used by Task 16)

- [ ] **Step 1: Write the failing tests**

```go
package handlers

import (
	"bytes"
	"context"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"testing"

	"github.com/FinancePlanner/StockPlanWeb/internal/api"
	"github.com/FinancePlanner/StockPlanWeb/internal/config"
	"github.com/FinancePlanner/StockPlanWeb/internal/session"
	"github.com/alexedwards/scs/v2"
	"github.com/go-chi/chi/v5"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const articleDetailJSON = `{"article":{"id":"5b0c7d2e-3f9a-4a51-8d33-9b6e2f1c4a10","code":"abcd2345","slug":"why-2027","title":"Why 2027 could reprice NEXT & co","bulletPoints":["First LNG from Train 1 is targeted for 1H 2027."],"tickers":["NEXT"],"author":{"id":"a1","username":"ana","avatarURL":null},"coverImageId":null,"upvoteCount":6,"viewCount":1715,"wordCount":589,"status":"published","source":"web","publishedAt":"2026-10-01T04:41:27Z","editedAt":null},"bodyMarkdown":"Revenue **visibility** is long. $NEXT <script>alert(1)</script>","disclosure":"I hold a position in $NEXT.","viewerUpvoted":false,"viewerIsAuthor":false}`

const articleSummaryJSON = `{"id":"5b0c7d2e-3f9a-4a51-8d33-9b6e2f1c4a10","code":"abcd2345","slug":"why-2027","title":"Why 2027 could reprice NEXT & co","bulletPoints":["First LNG from Train 1 is targeted for 1H 2027."],"tickers":["NEXT"],"author":{"id":"a1","username":"ana","avatarURL":null},"coverImageId":null,"upvoteCount":6,"viewCount":1715,"wordCount":589,"status":"published","source":"web","publishedAt":"2026-10-01T04:41:27Z","editedAt":null}`

type articlesBackend struct {
	mu      sync.Mutex
	calls   []string
	auth    map[string]string
	headers map[string]http.Header
	bodies  map[string]string
}

func newArticlesBackend(t *testing.T) (*api.Service, *articlesBackend) {
	t.Helper()
	b := &articlesBackend{auth: map[string]string{}, headers: map[string]http.Header{}, bodies: map[string]string{}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		key := r.Method + " " + r.URL.Path
		b.mu.Lock()
		b.calls = append(b.calls, r.Method+" "+r.URL.RequestURI())
		b.auth[key] = r.Header.Get("Authorization")
		b.headers[key] = r.Header.Clone()
		b.bodies[key] = string(raw)
		b.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		switch {
		case key == "GET /v1/articles/abcd2345":
			_, _ = w.Write([]byte(articleDetailJSON))
		case key == "GET /v1/articles":
			_, _ = w.Write([]byte(`{"items":[` + articleSummaryJSON + `],"nextCursor":null}`))
		case key == "POST /v1/articles/abcd2345/view":
			w.WriteHeader(http.StatusNoContent)
		case key == "POST /v1/articles/abcd2345/vote":
			_, _ = w.Write([]byte(`{"upvoteCount":7,"voted":true}`))
		case key == "POST /v1/articles":
			_, _ = w.Write([]byte(articleDetailJSON))
		case key == "GET /v1/community/me":
			_, _ = w.Write([]byte(`{"isAdmin":false,"guidelinesAccepted":true,"hasUsername":true,"activeSanction":null}`))
		default:
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":true,"code":"not_found","reason":"Not found"}`))
		}
	}))
	t.Cleanup(srv.Close)
	svc, err := api.NewService(srv.URL)
	require.NoError(t, err)
	return svc, b
}

func (b *articlesBackend) count(call string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := 0
	for _, c := range b.calls {
		if c == call {
			n++
		}
	}
	return n
}

func (b *articlesBackend) authFor(key string) string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.auth[key]
}

func articlesRouter(t *testing.T, svc *api.Service) http.Handler {
	t.Helper()
	sm := scs.New()
	deps := &Deps{API: svc, Session: sm, Config: &config.Config{PublicAPIToken: "public-token", PublicBaseURL: "https://www.norviq.org"}}
	h := NewArticlesHandler(deps, NewAppHandler(deps))
	r := chi.NewRouter()
	r.Get("/test/login", func(w http.ResponseWriter, r *http.Request) {
		sm.Put(r.Context(), session.KeyAccessToken, "user-token")
		w.WriteHeader(http.StatusNoContent)
	})
	h.MountPublic(r)
	h.MountSignedIn(r)
	return sm.LoadAndSave(r)
}

// signedInCookie logs the test session in and returns its cookie.
func signedInCookie(t *testing.T, h http.Handler) *http.Cookie {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/test/login", nil))
	cookies := rec.Result().Cookies()
	require.NotEmpty(t, cookies)
	return cookies[0]
}

func serveArticles(t *testing.T, h http.Handler, method, target string, form url.Values, cookie *http.Cookie) *httptest.ResponseRecorder {
	t.Helper()
	var body io.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	}
	req := httptest.NewRequestWithContext(context.Background(), method, target, body)
	req.RemoteAddr = "203.0.113.7:51234"
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	if cookie != nil {
		req.AddCookie(cookie)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestDetailAnonymousIsCachedAndCookieless(t *testing.T) {
	t.Parallel()
	svc, backend := newArticlesBackend(t)
	h := articlesRouter(t, svc)

	rec := serveArticles(t, h, http.MethodGet, "/articles/why-2027-abcd2345", nil, nil)
	require.Equal(t, http.StatusOK, rec.Code)
	assert.Equal(t, "public, max-age=900", rec.Header().Get("Cache-Control"))
	assert.Empty(t, rec.Header().Values("Set-Cookie"))
	html := rec.Body.String()
	assert.Contains(t, html, "Why 2027 could reprice NEXT &amp; co")
	assert.Contains(t, html, `<meta property="og:type" content="article">`)
	assert.Contains(t, html, `content="https://www.norviq.org/articles/abcd2345/og.png"`)
	assert.Contains(t, html, `<meta property="article:tag" content="NEXT">`)
	assert.Contains(t, html, `application/ld+json`)
	assert.Contains(t, html, `"wordCount":589`)
	assert.Contains(t, html, "Not investment advice")
	assert.Contains(t, html, "I hold a position in $NEXT.")
	assert.Contains(t, html, `href="/articles/ticker/NEXT"`)
	assert.Contains(t, html, "x.com/intent/post?text=")
	assert.Contains(t, html, `data-article-view="/articles/abcd2345/view"`)
	assert.NotContains(t, html, "<script>alert(1)</script>")
	assert.NotContains(t, html, `hx-post="/articles/abcd2345/vote"`, "anonymous visitors get a sign-in link, not a live vote")
	assert.Equal(t, "Bearer public-token", backend.authFor("GET /v1/articles/abcd2345"))

	again := serveArticles(t, h, http.MethodGet, "/articles/why-2027-abcd2345", nil, nil)
	require.Equal(t, http.StatusOK, again.Code)
	assert.Equal(t, 1, backend.count("GET /v1/articles/abcd2345"), "the second anonymous view is served from cache")
}

func TestDetailSignedInIsPersonalAndUncached(t *testing.T) {
	t.Parallel()
	svc, backend := newArticlesBackend(t)
	h := articlesRouter(t, svc)
	cookie := signedInCookie(t, h)

	rec := serveArticles(t, h, http.MethodGet, "/articles/why-2027-abcd2345", nil, cookie)
	require.Equal(t, http.StatusOK, rec.Code)
	assert.Equal(t, "private, no-store", rec.Header().Get("Cache-Control"))
	assert.Contains(t, rec.Body.String(), `hx-post="/articles/abcd2345/vote"`)
	assert.Equal(t, "Bearer user-token", backend.authFor("GET /v1/articles/abcd2345"))
}

func TestDetailRedirectsToCanonicalSlug(t *testing.T) {
	t.Parallel()
	svc, _ := newArticlesBackend(t)
	h := articlesRouter(t, svc)
	for _, target := range []string{"/articles/old-title-abcd2345", "/articles/abcd2345", "/a/abcd2345"} {
		rec := serveArticles(t, h, http.MethodGet, target, nil, nil)
		assert.Equal(t, http.StatusMovedPermanently, rec.Code, target)
		assert.Equal(t, "/articles/why-2027-abcd2345", rec.Header().Get("Location"), target)
	}
}

func TestHiddenArticle404sPublicly(t *testing.T) {
	t.Parallel()
	svc, _ := newArticlesBackend(t)
	h := articlesRouter(t, svc)
	assert.Equal(t, http.StatusNotFound, serveArticles(t, h, http.MethodGet, "/articles/gone-hhhh2345", nil, nil).Code)
	assert.Equal(t, http.StatusNotFound, serveArticles(t, h, http.MethodGet, "/articles/not-a-code", nil, nil).Code)
}

func TestFeedsFilterAndValidate(t *testing.T) {
	t.Parallel()
	svc, backend := newArticlesBackend(t)
	h := articlesRouter(t, svc)

	rec := serveArticles(t, h, http.MethodGet, "/articles/ticker/next", nil, nil)
	require.Equal(t, http.StatusOK, rec.Code)
	assert.Contains(t, rec.Body.String(), `href="/articles/why-2027-abcd2345"`)
	assert.Equal(t, 1, backend.count("GET /v1/articles?limit=20&ticker=NEXT"))

	assert.Equal(t, http.StatusNotFound, serveArticles(t, h, http.MethodGet, "/articles/ticker/bad%20one", nil, nil).Code)

	author := serveArticles(t, h, http.MethodGet, "/u/ana/articles", nil, nil)
	require.Equal(t, http.StatusOK, author.Code)
	assert.Equal(t, 1, backend.count("GET /v1/articles?author=ana&limit=20"))

	all := serveArticles(t, h, http.MethodGet, "/articles", nil, nil)
	require.Equal(t, http.StatusOK, all.Code)
	assert.Contains(t, all.Body.String(), "First LNG from Train 1")
}

func TestShareImagesHaveTheRightSize(t *testing.T) {
	t.Parallel()
	svc, _ := newArticlesBackend(t)
	h := articlesRouter(t, svc)
	for target, size := range map[string][2]int{
		"/articles/abcd2345/og.png":   {1200, 630},
		"/articles/abcd2345/card.png": {1080, 1350},
	} {
		rec := serveArticles(t, h, http.MethodGet, target, nil, nil)
		require.Equal(t, http.StatusOK, rec.Code, target)
		assert.Equal(t, "image/png", rec.Header().Get("Content-Type"))
		cfg, err := png.DecodeConfig(bytes.NewReader(rec.Body.Bytes()))
		require.NoError(t, err)
		assert.Equal(t, size, [2]int{cfg.Width, cfg.Height}, target)
	}
}

func TestViewBeaconForwardsHashedVisitor(t *testing.T) {
	t.Parallel()
	svc, backend := newArticlesBackend(t)
	h := articlesRouter(t, svc)
	rec := serveArticles(t, h, http.MethodPost, "/articles/abcd2345/view", nil, nil)
	assert.Equal(t, http.StatusNoContent, rec.Code)
	backend.mu.Lock()
	viewer := backend.headers["POST /v1/articles/abcd2345/view"].Get("X-Norviq-Viewer")
	backend.mu.Unlock()
	assert.Regexp(t, regexp.MustCompile(`^[0-9a-f]{32}$`), viewer)
	assert.NotContains(t, viewer, "203.0.113.7")
	assert.Equal(t, "Bearer public-token", backend.authFor("POST /v1/articles/abcd2345/view"))
}
```

> The exact query-string order in `count(...)` follows `url.Values.Encode()`, which sorts keys. That gives
> `author=…&limit=20` and `limit=20&ticker=…`.

- [ ] **Step 2: Run the tests and check they fail**

Run: `go test ./internal/handlers -run 'Article|Detail|Feed|Share|View|Hidden' -count=1`
Expected: FAIL with "undefined: NewArticlesHandler".

- [ ] **Step 3: Write the templates (`internal/pages/articles/articles.templ`)**

```templ
package articles

import (
	"strconv"

	"github.com/FinancePlanner/StockPlanWeb/internal/pages/components"
)

func voteVals(on bool) string {
	return `{"on":"` + strconv.FormatBool(on) + `"}`
}

templ header() {
	<header class="mb-10 flex items-center justify-between gap-4">
		<a href="/" class="landing-brand-link" aria-label="Norviq home">
			@components.NorviqFullLogo()
		</a>
		<nav class="flex items-center gap-4 text-sm">
			<a href="/articles" class="hover:underline">Articles</a>
			<a href="/articles/new" class="rounded-lg border border-border px-3 py-1.5 font-medium hover:bg-muted">Write</a>
		</nav>
	</header>
}

templ footer() {
	<footer class="mt-16 border-t border-border pt-6 text-xs text-muted-foreground">
		<p>{ Disclaimer } Norviq doesn't review articles before they go live. <a href="/terms" class="underline">Terms</a></p>
	</footer>
}

templ card(c Card) {
	<li class="rounded-xl border border-border p-5">
		<div class="flex flex-wrap gap-2 text-sm font-medium text-[var(--color-accent)]">
			for _, t := range c.Tickers {
				<a href={ templ.SafeURL("/articles/ticker/" + t) } class="hover:underline">{ "$" + t }</a>
			}
		</div>
		<h2 class="mt-2 text-xl font-semibold leading-snug"><a href={ templ.SafeURL(c.URL) } class="hover:underline">{ c.Title }</a></h2>
		if c.FirstBullet != "" {
			<p class="mt-2 text-muted-foreground">{ c.FirstBullet }</p>
		}
		<p class="mt-3 text-sm text-muted-foreground">
			{ c.Byline } · ▲ { strconv.Itoa(c.Upvotes) } · { strconv.Itoa(c.Views) } views
		</p>
	</li>
}

templ FeedMeta(vm FeedVM, ogImage string) {
	<meta name="description" content={ vm.MetaDescription }/>
	<meta name="robots" content="index,follow,max-image-preview:large"/>
	<link rel="canonical" href={ vm.CanonicalURL }/>
	<meta property="og:type" content="website"/>
	<meta property="og:site_name" content="Norviq"/>
	<meta property="og:url" content={ vm.CanonicalURL }/>
	<meta property="og:title" content={ vm.Heading }/>
	<meta property="og:description" content={ vm.MetaDescription }/>
	<meta property="og:image" content={ ogImage }/>
	<meta name="twitter:card" content="summary_large_image"/>
	<meta name="twitter:site" content="@NorviqPlanner"/>
}

templ FeedPage(vm FeedVM) {
	<main id="main-content" class="mx-auto w-full max-w-3xl px-6 py-10">
		@header()
		<h1 class="text-3xl font-semibold">{ vm.Heading }</h1>
		if vm.Subheading != "" {
			<p class="mt-2 text-muted-foreground">{ vm.Subheading }</p>
		}
		if vm.Notice != "" {
			<p role="status" class="mt-4 rounded-lg border border-border p-3 text-sm">{ vm.Notice }</p>
		}
		if len(vm.Cards) == 0 {
			<p class="mt-8 text-muted-foreground">No articles yet. <a href="/articles/new" class="underline">Write the first one.</a></p>
		} else {
			<ol class="mt-8 space-y-4">
				for _, c := range vm.Cards {
					@card(c)
				}
			</ol>
		}
		if vm.NextURL != "" {
			<a href={ templ.SafeURL(vm.NextURL) } rel="next" class="mt-6 inline-block underline">Older articles</a>
		}
		@footer()
	</main>
}

templ DetailMeta(vm DetailVM) {
	<meta name="description" content={ vm.MetaDescription }/>
	if vm.Indexable {
		<meta name="robots" content="index,follow,max-image-preview:large"/>
	} else {
		<meta name="robots" content="noindex"/>
	}
	<link rel="canonical" href={ vm.CanonicalURL }/>
	<meta property="og:type" content="article"/>
	<meta property="og:site_name" content="Norviq"/>
	<meta property="og:locale" content="en_US"/>
	<meta property="og:url" content={ vm.CanonicalURL }/>
	<meta property="og:title" content={ vm.Title }/>
	<meta property="og:description" content={ vm.MetaDescription }/>
	<meta property="og:image" content={ vm.OGImageURL }/>
	<meta property="og:image:type" content="image/png"/>
	<meta property="og:image:width" content="1200"/>
	<meta property="og:image:height" content="630"/>
	<meta property="article:published_time" content={ vm.PublishedISO }/>
	<meta property="article:modified_time" content={ vm.ModifiedISO }/>
	for _, t := range vm.Tickers {
		<meta property="article:tag" content={ t.Symbol }/>
	}
	<meta name="twitter:card" content="summary_large_image"/>
	<meta name="twitter:site" content="@NorviqPlanner"/>
	<meta name="twitter:title" content={ vm.Title }/>
	<meta name="twitter:description" content={ vm.MetaDescription }/>
	<meta name="twitter:image" content={ vm.OGImageURL }/>
	@templ.Raw(`<script type="application/ld+json">` + vm.JSONLD + `</script>`)
}

templ VoteButton(code string, count int, voted, canVote bool, loginURL string) {
	<div id={ "article-vote-" + code }>
		if canVote {
			<button
				type="button"
				class="rounded-lg border border-border px-3 py-1.5 text-sm font-medium aria-pressed:bg-muted"
				hx-post={ "/articles/" + code + "/vote" }
				hx-vals={ voteVals(!voted) }
				hx-target={ "#article-vote-" + code }
				hx-swap="outerHTML"
				aria-pressed={ strconv.FormatBool(voted) }
				aria-label="Upvote"
			>▲ { strconv.Itoa(count) }</button>
		} else {
			<a href={ templ.SafeURL(loginURL) } class="rounded-lg border border-border px-3 py-1.5 text-sm font-medium" aria-label="Sign in to upvote">▲ { strconv.Itoa(count) }</a>
		}
	</div>
}

templ ShareBar(vm DetailVM) {
	<div class="flex flex-wrap gap-2 text-sm" role="group" aria-label="Share this article">
		<a href={ templ.URL(vm.Share.X) } target="_blank" rel="noopener noreferrer" class="rounded-lg border border-border px-3 py-1.5">Share on X</a>
		<a href={ templ.URL(vm.Share.LinkedIn) } target="_blank" rel="noopener noreferrer" class="rounded-lg border border-border px-3 py-1.5">LinkedIn</a>
		<button type="button" data-share-copy={ vm.Share.DiscordText } class="rounded-lg border border-border px-3 py-1.5">Copy for Discord</button>
		<button type="button" data-share-card data-card-url={ vm.CardImageURL } data-caption={ vm.Share.InstagramCaption } class="rounded-lg border border-border px-3 py-1.5">Instagram card</button>
		<button type="button" data-share-copy={ vm.Share.Copy } class="rounded-lg border border-border px-3 py-1.5">Copy link</button>
	</div>
}

templ DetailPage(vm DetailVM) {
	<main id="main-content" class="mx-auto w-full max-w-3xl px-6 py-10" data-article-view={ vm.ViewURL }>
		@header()
		if vm.Notice != "" {
			<p role="status" class="mb-6 rounded-lg border border-border p-3 text-sm">{ vm.Notice }</p>
		}
		if vm.Hidden {
			<p role="status" class="mb-6 rounded-lg border border-[var(--color-danger)] p-3 text-sm">Hidden by a moderator. Only you and moderators can see it.</p>
		}
		<nav aria-label="Breadcrumb" class="text-sm text-muted-foreground">
			<a href="/articles" class="hover:underline">Articles</a>
			if len(vm.Tickers) > 0 {
				› <a href={ templ.SafeURL(vm.Tickers[0].FeedURL) } class="hover:underline">{ "$" + vm.Tickers[0].Symbol }</a>
			}
		</nav>
		<h1 class="mt-3 text-3xl font-semibold leading-tight">{ vm.Title }</h1>
		<p class="mt-3 text-sm text-muted-foreground">
			<a href={ templ.SafeURL(vm.AuthorURL) } class="font-medium hover:underline">{ vm.Author }</a>
			· <time datetime={ vm.PublishedISO }>{ vm.PublishedLabel }</time>
			if vm.Edited {
				· edited
			}
			· { strconv.Itoa(vm.ReadingMinutes) } min read · { strconv.Itoa(vm.Views) } views
		</p>
		<div class="mt-4 flex flex-wrap items-center gap-2">
			for _, t := range vm.Tickers {
				<a href={ templ.SafeURL(t.FeedURL) } class="rounded-full border border-border px-3 py-1 text-sm font-medium">{ "$" + t.Symbol }</a>
				if t.StockURL != "" {
					<a href={ templ.SafeURL(t.StockURL) } class="text-xs text-muted-foreground underline">{ t.Symbol } data</a>
				}
			}
		</div>
		<section class="mt-6 rounded-xl border border-border p-5" aria-labelledby="key-points">
			<h2 id="key-points" class="text-sm font-semibold uppercase tracking-wide text-muted-foreground">Key points</h2>
			<ul class="mt-3 list-disc space-y-2 pl-5">
				for _, b := range vm.Bullets {
					<li>{ b }</li>
				}
			</ul>
		</section>
		if vm.CoverURL != "" {
			<img src={ string(templ.SafeURL(vm.CoverURL)) } alt="" class="mt-6 w-full rounded-xl" loading="lazy"/>
		}
		<article class="prose mt-8 max-w-none">
			@templ.Raw(vm.BodyHTML)
		</article>
		<aside class="mt-8 rounded-xl border border-border p-4 text-sm"><strong>Disclosure:</strong> { vm.Disclosure }</aside>
		<p class="mt-3 text-xs text-muted-foreground">{ Disclaimer }</p>
		<div class="mt-6 flex flex-wrap items-center gap-3">
			@VoteButton(vm.Code, vm.Upvotes, vm.ViewerUpvoted, vm.SignedIn, vm.LoginURL)
			@ShareBar(vm)
		</div>
		if vm.SignedIn {
			<div class="mt-6 flex flex-wrap gap-3 text-sm">
				if vm.ViewerIsAuthor {
					<a href={ templ.SafeURL("/articles/" + vm.Code + "/edit") } class="underline">Edit</a>
					<form method="post" action={ templ.SafeURL("/articles/" + vm.Code + "/delete") } onsubmit="return window.confirm('Delete this article?')">
						@components.CSRFField()
						<button type="submit" class="text-[var(--color-danger)] underline">Delete</button>
					</form>
				}
				if vm.IsAdmin {
					<form method="post" action={ templ.SafeURL("/articles/" + vm.Code + "/visibility") }>
						@components.CSRFField()
						<input type="hidden" name="hidden" value={ strconv.FormatBool(!vm.Hidden) }/>
						<button type="submit" class="underline">
							if vm.Hidden {
								Unhide
							} else {
								Hide
							}
						</button>
					</form>
				}
				<details>
					<summary class="cursor-pointer underline">Report</summary>
					<form method="post" action={ templ.SafeURL("/articles/" + vm.Code + "/report") } class="mt-2 space-y-2">
						@components.CSRFField()
						<select name="reason" class="rounded border border-border p-1">
							<option value="scam">Scam or pump-and-dump</option>
							<option value="spam">Spam</option>
							<option value="harassment">Harassment</option>
							<option value="hate">Hate</option>
							<option value="impersonation">Impersonation</option>
							<option value="inappropriate">Inappropriate</option>
							<option value="other">Other</option>
						</select>
						<textarea name="note" maxlength="1000" rows="2" class="block w-full rounded border border-border p-2" placeholder="Anything we should know (optional)"></textarea>
						<button type="submit" class="rounded-lg border border-border px-3 py-1">Send report</button>
					</form>
				</details>
			</div>
		}
		if len(vm.More) > 0 && len(vm.Tickers) > 0 {
			<section class="mt-12">
				<h2 class="text-lg font-semibold">{ "More on $" + vm.Tickers[0].Symbol }</h2>
				<ol class="mt-4 space-y-4">
					for _, c := range vm.More {
						@card(c)
					}
				</ol>
			</section>
		}
		@footer()
	</main>
}
```

Run: `templ generate`. Expected: `internal/pages/articles/articles_templ.go` is generated with no errors. If templ rejects `src={ string(templ.SafeURL(...)) }`, use `src={ vm.CoverURL }`; the URL is server-built (`/articles/images/{uuid}`).

- [ ] **Step 4: Write the handler (`internal/handlers/articles.go`)**

```go
package handlers

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/FinancePlanner/StockPlanWeb/internal/api"
	"github.com/FinancePlanner/StockPlanWeb/internal/csrf"
	"github.com/FinancePlanner/StockPlanWeb/internal/markdown"
	"github.com/FinancePlanner/StockPlanWeb/internal/middleware"
	"github.com/FinancePlanner/StockPlanWeb/internal/pages/articles"
	"github.com/FinancePlanner/StockPlanWeb/internal/publicsymbols"
	"github.com/FinancePlanner/StockPlanWeb/internal/session"
	"github.com/FinancePlanner/StockPlanWeb/internal/sharecard"
	"github.com/FinancePlanner/StockPlanWeb/templates"
	"github.com/go-chi/chi/v5"
)

// Articles: user-written stock write-ups. Read pages are public and crawlable
// like /s/{symbol}; the backend enforces every rule on writes.

var (
	errArticleNotFound = errors.New("article not found")
	usernamePattern    = regexp.MustCompile(`^[A-Za-z0-9_]{1,32}$`)
	uuidPattern        = regexp.MustCompile(`^[0-9a-fA-F-]{36}$`)
	cursorPattern      = regexp.MustCompile(`^\d{1,16}_[0-9A-Fa-f-]{36}$`)
)

// articleRedirect is returned from a cached render when the URL's slug isn't
// the canonical one. Errors are never cached, so neither is the redirect.
type articleRedirect struct{ to string }

func (r articleRedirect) Error() string { return "redirect to " + r.to }

type ArticlesHandler struct {
	deps  *Deps
	app   *AppHandler
	pages *publicPageCache
	cards *publicPageCache
}

func NewArticlesHandler(deps *Deps, app *AppHandler) *ArticlesHandler {
	return &ArticlesHandler{deps: deps, app: app, pages: newPublicPageCache(), cards: newPublicPageCache()}
}

// MountPublic registers the crawlable routes. server.go wraps them in the
// articles gate.
func (h *ArticlesHandler) MountPublic(r chi.Router) {
	r.Get("/articles", h.Feed)
	r.Get("/articles/ticker/{symbol}", h.TickerFeed)
	r.Get("/articles/images/{id}", h.Image)
	r.Get("/articles/{code}/og.png", h.OGImage)
	r.Get("/articles/{code}/card.png", h.CardImage)
	r.Post("/articles/{code}/view", h.View)
	r.Get("/articles/{slugcode}", h.Detail)
	r.Get("/a/{code}", h.ShortLink)
	r.Get("/u/{username}/articles", h.AuthorFeed)
}

func (h *ArticlesHandler) signedIn(r *http.Request) bool {
	return h.deps.Session != nil && session.AccessToken(h.deps.Session, r) != ""
}

func (h *ArticlesHandler) publicEditor() api.RequestEditorFn {
	return api.WithBearerToken(h.deps.Config.PublicAPIToken)
}

// reader uses the visitor's own token when signed in, so "you upvoted" and
// "you wrote this" are right; the public token otherwise.
func (h *ArticlesHandler) reader(r *http.Request) api.RequestEditorFn {
	if h.signedIn(r) {
		return middleware.BearerEditor(h.deps.Session, r)
	}
	return h.publicEditor()
}

func (h *ArticlesHandler) base() string {
	return strings.TrimRight(h.deps.Config.PublicBaseURL, "/")
}

func (h *ArticlesHandler) fetch(ctx context.Context, code string, editor api.RequestEditorFn) (*api.ArticleDetail, error) {
	detail, err := h.deps.API.GetArticle(ctx, code, editor)
	if api.IsBoardsNotFound(err) {
		return nil, errArticleNotFound
	}
	return detail, err
}

// MARK: - Detail

func (h *ArticlesHandler) Detail(w http.ResponseWriter, r *http.Request) {
	segment := chi.URLParam(r, "slugcode")
	code, ok := articles.ParseSlugCode(segment)
	if !ok {
		http.NotFound(w, r)
		return
	}

	if h.signedIn(r) {
		detail, err := h.fetch(r.Context(), code, h.reader(r))
		if h.detailFailed(w, r, err) {
			return
		}
		if canonical := articles.Path(detail.Article.Slug, detail.Article.Code); "/articles/"+segment != canonical {
			http.Redirect(w, r, canonical, http.StatusMovedPermanently)
			return
		}
		vm := h.detailVM(r.Context(), detail, true)
		vm.IsAdmin = h.viewerIsAdmin(r)
		vm.Notice = articleNotices[r.URL.Query().Get("notice")]
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "private, no-store")
		page := templates.PublicLayout(vm.Title+" — Norviq", templates.DefaultPublicAssets(), articles.DetailMeta(vm), articles.DetailPage(vm))
		if err := page.Render(r.Context(), w); err != nil {
			slog.Error("render article", "code", code, "error", err)
		}
		return
	}

	// Anonymous: one cached render per canonical URL, shared by every visitor.
	html, err := h.pages.Do("detail:"+segment, func() ([]byte, error) {
		ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), publicRenderTimeout)
		defer cancel()
		detail, err := h.fetch(ctx, code, h.publicEditor())
		if err != nil {
			return nil, err
		}
		if canonical := articles.Path(detail.Article.Slug, detail.Article.Code); "/articles/"+segment != canonical {
			return nil, articleRedirect{to: canonical}
		}
		vm := h.detailVM(ctx, detail, false)
		page := templates.PublicLayout(vm.Title+" — Norviq", templates.DefaultPublicAssets(), articles.DetailMeta(vm), articles.DetailPage(vm))
		var buf bytes.Buffer
		// Bare context: this HTML is shared, so it must not carry the first
		// visitor's CSRF token (see PublicStockHandler.render).
		if err := page.Render(csrf.WithToken(context.Background(), ""), &buf); err != nil {
			return nil, err
		}
		return buf.Bytes(), nil
	})
	if h.detailFailed(w, r, err) {
		return
	}
	stripPerVisitorHeaders(w.Header())
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=900")
	_, _ = w.Write(html)
}

// detailFailed writes the response for a failed detail load and reports
// whether it did.
func (h *ArticlesHandler) detailFailed(w http.ResponseWriter, r *http.Request, err error) bool {
	var redirect articleRedirect
	switch {
	case err == nil:
		return false
	case errors.As(err, &redirect):
		http.Redirect(w, r, redirect.to, http.StatusMovedPermanently)
	case errors.Is(err, errArticleNotFound):
		http.NotFound(w, r)
	default:
		slog.Error("load article", "path", r.URL.Path, "error", err)
		http.Error(w, "Articles are temporarily unavailable", http.StatusBadGateway)
	}
	return true
}

func (h *ArticlesHandler) viewerIsAdmin(r *http.Request) bool {
	status, err := h.deps.API.CommunityViewer(r.Context(), middleware.BearerEditor(h.deps.Session, r))
	return err == nil && status.IsAdmin
}

var articleNotices = map[string]string{
	"published": "Published. Share it below.",
	"updated":   "Saved.",
	"reported":  "Thanks. A person will review the report.",
	"hidden":    "Hidden from everyone but the author.",
	"unhidden":  "Visible again.",
	"deleted":   "Deleted.",
}

func (h *ArticlesHandler) detailVM(ctx context.Context, d *api.ArticleDetail, personal bool) articles.DetailVM {
	a := d.Article
	path := articles.Path(a.Slug, a.Code)
	canonical := h.base() + path
	author := "Unknown"
	authorURL := "/articles"
	if a.Author.Username != nil {
		author = "@" + *a.Author.Username
		authorURL = "/u/" + url.PathEscape(*a.Author.Username) + "/articles"
	}
	modified := a.PublishedAt
	if a.EditedAt != nil {
		modified = *a.EditedAt
	}
	tickers := make([]articles.TickerLink, 0, len(a.Tickers))
	for _, t := range a.Tickers {
		link := articles.TickerLink{Symbol: t, FeedURL: "/articles/ticker/" + url.PathEscape(t)}
		if publicsymbols.Allowed(t) {
			link.StockURL = "/s/" + url.PathEscape(t)
		}
		tickers = append(tickers, link)
	}
	description := a.Title
	if len(a.BulletPoints) > 0 {
		description = a.BulletPoints[0]
	}
	minutes := a.WordCount / 220
	if minutes < 1 {
		minutes = 1
	}
	vm := articles.DetailVM{
		Code:            a.Code,
		Title:           a.Title,
		CanonicalURL:    canonical,
		MetaDescription: description,
		OGImageURL:      h.base() + "/articles/" + a.Code + "/og.png",
		CardImageURL:    "/articles/" + a.Code + "/card.png",
		ViewURL:         "/articles/" + a.Code + "/view",
		LoginURL:        "/login?next=" + url.QueryEscape(path),
		Tickers:         tickers,
		Bullets:         a.BulletPoints,
		BodyHTML:        markdown.Render(d.BodyMarkdown),
		Disclosure:      d.Disclosure,
		Author:          author,
		AuthorURL:       authorURL,
		PublishedISO:    a.PublishedAt.UTC().Format(time.RFC3339),
		ModifiedISO:     modified.UTC().Format(time.RFC3339),
		PublishedLabel:  a.PublishedAt.UTC().Format("Jan 2, 2006"),
		Edited:          a.EditedAt != nil,
		ReadingMinutes:  minutes,
		Views:           a.ViewCount,
		Upvotes:         a.UpvoteCount,
		ViewerUpvoted:   personal && d.ViewerUpvoted,
		ViewerIsAuthor:  personal && d.ViewerIsAuthor,
		SignedIn:        personal,
		Hidden:          a.Status == "hidden",
		Indexable:       a.Status == "published",
		Share:           articles.BuildShareLinks(canonical, a.Title, a.Tickers, a.BulletPoints),
	}
	if a.CoverImageID != nil {
		vm.CoverURL = "/articles/images/" + url.PathEscape(*a.CoverImageID)
	}
	vm.JSONLD = articleJSONLD(vm, a)
	if len(a.Tickers) > 0 {
		if page, err := h.deps.API.ListArticles(ctx, api.ArticleListQuery{Ticker: a.Tickers[0], Limit: 4}, h.publicEditor()); err == nil {
			for _, s := range page.Items {
				if s.Code != a.Code && len(vm.More) < 3 {
					vm.More = append(vm.More, articleCard(s))
				}
			}
		}
	}
	return vm
}

func articleJSONLD(vm articles.DetailVM, a api.ArticleSummary) string {
	data := map[string]any{
		"@context":         "https://schema.org",
		"@type":            "Article",
		"headline":         a.Title,
		"description":      vm.MetaDescription,
		"url":              vm.CanonicalURL,
		"mainEntityOfPage": vm.CanonicalURL,
		"image":            vm.OGImageURL,
		"datePublished":    vm.PublishedISO,
		"dateModified":     vm.ModifiedISO,
		"wordCount":        a.WordCount,
		"keywords":         a.Tickers,
		"author":           map[string]any{"@type": "Person", "name": vm.Author},
		"publisher":        map[string]any{"@type": "Organization", "name": "Norviq"},
	}
	// json.Marshal escapes <, > and &, so the result is safe inside <script>.
	out, err := json.Marshal(data)
	if err != nil {
		return "{}"
	}
	return string(out)
}

func articleCard(s api.ArticleSummary) articles.Card {
	byline := "Unknown"
	if s.Author.Username != nil {
		byline = "@" + *s.Author.Username
	}
	byline += " · " + s.PublishedAt.UTC().Format("Jan 2, 2006")
	first := ""
	if len(s.BulletPoints) > 0 {
		first = s.BulletPoints[0]
	}
	return articles.Card{
		URL: articles.Path(s.Slug, s.Code), Title: s.Title, Tickers: s.Tickers,
		FirstBullet: first, Byline: byline, Upvotes: s.UpvoteCount, Views: s.ViewCount,
	}
}

// MARK: - Feeds

// Feeds are not held in the page cache: their keys (cursor, ticker) are
// visitor-controlled, and the cache never evicts. A short CDN max-age instead.
func (h *ArticlesHandler) serveFeed(w http.ResponseWriter, r *http.Request, q api.ArticleListQuery, vm articles.FeedVM, basePath string) {
	if cursor := r.URL.Query().Get("cursor"); cursorPattern.MatchString(cursor) {
		q.Cursor = cursor
	}
	q.Limit = 20
	page, err := h.deps.API.ListArticles(r.Context(), q, h.publicEditor())
	if err != nil {
		slog.Error("list articles", "path", r.URL.Path, "error", err)
		http.Error(w, "Articles are temporarily unavailable", http.StatusBadGateway)
		return
	}
	for _, s := range page.Items {
		vm.Cards = append(vm.Cards, articleCard(s))
	}
	if page.NextCursor != nil {
		vm.NextURL = basePath + "?cursor=" + url.QueryEscape(*page.NextCursor)
	}
	vm.CanonicalURL = h.base() + basePath
	vm.Notice = articleNotices[r.URL.Query().Get("notice")]
	var buf bytes.Buffer
	page2 := templates.PublicLayout(vm.Heading+" — Norviq", templates.DefaultPublicAssets(),
		articles.FeedMeta(vm, h.base()+"/static/images/og.png"), articles.FeedPage(vm))
	if err := page2.Render(csrf.WithToken(context.Background(), ""), &buf); err != nil {
		slog.Error("render article feed", "error", err)
		http.Error(w, "Failed to render page", http.StatusInternalServerError)
		return
	}
	stripPerVisitorHeaders(w.Header())
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "public, max-age=120")
	_, _ = w.Write(buf.Bytes())
}

func (h *ArticlesHandler) Feed(w http.ResponseWriter, r *http.Request) {
	h.serveFeed(w, r, api.ArticleListQuery{}, articles.FeedVM{
		Heading:         "Stock articles",
		Subheading:      "Theses and deep dives written by Norviq investors.",
		MetaDescription: "Stock theses and deep dives written by Norviq investors.",
	}, "/articles")
}

func (h *ArticlesHandler) TickerFeed(w http.ResponseWriter, r *http.Request) {
	ticker, ok := articles.NormalizeTicker(chi.URLParam(r, "symbol"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	h.serveFeed(w, r, api.ArticleListQuery{Ticker: ticker}, articles.FeedVM{
		Heading:         "$" + ticker + " articles",
		MetaDescription: "Investor articles and theses on $" + ticker + ".",
	}, "/articles/ticker/"+ticker)
}

func (h *ArticlesHandler) AuthorFeed(w http.ResponseWriter, r *http.Request) {
	username := chi.URLParam(r, "username")
	if !usernamePattern.MatchString(username) {
		http.NotFound(w, r)
		return
	}
	h.serveFeed(w, r, api.ArticleListQuery{Author: username}, articles.FeedVM{
		Heading:         "Articles by @" + username,
		MetaDescription: "Stock articles written by @" + username + " on Norviq.",
	}, "/u/"+username+"/articles")
}

// MARK: - Short link, images, view beacon

func (h *ArticlesHandler) ShortLink(w http.ResponseWriter, r *http.Request) {
	code, ok := articles.ParseSlugCode(chi.URLParam(r, "code"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	detail, err := h.fetch(r.Context(), code, h.publicEditor())
	if h.detailFailed(w, r, err) {
		return
	}
	http.Redirect(w, r, articles.Path(detail.Article.Slug, detail.Article.Code), http.StatusMovedPermanently)
}

func (h *ArticlesHandler) OGImage(w http.ResponseWriter, r *http.Request) {
	h.serveCard(w, r, "og", sharecard.OG)
}

func (h *ArticlesHandler) CardImage(w http.ResponseWriter, r *http.Request) {
	h.serveCard(w, r, "card", sharecard.Instagram)
}

func (h *ArticlesHandler) serveCard(w http.ResponseWriter, r *http.Request, kind string, format sharecard.Format) {
	code, ok := articles.ParseSlugCode(chi.URLParam(r, "code"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	png, err := h.cards.Do(kind+":"+code, func() ([]byte, error) {
		ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), publicRenderTimeout)
		defer cancel()
		detail, err := h.fetch(ctx, code, h.publicEditor())
		if err != nil {
			return nil, err
		}
		a := detail.Article
		author := ""
		if a.Author.Username != nil {
			author = "@" + *a.Author.Username
		}
		short := strings.TrimPrefix(strings.TrimPrefix(h.base(), "https://"), "www.") + "/a/" + a.Code
		return sharecard.Render(sharecard.Card{
			Title: a.Title, Tickers: a.Tickers, Bullets: a.BulletPoints, Author: author,
			Date: a.PublishedAt.UTC().Format("Jan 2, 2006"), ShortURL: short,
		}, format)
	})
	if h.detailFailed(w, r, err) {
		return
	}
	stripPerVisitorHeaders(w.Header())
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	_, _ = w.Write(png)
}

func (h *ArticlesHandler) Image(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if !uuidPattern.MatchString(id) {
		http.NotFound(w, r)
		return
	}
	data, contentType, err := h.deps.API.FetchArticleImage(r.Context(), id, h.publicEditor())
	if err != nil {
		if api.IsBoardsNotFound(err) {
			http.NotFound(w, r)
			return
		}
		slog.Error("fetch article image", "id", id, "error", err)
		http.Error(w, "Image unavailable", http.StatusBadGateway)
		return
	}
	switch contentType {
	case "image/png", "image/jpeg", "image/webp":
	default:
		http.NotFound(w, r)
		return
	}
	stripPerVisitorHeaders(w.Header())
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	_, _ = w.Write(data)
}

// View counts a read. It's a beacon because anonymous pages are cached; the
// visitor key is a daily-salted hash, never the raw IP.
func (h *ArticlesHandler) View(w http.ResponseWriter, r *http.Request) {
	code, ok := articles.ParseSlugCode(chi.URLParam(r, "code"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	if err := h.deps.API.RecordArticleView(ctx, code, h.visitorKey(r), h.reader(r)); err != nil && !api.IsBoardsNotFound(err) {
		slog.Debug("record article view failed", "code", code, "error", err)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *ArticlesHandler) visitorKey(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	sum := sha256.Sum256([]byte(host + "|" + time.Now().UTC().Format("2006-01-02") + "|" + h.deps.Config.PublicAPIToken))
	return hex.EncodeToString(sum[:16])
}

// MARK: - Sitemap

// SitemapPaths lists up to 500 recent article paths, or none when articles
// are off or the backend can't answer.
func (h *ArticlesHandler) SitemapPaths(ctx context.Context) []string {
	if h.deps == nil || !h.deps.Config.PublicPagesEnabled() {
		return nil
	}
	var paths []string
	cursor := ""
	for range 5 {
		page, err := h.deps.API.ListArticles(ctx, api.ArticleListQuery{Cursor: cursor, Limit: 100}, h.publicEditor())
		if err != nil {
			return paths
		}
		for _, s := range page.Items {
			paths = append(paths, articles.Path(s.Slug, s.Code))
		}
		if page.NextCursor == nil {
			break
		}
		cursor = *page.NextCursor
	}
	return paths
}
```

Add a placeholder `MountSignedIn` so this task compiles. Task 15 replaces it:

```go
// MountSignedIn registers the write routes; filled in by the composer task.
func (h *ArticlesHandler) MountSignedIn(r chi.Router) {}
```

- [ ] **Step 5: Write the share script (`internal/server/assets/article-share.js`)**

```js
// Article share bar and view beacon. Plain DOM; no third-party widgets.

async function copyText (text, button) {
  try {
    await navigator.clipboard.writeText(text)
  } catch {
    const area = document.createElement('textarea')
    area.value = text
    area.setAttribute('readonly', '')
    area.style.position = 'fixed'
    area.style.opacity = '0'
    document.body.appendChild(area)
    area.select()
    document.execCommand('copy')
    area.remove()
  }
  const label = button.textContent
  button.textContent = 'Copied'
  setTimeout(() => { button.textContent = label }, 1500)
}

// Instagram has no web share URL: hand the card image to the OS share sheet
// where files are supported (mobile), otherwise download it and copy a caption.
async function shareCard (button) {
  const response = await fetch(button.dataset.cardUrl)
  const blob = await response.blob()
  const file = new File([blob], 'norviq-article.png', { type: 'image/png' })
  if (navigator.canShare && navigator.canShare({ files: [file] })) {
    try {
      await navigator.share({ files: [file], text: button.dataset.caption })
      return
    } catch (error) {
      if (error && error.name === 'AbortError') return
    }
  }
  const link = document.createElement('a')
  link.href = URL.createObjectURL(blob)
  link.download = 'norviq-article.png'
  document.body.appendChild(link)
  link.click()
  link.remove()
  await copyText(button.dataset.caption, button)
}

function recordView (element) {
  const url = element.dataset.articleView
  if (!url) return
  try {
    const key = 'nv-viewed:' + url
    if (sessionStorage.getItem(key)) return
    sessionStorage.setItem(key, '1')
  } catch {}
  fetch(url, { method: 'POST', keepalive: true, credentials: 'same-origin' }).catch(() => {})
}

export function initArticleShare (root = document) {
  root.querySelectorAll('[data-share-copy]').forEach((button) => {
    button.addEventListener('click', () => copyText(button.dataset.shareCopy, button))
  })
  root.querySelectorAll('[data-share-card]').forEach((button) => {
    button.addEventListener('click', () => shareCard(button))
  })
  root.querySelectorAll('[data-article-view]').forEach(recordView)
}
```

In `scripts.js`, add `import { initArticleShare } from './article-share.js'` beside the other imports, and call `initArticleShare()` wherever the file runs its other page initialisers on load.

Run: `bun run dev`. Expected: the parcel build succeeds.

- [ ] **Step 6: Run the tests and check they pass**

Run: `templ generate && go test ./internal/handlers -run 'Article|Detail|Feed|Share|View|Hidden' -count=1 -race`
Expected: PASS (7 tests).

- [ ] **Step 7: Commit**

```bash
git add internal/pages/articles internal/handlers/articles.go internal/handlers/articles_test.go internal/server/assets/article-share.js internal/server/assets/scripts.js
git commit -m "feat(articles): public article pages, feeds, share cards and view beacon"
```

---

### Task 15: Composer, edit/delete, vote, report, moderation (signed in)

**Files:**
- Create: `norviq-web/internal/handlers/articles_compose.go`
- Modify: `norviq-web/internal/handlers/articles.go`. Delete the placeholder `MountSignedIn`.
- Modify: `norviq-web/internal/pages/articles/articles.templ`. Add `ComposePage` and `Preview`, then run `templ generate`.
- Test: `norviq-web/internal/handlers/articles_compose_test.go`

**Interfaces:**
- Consumes:
  - Task 9 client
  - `markdown.Render`
  - `h.app.loadBoardsViewer` (returns `boards.Viewer` with `NeedsSetup`, `NeedsUsername`)
  - `h.app.renderShell(w, r, title, meta, activePath, content)`
  - `boardsErrorText(err)`
  - `components.Field` / `components.FieldProps{Name, Label, Value, Placeholder, Description, Required}`
- Produces `MountSignedIn(r)` with these routes:
  - `GET|POST /articles/new`
  - `GET|POST /articles/{code}/edit`
  - `POST /articles/{code}/delete`
  - `POST /articles/{code}/vote`
  - `POST /articles/{code}/report`
  - `POST /articles/{code}/visibility`
  - `POST /articles/preview`

- [ ] **Step 1: Write the failing tests**

```go
package handlers

import (
	"encoding/json"
	"net/http"
	"net/url"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func composeForm() url.Values {
	return url.Values{
		"title":      {"Why 2027 could reprice NEXT & co"},
		"tickers":    {"next, NVDA"},
		"bullet1":    {"First LNG from Train 1 is targeted for 1H 2027."},
		"bullet2":    {""},
		"bullet3":    {""},
		"body":       {"Revenue visibility is long."},
		"disclosure": {"I hold a position in $NEXT."},
	}
}

func TestComposeCreatesAndRedirects(t *testing.T) {
	t.Parallel()
	svc, backend := newArticlesBackend(t)
	h := articlesRouter(t, svc)
	cookie := signedInCookie(t, h)

	rec := serveArticles(t, h, http.MethodPost, "/articles/new", composeForm(), cookie)
	require.Equal(t, http.StatusSeeOther, rec.Code)
	assert.Equal(t, "/articles/why-2027-abcd2345?notice=published", rec.Header().Get("Location"))

	backend.mu.Lock()
	raw := backend.bodies["POST /v1/articles"]
	backend.mu.Unlock()
	var sent map[string]any
	require.NoError(t, json.Unmarshal([]byte(raw), &sent))
	assert.Equal(t, []any{"next", "NVDA"}, sent["tickers"])
	assert.Equal(t, []any{"First LNG from Train 1 is targeted for 1H 2027."}, sent["bulletPoints"], "blank key points are dropped")
	assert.Equal(t, "web", sent["source"])
	assert.Equal(t, "Bearer user-token", backend.authFor("POST /v1/articles"))
}

func TestComposeShowsBackendErrorAndKeepsInput(t *testing.T) {
	t.Parallel()
	svc, _ := newArticlesBackend(t)
	h := articlesRouter(t, svc)
	cookie := signedInCookie(t, h)
	form := composeForm()
	form.Set("title", "Rejected title for the test")
	rec := serveArticles(t, h, http.MethodPost, "/articles/abcd2345/edit", form, cookie)
	assert.Equal(t, http.StatusUnprocessableEntity, rec.Code)
	assert.Contains(t, rec.Body.String(), "Not found")
	assert.Contains(t, rec.Body.String(), `value="Rejected title for the test"`)
}

func TestComposeRequiresGuidelines(t *testing.T) {
	t.Parallel()
	svc, _ := newArticlesBackendWithViewer(t, `{"isAdmin":false,"guidelinesAccepted":false,"hasUsername":true,"activeSanction":null}`)
	h := articlesRouter(t, svc)
	cookie := signedInCookie(t, h)
	rec := serveArticles(t, h, http.MethodGet, "/articles/new", nil, cookie)
	assert.Equal(t, http.StatusSeeOther, rec.Code)
	assert.Equal(t, "/boards/guidelines?next=%2Farticles%2Fnew", rec.Header().Get("Location"))
}

func TestArticleVoteSwapsTheButton(t *testing.T) {
	t.Parallel()
	svc, backend := newArticlesBackend(t)
	h := articlesRouter(t, svc)
	cookie := signedInCookie(t, h)
	rec := serveArticles(t, h, http.MethodPost, "/articles/abcd2345/vote", url.Values{"on": {"true"}}, cookie)
	require.Equal(t, http.StatusOK, rec.Code)
	html := rec.Body.String()
	assert.Contains(t, html, `id="article-vote-abcd2345"`)
	assert.Contains(t, html, `aria-pressed="true"`)
	assert.Contains(t, html, "7")
	assert.Equal(t, 1, backend.count("POST /v1/articles/abcd2345/vote"))
}

func TestPreviewIsSanitised(t *testing.T) {
	t.Parallel()
	svc, _ := newArticlesBackend(t)
	h := articlesRouter(t, svc)
	cookie := signedInCookie(t, h)
	rec := serveArticles(t, h, http.MethodPost, "/articles/preview", url.Values{"body": {"**hi** <script>x()</script>"}}, cookie)
	require.Equal(t, http.StatusOK, rec.Code)
	assert.Contains(t, rec.Body.String(), "<strong>hi</strong>")
	assert.NotContains(t, rec.Body.String(), "<script")
}
```

In `articles_test.go` (Task 14), rename `newArticlesBackend` to `newArticlesBackendWithViewer(t *testing.T, viewer string)`. Change its community case to `case key == "GET /v1/community/me": _, _ = w.Write([]byte(viewer))`, then add:

```go
func newArticlesBackend(t *testing.T) (*api.Service, *articlesBackend) {
	return newArticlesBackendWithViewer(t, `{"isAdmin":false,"guidelinesAccepted":true,"hasUsername":true,"activeSanction":null}`)
}
``` `PATCH /v1/articles/abcd2345` falls through to the 404 default on purpose: that is the "backend error" path the edit test exercises.

The signed-in routes sit outside `RequireAuth` in this test router. That matches production: `RequireAuth` is applied by server.go (Task 16), not by `MountSignedIn`.

- [ ] **Step 2: Run the tests and check they fail**

Run: `go test ./internal/handlers -run 'Compose|ArticleVote|Preview' -count=1`
Expected: FAIL with 404/405 (routes not mounted).

- [ ] **Step 3: Add the templates to `articles.templ`**

```templ
templ Preview(html string) {
	@templ.Raw(html)
}

templ ComposePage(vm ComposeVM) {
	<div class="mx-auto w-full max-w-3xl px-6 py-8">
		<h1 class="text-2xl font-semibold">{ vm.Heading }</h1>
		<p class="mt-1 text-sm text-muted-foreground">Your article is public and shows on each ticker's page. { Disclaimer }</p>
		if vm.Error != "" {
			<p role="alert" class="mt-4 rounded-lg border border-[var(--color-danger)] p-3 text-sm">{ vm.Error }</p>
		}
		if !vm.Blocked {
			<form method="post" action={ templ.SafeURL(vm.Action) } enctype="multipart/form-data" class="mt-6 space-y-5">
				@components.CSRFField()
				@components.Field(components.FieldProps{Name: "title", Label: "Title", Value: vm.Form.Title, Required: true, Placeholder: "Why 2027 could reprice NextDecade"})
				@components.Field(components.FieldProps{Name: "tickers", Label: "Tickers", Value: vm.Form.Tickers, Required: true, Placeholder: "NEXT, NVDA", Description: "One to five, separated by commas."})
				<fieldset class="space-y-2">
					<legend class="text-sm font-medium">Key points</legend>
					<p class="text-xs text-muted-foreground">One to three one-line takeaways. They lead the article and the share card.</p>
					for i, b := range vm.Form.Bullets {
						<input type="text" name={ "bullet" + strconv.Itoa(i+1) } value={ b } maxlength="240" class="block w-full rounded-lg border border-border p-2" placeholder="A one-line takeaway"/>
					}
				</fieldset>
				<label class="block text-sm font-medium">
					Article (Markdown)
					<textarea
						name="body"
						rows="18"
						required
						maxlength="20000"
						class="mt-1 block w-full rounded-lg border border-border p-3 font-mono text-sm"
						hx-post="/articles/preview"
						hx-trigger="keyup changed delay:600ms"
						hx-params="body"
						hx-target="#article-preview"
						hx-swap="innerHTML"
					>{ vm.Form.Body }</textarea>
				</label>
				<section>
					<h2 class="text-sm font-medium">Preview</h2>
					<div id="article-preview" class="prose mt-2 max-w-none rounded-lg border border-border p-4">
						@templ.Raw(vm.Preview)
					</div>
				</section>
				@components.Field(components.FieldProps{Name: "disclosure", Label: "Disclosure", Value: vm.Form.Disclosure, Required: true, Placeholder: "I hold a position in $NEXT.", Description: "Required. For example: \"No position\", \"I hold shares\", \"I may trade within 72 hours\"."})
				<label class="block text-sm font-medium">
					Cover image (optional)
					<input type="file" name="cover" accept="image/jpeg,image/png,image/webp" class="mt-1 block text-sm"/>
				</label>
				if vm.Form.CoverImageID != "" {
					<input type="hidden" name="cover_image_id" value={ vm.Form.CoverImageID }/>
					<p class="text-xs text-muted-foreground">The current cover stays unless you choose a new one.</p>
				}
				<button type="submit" class="rounded-lg bg-[var(--color-accent)] px-4 py-2 font-medium text-white">{ vm.Submit }</button>
			</form>
		}
	</div>
}
```

> If `components.FieldProps` has no `Required` field, drop it from these calls. The backend still enforces it.
> Check this in `internal/pages/components/field_templ.go:184`.

Run: `templ generate`.

- [ ] **Step 4: Write `articles_compose.go`**

```go
package handlers

import (
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"unicode"

	"github.com/FinancePlanner/StockPlanWeb/internal/api"
	"github.com/FinancePlanner/StockPlanWeb/internal/markdown"
	"github.com/FinancePlanner/StockPlanWeb/internal/middleware"
	"github.com/FinancePlanner/StockPlanWeb/internal/pages/articles"
	"github.com/go-chi/chi/v5"
)

const articleFormMaxBytes = 4 << 20

// MountSignedIn registers the write routes. server.go wraps them in
// RequireAuth and the articles gate.
func (h *ArticlesHandler) MountSignedIn(r chi.Router) {
	r.Get("/articles/new", h.NewForm)
	r.Post("/articles/new", h.Create)
	r.Post("/articles/preview", h.Preview)
	r.Get("/articles/{code}/edit", h.EditForm)
	r.Post("/articles/{code}/edit", h.Update)
	r.Post("/articles/{code}/delete", h.Delete)
	r.Post("/articles/{code}/vote", h.Vote)
	r.Post("/articles/{code}/report", h.Report)
	r.Post("/articles/{code}/visibility", h.Visibility)
}

func (h *ArticlesHandler) writer(r *http.Request) api.RequestEditorFn {
	return middleware.BearerEditor(h.deps.Session, r)
}

func (h *ArticlesHandler) renderCompose(w http.ResponseWriter, r *http.Request, vm articles.ComposeVM, status int) {
	if vm.Preview == "" && vm.Form.Body != "" {
		vm.Preview = markdown.Render(vm.Form.Body)
	}
	if status != http.StatusOK {
		w.WriteHeader(status)
	}
	h.app.renderShell(w, r, vm.Heading+" - Norviq", nil, "/articles", articles.ComposePage(vm))
}

// composeGate sends a member who hasn't accepted the guidelines to them, and
// blocks one without a username. It reports whether the page may render.
func (h *ArticlesHandler) composeGate(w http.ResponseWriter, r *http.Request, vm *articles.ComposeVM) bool {
	viewer, ok := h.app.loadBoardsViewer(w, r)
	if !ok {
		return false
	}
	if viewer.NeedsSetup {
		http.Redirect(w, r, "/boards/guidelines?next="+url.QueryEscape(r.URL.RequestURI()), http.StatusSeeOther)
		return false
	}
	if viewer.NeedsUsername {
		vm.Blocked = true
		vm.Error = "Pick a username in Settings before publishing."
	}
	return true
}

func (h *ArticlesHandler) NewForm(w http.ResponseWriter, r *http.Request) {
	vm := articles.ComposeVM{Heading: "Write an article", Action: "/articles/new", Submit: "Publish"}
	if !h.composeGate(w, r, &vm) {
		return
	}
	h.renderCompose(w, r, vm, http.StatusOK)
}

func (h *ArticlesHandler) Create(w http.ResponseWriter, r *http.Request) {
	vm := articles.ComposeVM{Heading: "Write an article", Action: "/articles/new", Submit: "Publish"}
	form, err := h.readForm(w, r)
	vm.Form = form
	if err != nil {
		vm.Error = boardsErrorText(err)
		h.renderCompose(w, r, vm, http.StatusUnprocessableEntity)
		return
	}
	req := articleWriteRequest(form)
	req.Source = "web"
	detail, err := h.deps.API.CreateArticle(r.Context(), req, h.writer(r))
	if err != nil {
		vm.Error = boardsErrorText(err)
		h.renderCompose(w, r, vm, http.StatusUnprocessableEntity)
		return
	}
	http.Redirect(w, r, articles.Path(detail.Article.Slug, detail.Article.Code)+"?notice=published", http.StatusSeeOther)
}

func (h *ArticlesHandler) EditForm(w http.ResponseWriter, r *http.Request) {
	code, ok := articles.ParseSlugCode(chi.URLParam(r, "code"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	detail, err := h.deps.API.GetArticle(r.Context(), code, h.writer(r))
	if err != nil || !detail.ViewerIsAuthor {
		http.NotFound(w, r)
		return
	}
	a := detail.Article
	form := articles.Form{
		Title: a.Title, Tickers: strings.Join(a.Tickers, ", "), Body: detail.BodyMarkdown, Disclosure: detail.Disclosure,
	}
	copy(form.Bullets[:], a.BulletPoints)
	if a.CoverImageID != nil {
		form.CoverImageID = *a.CoverImageID
	}
	h.renderCompose(w, r, articles.ComposeVM{Heading: "Edit article", Action: "/articles/" + code + "/edit", Submit: "Save", Form: form}, http.StatusOK)
}

func (h *ArticlesHandler) Update(w http.ResponseWriter, r *http.Request) {
	code, ok := articles.ParseSlugCode(chi.URLParam(r, "code"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	vm := articles.ComposeVM{Heading: "Edit article", Action: "/articles/" + code + "/edit", Submit: "Save"}
	form, err := h.readForm(w, r)
	vm.Form = form
	if err == nil {
		var detail *api.ArticleDetail
		detail, err = h.deps.API.UpdateArticle(r.Context(), code, articleWriteRequest(form), h.writer(r))
		if err == nil {
			http.Redirect(w, r, articles.Path(detail.Article.Slug, detail.Article.Code)+"?notice=updated", http.StatusSeeOther)
			return
		}
	}
	vm.Error = boardsErrorText(err)
	h.renderCompose(w, r, vm, http.StatusUnprocessableEntity)
}

func (h *ArticlesHandler) Delete(w http.ResponseWriter, r *http.Request) {
	code, ok := articles.ParseSlugCode(chi.URLParam(r, "code"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	if err := h.deps.API.DeleteArticle(r.Context(), code, h.writer(r)); err != nil {
		http.Error(w, boardsErrorText(err), http.StatusUnprocessableEntity)
		return
	}
	http.Redirect(w, r, "/articles?notice=deleted", http.StatusSeeOther)
}

func (h *ArticlesHandler) Vote(w http.ResponseWriter, r *http.Request) {
	code, ok := articles.ParseSlugCode(chi.URLParam(r, "code"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	vote, err := h.deps.API.VoteArticle(r.Context(), code, r.FormValue("on") != "false", h.writer(r))
	if err != nil {
		w.Header().Set("HX-Reswap", "none")
		http.Error(w, boardsErrorText(err), http.StatusUnprocessableEntity)
		return
	}
	setHTMLContentType(w)
	_ = articles.VoteButton(code, vote.UpvoteCount, vote.Voted, true, "").Render(r.Context(), w)
}

func (h *ArticlesHandler) Report(w http.ResponseWriter, r *http.Request) {
	code, ok := articles.ParseSlugCode(chi.URLParam(r, "code"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	if err := h.deps.API.ReportArticle(r.Context(), code, r.FormValue("reason"), strings.TrimSpace(r.FormValue("note")), h.writer(r)); err != nil {
		slog.Warn("article report failed", "code", code, "error", err)
		http.Redirect(w, r, "/a/"+code, http.StatusSeeOther)
		return
	}
	h.redirectToArticle(w, r, code, "reported")
}

func (h *ArticlesHandler) Visibility(w http.ResponseWriter, r *http.Request) {
	code, ok := articles.ParseSlugCode(chi.URLParam(r, "code"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	hidden := r.FormValue("hidden") == "true"
	if err := h.deps.API.SetArticleVisibility(r.Context(), code, hidden, h.writer(r)); err != nil {
		http.Error(w, boardsErrorText(err), http.StatusForbidden)
		return
	}
	notice := "unhidden"
	if hidden {
		notice = "hidden"
	}
	h.redirectToArticle(w, r, code, notice)
}

func (h *ArticlesHandler) redirectToArticle(w http.ResponseWriter, r *http.Request, code, notice string) {
	detail, err := h.deps.API.GetArticle(r.Context(), code, h.writer(r))
	if err != nil {
		http.Redirect(w, r, "/articles?notice="+notice, http.StatusSeeOther)
		return
	}
	http.Redirect(w, r, articles.Path(detail.Article.Slug, detail.Article.Code)+"?notice="+notice, http.StatusSeeOther)
}

func (h *ArticlesHandler) Preview(w http.ResponseWriter, r *http.Request) {
	body := r.FormValue("body")
	if len(body) > 20000 {
		body = body[:20000]
	}
	setHTMLContentType(w)
	_ = articles.Preview(markdown.Render(body)).Render(r.Context(), w)
}

// readForm parses the composer, uploading a new cover first when one was
// chosen. The returned form always carries what the person typed, so a
// failure can re-render it.
func (h *ArticlesHandler) readForm(w http.ResponseWriter, r *http.Request) (articles.Form, error) {
	r.Body = http.MaxBytesReader(w, r.Body, articleFormMaxBytes)
	if strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/") {
		if err := r.ParseMultipartForm(articleFormMaxBytes); err != nil {
			return articles.Form{}, &api.BoardsError{Status: http.StatusRequestEntityTooLarge, Reason: "That upload is too large. Covers can be 2 MB."}
		}
	}
	form := articles.Form{
		Title:        r.FormValue("title"),
		Tickers:      r.FormValue("tickers"),
		Body:         r.FormValue("body"),
		Disclosure:   r.FormValue("disclosure"),
		CoverImageID: r.FormValue("cover_image_id"),
		Bullets:      [3]string{r.FormValue("bullet1"), r.FormValue("bullet2"), r.FormValue("bullet3")},
	}
	file, header, err := r.FormFile("cover")
	if err != nil || header.Size == 0 {
		return form, nil
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, 2_000_001))
	if err != nil {
		return form, err
	}
	id, err := h.deps.API.UploadArticleImage(r.Context(), header.Filename, data, h.writer(r))
	if err != nil {
		return form, err
	}
	form.CoverImageID = id
	return form, nil
}

func articleWriteRequest(f articles.Form) api.ArticleWriteRequest {
	var bullets []string
	for _, b := range f.Bullets {
		if strings.TrimSpace(b) != "" {
			bullets = append(bullets, strings.TrimSpace(b))
		}
	}
	tickers := strings.FieldsFunc(f.Tickers, func(r rune) bool { return r == ',' || unicode.IsSpace(r) })
	req := api.ArticleWriteRequest{
		Title: f.Title, BodyMarkdown: f.Body, BulletPoints: bullets, Tickers: tickers, Disclosure: f.Disclosure,
	}
	if f.CoverImageID != "" {
		id := f.CoverImageID
		req.CoverImageID = &id
	}
	return req
}
```

> `boardsErrorText(err)` already exists in `boards.go:113`. Check that it returns the backend `Reason`; the edit test
> expects "Not found". If it maps codes to fixed copy instead, assert on that copy.

- [ ] **Step 5: Run the tests and check they pass**

Run: `templ generate && go test ./internal/handlers -count=1 -race`
Expected: PASS. This is the whole handlers package, so Boards and public-stock tests are covered too.

- [ ] **Step 6: Commit**

```bash
git add internal/handlers/articles.go internal/handlers/articles_compose.go internal/handlers/articles_compose_test.go internal/handlers/articles_test.go internal/pages/articles
git commit -m "feat(articles): composer, edit/delete, vote, report and moderation"
```

---

### Task 16: Wire routes, CSRF exemption, sitemap and nav

**Files:**
- Modify: `norviq-web/internal/server/server.go`
- Modify: `norviq-web/internal/middleware/csrf.go`. Add `handler.ExemptGlob("/articles/*/view")` beside `ExemptGlob("/auth/oauth/*/callback")`.
- Modify: `norviq-web/internal/server/seo.go` and `norviq-web/internal/server/seo_test.go`
- Modify: the app nav component that links `/boards`. Find it with `grep -rn '"/boards"' internal/pages/components templates | grep -v _templ.go`.
- Test: `norviq-web/internal/server/seo_test.go` (new case)

**Interfaces:**
- Consumes: `ArticlesHandler.MountPublic`, `MountSignedIn`, `SitemapPaths`; `middleware.AttachArticlesAvailability`, `RequireArticles`; `articlegate.Enabled`.

- [ ] **Step 1: Write the failing sitemap test**

Add to `seo_test.go`:

```go
func TestSitemapIncludesArticlePaths(t *testing.T) {
	t.Parallel()
	rec := httptest.NewRecorder()
	extra := func(context.Context) []string { return []string{"/articles/why-2027-abcd2345"} }
	sitemapHandler(&config.Config{PublicBaseURL: "https://www.norviq.org/"}, extra).
		ServeHTTP(rec, httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/sitemap.xml", nil))
	assert.Contains(t, rec.Body.String(), "<loc>https://www.norviq.org/articles/why-2027-abcd2345</loc>")
}
```

Update the two existing `sitemapHandler(...)` calls in `seo_test.go` to pass `nil` as the second argument.

- [ ] **Step 2: Run the test and check it fails**

Run: `go test ./internal/server -run Sitemap -count=1`
Expected: FAIL to compile with "too many arguments".

- [ ] **Step 3: Extend the sitemap**

In `seo.go`, change the signature and append the extra paths after the ticker loop:

```go
// extra lists further public paths (articles); nil for none.
func sitemapHandler(cfg *config.Config, extra func(context.Context) []string) http.HandlerFunc {
```

Inside, after the `publicsymbols` loop:

```go
		if extra != nil {
			for _, p := range extra(r.Context()) {
				set.URLs = append(set.URLs, sitemapURL{Loc: base + p})
			}
		}
```

Add `"context"` to the imports.

- [ ] **Step 4: Wire the routes in `server.go`**

Near the other handler constructions, before `router.Get("/sitemap.xml", …)`:

```go
	articlesHandler := handlers.NewArticlesHandler(deps, appHandler)
	attachArticles := middleware.AttachArticlesAvailability(deps.API, deps.Config)
```

If `appHandler` is created later in the function, move `articlesHandler`'s construction below it, and reorder so the sitemap line comes after.

Change the sitemap line:

```go
	router.Get("/sitemap.xml", sitemapHandler(deps.Config, articlesHandler.SitemapPaths))
```

Add the public routes next to `/s/{symbol}`:

```go
	// User-written articles. Public and crawlable like /s/{symbol}; the gate
	// 404s them while the backend has ARTICLES_ENABLED off or PUBLIC_API_TOKEN
	// is unset.
	router.Group(func(r chi.Router) {
		r.Use(attachArticles, middleware.RequireArticles)
		articlesHandler.MountPublic(r)
	})
```

Inside the existing signed-in group that registers `/boards` (around line 605), add:

```go
		r.Group(func(r chi.Router) {
			r.Use(attachArticles, middleware.RequireArticles)
			articlesHandler.MountSignedIn(r)
		})
```

chi picks the static `/articles/new` over the public `/articles/{slugcode}`, even across groups. The test in Step 6 checks that.

For the nav, wrap the router's app-shell middleware chain so `articlegate.Enabled(ctx)` is answered on every page. The simplest way is to add `router.Use(attachArticles)` right after the session middleware near line 167, and drop the `attachArticles` from the two groups above (keep `RequireArticles`). Do one or the other, not both. If the global `Use` must come before any route registration, chi panics otherwise, so put it with the other `router.Use` calls.

- [ ] **Step 5: Exempt the view beacon from CSRF and add the nav link**

In `internal/middleware/csrf.go`:

```go
		// The article view beacon only bumps a de-duplicated counter, and
		// anonymous article pages are cached without a CSRF token.
		handler.ExemptGlob("/articles/*/view")
```

In the nav component that lists `/boards`, add an "Articles" link to `/articles`, rendered only when `articlegate.Enabled(ctx)`. Match the markup of the Boards entry exactly. Run `templ generate`.

- [ ] **Step 6: Add a routing test and run the full suite**

Add to `internal/server` tests, next to any existing router test (search `setupRouter(` in `*_test.go` for how they build the router). Assert:
- `GET /articles/new` without a session redirects to `/login?next=…` when the gate is on.
- `GET /articles` returns 404 when the gate probe gets a 404.

If building the full router in a test is impractical, which is likely given its dependencies, skip this test. Instead, in Step 7, check both cases manually against a local backend.

Run: `templ generate && make test`
Expected: PASS for the whole repo.

- [ ] **Step 7: Local end-to-end check**

1. Start the backend with `ARTICLES_ENABLED=true` (`docker compose up` in norviq-backend, or `swift run`).
2. Start the web app with `PUBLIC_API_TOKEN` set to a PAT that has `market:read`, and `PUBLIC_BASE_URL=http://localhost:<port>`.
3. Sign up, accept the Boards guidelines and set a username.
4. Open `/articles/new`. Publish an article with a cover.
5. Open the article in a private window, logged out. Check the cards, the share buttons and `/a/{code}`.
6. Check that `curl -sI` on the article shows `Cache-Control: public, max-age=900` and no `Set-Cookie`.
7. Restart the backend with the flag off. `/articles` should 404 within about 60 seconds.

- [ ] **Step 8: Commit**

```bash
git add internal/server internal/middleware/csrf.go internal/pages/components templates
git commit -m "feat(articles): mount article routes behind the gate, sitemap and nav link"
```

---

# Part D — Infra and staging

### Task 17: Flag on in staging, off in production

**Files:**
- Modify: `~/Work/production/platform/infra/apps/norviq/api/values-common.yaml`
- Modify: `~/Work/production/platform/infra/apps/norviq/api/values-production.yaml`
- Modify: `~/Work/production/platform/infra/apps/norviq/api/values-staging.yaml`

- [ ] **Step 1: Branch from main (the checkout is on another feature branch)**

```bash
cd ~/Work/production/platform/infra && git status --short && git fetch origin && git checkout -b feat/norviq-articles-flag origin/main
```

If `git status` shows uncommitted work, stop and ask the user. Don't stash someone else's work.

- [ ] **Step 2: Add the env entries beside `PILOTS_ENABLED` in each file**

`values-common.yaml` and `values-production.yaml`:

```yaml
  # Articles: user-published, ticker-tagged stock write-ups.
  # Off until the staging check and the compliance read of the disclaimer copy.
  - name: ARTICLES_ENABLED
    value: "false"
```

`values-staging.yaml`:

```yaml
  # On in staging for the end-to-end check; production stays off until it
  # passes and the "not investment advice" copy has had a compliance read.
  - name: ARTICLES_ENABLED
    value: "true"
```

- [ ] **Step 3: Check the YAML parses and the keys are in the right list**

Run: `for f in apps/norviq/api/values-{common,production,staging}.yaml; do python3 -I -c "import sys,yaml; yaml.safe_load(open('$f'))" && echo ok $f; done && git diff`
Expected: three `ok` lines, and the diff shows only the new entries.

- [ ] **Step 4: Commit, then ask before pushing**

Merging to infra `main` deploys through ArgoCD.

```bash
git add apps/norviq/api/values-*.yaml
git commit -m "feat(norviq): ARTICLES_ENABLED on in staging, off in production"
```

Ask the user, then run `git push -u origin feat/norviq-articles-flag && gh pr create --fill`.

### Task 18: Staging rollout and end-to-end check (user approves each outward step)

- [ ] **Step 1: Push and merge, each with the user's approval**
  - norviq-shared tag `v5.19.0` (done in Task 1).
  - norviq-backend `feat/articles` → PR → CI green → merge.
  - norviq-web `feat/articles` → PR → CI green → merge.
  - The infra PR from Task 17 → merge.
- [ ] **Step 2: Deploy staging**
  - Dispatch "Deploy to k3s (staging)" in norviq-backend and in norviq-web: `gh workflow run deploy-k3s.yml` in each repo.
  - Wait for ArgoCD sync: `KUBECONFIG=~/.kube/maat.yaml kubectl -n norviq-staging get pods`.
  - The migration runs as a PreSync hook. Confirm it with `kubectl -n norviq-staging logs job/<migrate job>`.
- [ ] **Step 3: Staging E2E**
  1. Publish on staging web.
  2. Open the article logged out.
  3. Paste the URL into the X post composer preview, the LinkedIn Post Inspector (`https://www.linkedin.com/post-inspector/`) and a Discord channel. The 1200×630 card should show in all three.
  4. On an iPhone, tap "Instagram card". The share sheet should list Instagram.
  5. Upvote from a second account.
  6. Report from a second account. A 🚩 ping should arrive in the ops Discord channel.
  7. As an admin, hide the article. It should 404 logged out and disappear from `/articles`.
  8. Check `/sitemap.xml` lists the article.
- [ ] **Step 4: Report the result to the user.** Production is not promoted in this phase. `promote-norviq.yml -f service=both` and flipping `values-production.yaml` both wait for the user's compliance read and their explicit go.
