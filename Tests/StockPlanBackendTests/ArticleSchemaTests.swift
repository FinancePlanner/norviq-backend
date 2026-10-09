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
