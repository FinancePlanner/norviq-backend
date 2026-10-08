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
        if missing.contains(symbol) {
            return .missing
        }
        if unavailable.contains(symbol) {
            return .unknown
        }
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

        var code: String? {
            try? decode(APIErrorEnvelope.self).code
        }
    }

    static func withApp(enabled: Bool = true, _ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("NORVIQ_ADMIN_EMAILS", adminEmail, 1)
            if enabled {
                setenv("ARTICLES_ENABLED", "true", 1)
            } else {
                unsetenv("ARTICLES_ENABLED")
            }
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
            if let auth {
                req.headers.bearerAuthorization = BearerAuthorization(token: auth.token)
            }
            for (name, value) in headers {
                req.headers.replaceOrAdd(name: name, value: value)
            }
            if let body {
                try req.content.encode(body)
            }
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
            #expect(try await Kit.send(app, .PUT, "v1/admin/articles/anything/visibility", as: auth, body: ArticleVisibilityRequest(hidden: true)).status == .notFound)
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
