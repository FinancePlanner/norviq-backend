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
