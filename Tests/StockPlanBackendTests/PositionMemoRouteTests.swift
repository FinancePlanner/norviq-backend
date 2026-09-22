import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// Memo routes against a real database: ownership, the Pro gate, and the
/// bookmark flag. Rows are seeded directly so no model call is made.
extension AIEnvironmentSuites {
    @Suite("Position memo routes", .serialized)
    struct PositionMemoRouteTests {
        private func withApp(_ test: (Application) async throws -> Void) async throws {
            try await DatabaseTestLock.withLock {
                setenv("BYPASS_BILLING", "false", 1)
                let app = try await Application.make(.testing)
                do {
                    try await configure(app)
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

        private func registerUser(on app: Application, identifier: String, pro: Bool) async throws -> AuthResponse {
            let request = AuthRegisterRequest(
                username: "memo_\(identifier)",
                password: "Password123!",
                confirmPassword: "Password123!",
                email: "memo+\(identifier)@example.com",
                dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
            )
            var response: AuthResponse?
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(request)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                response = try res.content.decode(AuthResponse.self)
            })
            let auth = try #require(response)
            // Registration starts a trial, which resolves to pro. Clear it so a
            // free user is really free.
            let user = try #require(try await User.find(auth.userId, on: app.db))
            user.trialStartedAt = nil
            user.trialDays = nil
            user.trialTier = nil
            try await user.save(on: app.db)
            if pro {
                try await Entitlement(userId: auth.userId, level: "pro").save(on: app.db)
            }
            return auth
        }

        private func seedMemo(on app: Application, userId: UUID, bookmarked: Bool = false) async throws -> UUID {
            let crypto = app.userPIIEncryptionService
            func seal(_ value: some Encodable) throws -> Data {
                try crypto.encryptString(String(decoding: JSONEncoder().encode(value), as: UTF8.self))
            }
            let mark = PositionMemoMath.mark(PositionMemoMath.Input(
                askedSymbol: "A6I", primarySymbol: "GRAB", statedCost: 4.10, statedCurrency: "EUR",
                statedPercent: -34, live: .init(symbol: "A6I", price: 2.77, currency: "EUR"),
                primary: nil, fxRate: nil, fxPair: nil, fxDate: nil, shares: nil, lotAveragePrice: nil
            ))
            let row = try PositionMemo(
                userId: userId,
                conversationId: nil,
                askedSymbol: "A6I",
                primarySymbol: "GRAB",
                titleEncrypted: seal("Grab after the drawdown"),
                markEncrypted: seal(mark),
                sectionsEncrypted: seal([PositionMemoSection(heading: "What you own", paragraphs: ["Grab."])]),
                verdictEncrypted: seal("Q would not add here."),
                sourcesEncrypted: seal([PositionMemoSource]()),
                evidenceEncrypted: seal(["askedSymbol": "A6I"]),
                bookmarked: bookmarked
            )
            try await row.create(on: app.db)
            return try row.requireID()
        }

        @Test("The owner reads the memo with the server mark; another user gets 404")
        func detailIsOwnerScoped() async throws {
            try await withApp { app in
                let owner = try await registerUser(on: app, identifier: "owner", pro: true)
                let other = try await registerUser(on: app, identifier: "other", pro: true)
                let id = try await seedMemo(on: app, userId: owner.userId)

                try await app.testing().test(.GET, "v1/ai/memos/\(id)", beforeRequest: { req in req.headers.bearerAuthorization = .init(token: owner.token) }) { res async throws in
                    #expect(res.status == .ok)
                    let detail = try res.content.decode(PositionMemoDetail.self)
                    #expect(detail.primarySymbol == "GRAB")
                    #expect(detail.mark.costSource == "stated")
                    #expect(detail.footer == PositionMemoCopy.footer)
                }
                try await app.testing().test(.GET, "v1/ai/memos/\(id)", beforeRequest: { req in req.headers.bearerAuthorization = .init(token: other.token) }) { res async in
                    #expect(res.status == .notFound)
                }
                try await app.testing().test(.POST, "v1/ai/memos/\(id)/bookmark", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: other.token)
                    try req.content.encode(["bookmarked": true])
                }) { res async in
                    #expect(res.status == .notFound)
                }
                try await app.testing().test(.DELETE, "v1/ai/memos/\(id)", beforeRequest: { req in req.headers.bearerAuthorization = .init(token: other.token) }) { res async in
                    #expect(res.status == .notFound)
                }
                #expect(try await PositionMemo.find(id, on: app.db) != nil)
            }
        }

        @Test("Bookmarking moves a memo into the saved list, and delete removes it")
        func bookmarkAndList() async throws {
            try await withApp { app in
                let owner = try await registerUser(on: app, identifier: "saver", pro: true)
                let id = try await seedMemo(on: app, userId: owner.userId)
                _ = try await seedMemo(on: app, userId: owner.userId)

                try await app.testing().test(.GET, "v1/ai/memos?bookmarked=true", beforeRequest: { req in req.headers.bearerAuthorization = .init(token: owner.token) }) { res async throws in
                    #expect(try res.content.decode([PositionMemoListItem].self).isEmpty)
                }
                try await app.testing().test(.POST, "v1/ai/memos/\(id)/bookmark", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: owner.token)
                    try req.content.encode(["bookmarked": true])
                }) { res async throws in
                    #expect(res.status == .ok)
                    #expect(try res.content.decode(PositionMemoCard.self).bookmarked)
                }
                try await app.testing().test(.GET, "v1/ai/memos?bookmarked=true", beforeRequest: { req in req.headers.bearerAuthorization = .init(token: owner.token) }) { res async throws in
                    let saved = try res.content.decode([PositionMemoListItem].self)
                    #expect(saved.map(\.id) == [id.uuidString])
                    #expect(saved.first?.verdict == "Q would not add here.")
                }
                try await app.testing().test(.DELETE, "v1/ai/memos/\(id)", beforeRequest: { req in req.headers.bearerAuthorization = .init(token: owner.token) }) { res async in
                    #expect(res.status == .noContent)
                }
                #expect(try await PositionMemo.find(id, on: app.db) == nil)
            }
        }

        @Test("A free user gets the premium error and no memo is written")
        func freeUserIsGated() async throws {
            try await withApp { app in
                let free = try await registerUser(on: app, identifier: "free", pro: false)
                try await app.testing().test(.GET, "v1/ai/memos", beforeRequest: { req in req.headers.bearerAuthorization = .init(token: free.token) }) { res async in
                    #expect(res.status == .forbidden)
                }
                let conversation = try AIConversation(
                    userId: free.userId,
                    titleEncrypted: app.userPIIEncryptionService.encryptString("DD"),
                    expiresAt: Date().addingTimeInterval(3600)
                )
                try await conversation.create(on: app.db)
                let conversationId = try conversation.requireID()
                try await app.testing().test(.POST, "v1/ai/assistant/conversations/\(conversationId)/chat", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: free.token)
                    try req.content.encode(["content": "/dd GRAB"])
                }) { res async in
                    #expect(res.status == .forbidden)
                }
                #expect(try await PositionMemo.query(on: app.db).count() == 0)
            }
        }
    }
}
