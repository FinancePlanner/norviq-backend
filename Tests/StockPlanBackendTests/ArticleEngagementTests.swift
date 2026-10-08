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

    @Test("the web's listed credential counts each forwarded viewer once a day")
    func listedCredentialCountsViewers() async throws {
        try await Kit.withApp { app in
            let ana = try await Kit.member(app, "lv_ana")
            let web = try await Kit.credential(app, owner: ana)
            app.articleViewerCredentialIds = [web.id]
            let code = try await Kit.publish(app, as: ana).article.code
            let alice: HTTPHeaders = ["X-Norviq-Viewer": "0123456789abcdef0123456789abcdef"]
            let bob: HTTPHeaders = ["X-Norviq-Viewer": "fedcba9876543210fedcba9876543210"]

            for headers in [alice, alice, bob, bob] {
                #expect(try await Kit.send(app, .POST, "v1/articles/\(code)/view", token: web.token, headers: headers).status == .noContent)
            }
            // No viewer key: nothing to dedupe on, so nothing is counted.
            #expect(try await Kit.send(app, .POST, "v1/articles/\(code)/view", token: web.token).status == .noContent)

            let detail = try await Kit.send(app, .GET, "v1/articles/\(code)", as: ana).decode(ArticleDetail.self)
            #expect(detail.article.viewCount == 2)
        }
    }

    @Test("any other market:read credential counts nothing, however it rotates the viewer header")
    func unlistedCredentialCountsNothing() async throws {
        try await Kit.withApp { app in
            let ana = try await Kit.member(app, "uv_ana")
            let bo = try await Kit.member(app, "uv_bo")
            let web = try await Kit.credential(app, owner: ana)
            let other = try await Kit.credential(app, owner: bo)
            app.articleViewerCredentialIds = [web.id]
            let code = try await Kit.publish(app, as: ana).article.code

            for n in 0 ..< 5 {
                let headers: HTTPHeaders = ["X-Norviq-Viewer": String(repeating: String(n), count: 32)]
                #expect(try await Kit.send(app, .POST, "v1/articles/\(code)/view", token: other.token, headers: headers).status == .noContent)
            }
            #expect(try await Kit.send(app, .GET, "v1/articles/\(code)", as: ana).decode(ArticleDetail.self).article.viewCount == 0)

            // A first-party session is still keyed by its user.
            #expect(try await Kit.send(app, .POST, "v1/articles/\(code)/view", as: bo).status == .noContent)
            #expect(try await Kit.send(app, .POST, "v1/articles/\(code)/view", as: bo).status == .noContent)
            #expect(try await Kit.send(app, .GET, "v1/articles/\(code)", as: ana).decode(ArticleDetail.self).article.viewCount == 1)
        }
    }

    @Test("ARTICLES_VIEWER_CREDENTIAL_IDS tolerates whitespace, empties and junk")
    func parsesCredentialIds() {
        let first = UUID()
        let second = UUID()
        #expect(ArticleViewerCredentials.parse(nil).isEmpty)
        #expect(ArticleViewerCredentials.parse(" , ").isEmpty)
        #expect(ArticleViewerCredentials.parse(" \(first.uuidString.lowercased()) ,, \(second.uuidString) ,not-a-uuid") == [first, second])
    }

    /// Stands in for the Redis limiter, which is off under `.testing`.
    private struct RefusingLimiter: AsyncMiddleware {
        func respond(to _: Request, chainingTo _: any AsyncResponder) async throws -> Response {
            throw Abort(.tooManyRequests)
        }
    }

    private struct OK: AsyncResponder {
        func respond(to _: Request) async throws -> Response {
            Response(status: .noContent)
        }
    }

    @Test("the per-user view limiter skips the listed credential and applies to everyone else")
    func viewLimiterSkipsListedCredential() async throws {
        let app = try await Application.make(.testing)
        do {
            try await checkViewLimiter(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func checkViewLimiter(_ app: Application) async throws {
        let web = UUID()
        app.articleViewerCredentialIds = [web]
        let middleware = ArticleViewRateLimitMiddleware(limiter: RefusingLimiter())

        func request(scope tokenId: UUID?) -> Request {
            let req = Request(application: app, on: app.eventLoopGroup.next())
            req.auth.login(SessionToken(userId: UUID(), exp: .init(value: Date().addingTimeInterval(60))))
            if let tokenId {
                req.auth.login(ScopeContext(tokenId: tokenId, kind: .personalAccessToken, scopes: [.marketRead]))
            }
            return req
        }

        let listed = try await middleware.respond(to: request(scope: web), chainingTo: OK())
        #expect(listed.status == .noContent)
        await #expect { try await middleware.respond(to: request(scope: UUID()), chainingTo: OK()) } throws: {
            ($0 as? any AbortError)?.status == .tooManyRequests
        }
        await #expect { try await middleware.respond(to: request(scope: nil), chainingTo: OK()) } throws: {
            ($0 as? any AbortError)?.status == .tooManyRequests
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
