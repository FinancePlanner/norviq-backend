import Fluent
import FluentSQL
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// Feature writes queue a live achievement check for the right user, through
/// the real routes. The primary signal is the user's
/// `achievement_evaluations.last_evaluated_at`; an unlock is asserted only
/// where the hooked write itself qualifies. Also: invite redemptions and the
/// social activity migration.
@Suite("Achievement hook sites", .serialized)
struct AchievementHookSitesTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("ACHIEVEMENTS_ENABLED", "1", 1)
            setenv("SOCIAL_ENABLED", "1", 1)
            setenv("SOCIAL_CONTACT_PEPPER", "test-pepper", 1)
            setenv("SOCIAL_INVITE_BASE_URL", "https://norviq.test", 1)
            setenv("ARTICLES_ENABLED", "true", 1)
            setenv("NORVIQ_ADMIN_USER_IDS", "", 1)
            let previousDelay = AchievementHooks.delay
            AchievementHooks.delay = .zero
            defer {
                AchievementHooks.delay = previousDelay
                for key in [
                    "ACHIEVEMENTS_ENABLED", "SOCIAL_ENABLED", "SOCIAL_CONTACT_PEPPER",
                    "SOCIAL_INVITE_BASE_URL", "ARTICLES_ENABLED", "NORVIQ_ADMIN_USER_IDS",
                ] {
                    unsetenv(key)
                }
            }
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                app.articleTickerVerifier = StubTickerVerifier()
                try await app.autoMigrate()
                // Achievements went live long ago, so a freshly registered user is live.
                try await AchievementService.ensureActivated(at: Date(timeIntervalSince1970: 0), on: app.db)
                try await test(app)
                await AchievementHooks.shared.waitUntilIdle()
                try await app.autoRevert()
            } catch {
                await AchievementHooks.shared.waitUntilIdle()
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    // MARK: - Helpers

    private struct Reply {
        let status: HTTPStatus
        let body: Data

        func decode<T: Decodable>(_: T.Type) throws -> T {
            try JSONDecoder.backendAPI.decode(T.self, from: body)
        }
    }

    private func register(_ app: Application, _ id: String) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "achs_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "achs+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
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

    /// Registered and past the community guidelines, so they can post.
    private func member(_ app: Application, _ id: String) async throws -> AuthResponse {
        let auth = try await register(app, id)
        #expect(try await send(app, .POST, "v1/community/guidelines/accept", as: auth).status == .noContent)
        return auth
    }

    private func send(
        _ app: Application, _ method: HTTPMethod, _ path: String, as auth: AuthResponse,
        body: (any Content)? = nil
    ) async throws -> Reply {
        var reply: Reply?
        try await app.testing().test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: auth.token)
            if let body {
                try req.content.encode(body)
            }
        }, afterResponse: { res async throws in
            reply = Reply(status: res.status, body: Data(res.body.readableBytesView))
        })
        return try #require(reply)
    }

    /// Settles whatever earlier steps queued, then forgets every evaluation so
    /// the next assertion sees only what the step under test scheduled.
    private func settleAndForget(_ app: Application) async throws {
        await AchievementHooks.shared.waitUntilIdle()
        try await AchievementEvaluation.query(on: app.db).delete()
    }

    private func evaluated(_ app: Application, _ userId: UUID) async throws -> Bool {
        try await AchievementEvaluation.query(on: app.db)
            .filter(\.$userId == userId)
            .first()?.lastEvaluatedAt != nil
    }

    private func unlocked(_ app: Application, _ userId: UUID, _ key: String, tier: String = "") async throws -> Bool {
        try await UserAchievement.query(on: app.db)
            .filter(\.$user.$id == userId)
            .filter(\.$achievementKey == key)
            .filter(\.$tier == tier)
            .first() != nil
    }

    private func inviteCode(_ app: Application, of auth: AuthResponse) async throws -> String {
        try await send(app, .POST, "v1/social/invites", as: auth).decode(SocialInviteLinkDTO.self).code
    }

    private func setCreatedAt(_ app: Application, _ userId: UUID, daysAgo: Double) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        let createdAt = Date().addingTimeInterval(-daysAgo * 86400)
        try await sql.raw("UPDATE users SET created_at = \(bind: createdAt) WHERE id = \(bind: userId)").run()
    }

    private func redemptions(_ app: Application, invitee: UUID) async throws -> [SocialInviteRedemption] {
        try await SocialInviteRedemption.query(on: app.db).filter(\.$inviteeId == invitee).all()
    }

    // MARK: - Feature hooks

    @Test("Creating an expense evaluates the user")
    func expenseCreate() async throws {
        try await withApp { app in
            let user = try await register(app, "exp")
            try await settleAndForget(app)

            let reply = try await send(app, .POST, "v1/expenses", as: user,
                                       body: ExpenseRequest(title: "Coffee", amount: 4, pillar: .fundamentals, occurredOn: "2026-07-02"))
            #expect(reply.status == .ok || reply.status == .created)
            await AchievementHooks.shared.waitUntilIdle()

            #expect(try await evaluated(app, user.userId))
        }
    }

    @Test("A research note with a thesis unlocks craft.thesis bronze")
    func researchNote() async throws {
        try await withApp { app in
            let user = try await register(app, "note")
            try await settleAndForget(app)

            let note = ResearchNoteRequest(
                symbol: "AAPL", title: "Why", thesis: "Services margin keeps compounding.",
                risks: nil, catalysts: nil, referenceLinks: nil
            )
            #expect(try await send(app, .POST, "v1/research", as: user, body: note).status == .created)
            await AchievementHooks.shared.waitUntilIdle()

            #expect(try await evaluated(app, user.userId))
            #expect(try await unlocked(app, user.userId, "craft.thesis", tier: "bronze"))
        }
    }

    @Test("A check-in evaluates the user")
    func checkIn() async throws {
        try await withApp { app in
            let user = try await register(app, "chk")
            try await settleAndForget(app)

            #expect(try await send(app, .POST, "v1/gamification/check-in", as: user).status == .ok)
            await AchievementHooks.shared.waitUntilIdle()

            #expect(try await evaluated(app, user.userId))
        }
    }

    @Test("An upvote evaluates the post's author, not the voter")
    func boardVote() async throws {
        try await withApp { app in
            let author = try await member(app, "va")
            let voter = try await member(app, "vb")
            let posted = try await send(
                app, .POST, "v1/boards/general/posts", as: author,
                body: CreateBoardPostRequest(kind: .text, title: "A post title", url: nil, body: "Body", tags: [])
            )
            #expect(posted.status == .ok)
            let post = try posted.decode(BoardPostSummary.self)
            // Posting itself is a hook site for the author.
            await AchievementHooks.shared.waitUntilIdle()
            #expect(try await evaluated(app, author.userId))
            #expect(try await unlocked(app, author.userId, "social.first_post"))
            try await settleAndForget(app)

            let vote = try await send(app, .POST, "v1/board-posts/\(post.id)/vote", as: voter).decode(BoardVoteResponse.self)
            #expect(vote.voted)
            await AchievementHooks.shared.waitUntilIdle()

            #expect(try await evaluated(app, author.userId))
            #expect(try await !evaluated(app, voter.userId))
        }
    }

    @Test("Accepting a friend request evaluates both users")
    func friendAccept() async throws {
        try await withApp { app in
            let a = try await register(app, "fa")
            let b = try await register(app, "fb")
            #expect(try await send(app, .POST, "v1/social/friend-requests", as: a,
                                   body: SocialSendFriendRequestBody(userId: b.userId)).status == .ok)
            let incoming = try await send(app, .GET, "v1/social/friend-requests", as: b)
                .decode(SocialFriendRequestsResponse.self).incoming
            let requestId = try #require(incoming.first?.id)
            try await settleAndForget(app)

            #expect(try await send(app, .POST, "v1/social/friend-requests/\(requestId)/accept", as: b).status == .noContent)
            await AchievementHooks.shared.waitUntilIdle()

            #expect(try await evaluated(app, a.userId))
            #expect(try await evaluated(app, b.userId))
            #expect(try await unlocked(app, a.userId, "social.friends", tier: "bronze"))
            #expect(try await unlocked(app, b.userId, "social.friends", tier: "bronze"))
        }
    }

    @Test("A signed-in article view evaluates the reader; a relayed visitor view evaluates no one")
    func articleView() async throws {
        try await withApp { app in
            let author = try await ArticleTestKit.member(app, "achs_author")
            let reader = try await ArticleTestKit.member(app, "achs_reader")
            let web = try await ArticleTestKit.credential(app, owner: author)
            app.articleViewerCredentialIds = [web.id]
            let code = try await ArticleTestKit.publish(app, as: author).article.code
            try await settleAndForget(app)

            let before = AchievementHooks.shared.evaluationsRun
            let visitor: HTTPHeaders = ["X-Norviq-Viewer": "0123456789abcdef0123456789abcdef"]
            let anonymous = try await ArticleTestKit.send(app, .POST, "v1/articles/\(code)/view", token: web.token, headers: visitor)
            #expect(anonymous.status == .noContent)
            await AchievementHooks.shared.waitUntilIdle()
            #expect(try await ArticleView.query(on: app.db).count() == 1)
            #expect(AchievementHooks.shared.evaluationsRun == before)
            #expect(try await AchievementEvaluation.query(on: app.db).count() == 0)

            let viewed = try await ArticleTestKit.send(app, .POST, "v1/articles/\(code)/view", as: reader)
            #expect(viewed.status == .noContent)
            await AchievementHooks.shared.waitUntilIdle()
            #expect(try await evaluated(app, reader.userId))
            #expect(try await !evaluated(app, author.userId))
        }
    }

    // MARK: - Invite redemptions

    @Test("A day-old account redeeming an invite credits the inviter")
    func inviteRedeemedByNewAccount() async throws {
        try await withApp { app in
            let inviter = try await register(app, "inv1")
            let invitee = try await register(app, "inv2")
            try await setCreatedAt(app, invitee.userId, daysAgo: 1)
            let code = try await inviteCode(app, of: inviter)
            try await settleAndForget(app)

            #expect(try await send(app, .POST, "v1/social/invites/\(code)/redeem", as: invitee).status == .ok)
            await AchievementHooks.shared.waitUntilIdle()

            let rows = try await redemptions(app, invitee: invitee.userId)
            #expect(rows.count == 1)
            #expect(rows.first?.inviterId == inviter.userId)
            #expect(try await evaluated(app, inviter.userId))
            #expect(try await unlocked(app, inviter.userId, "social.inviter", tier: "bronze"))

            // Redeeming again credits nobody twice.
            #expect(try await send(app, .POST, "v1/social/invites/\(code)/redeem", as: invitee).status == .ok)
            #expect(try await redemptions(app, invitee: invitee.userId).count == 1)
        }
    }

    @Test("A month-old account redeeming an invite credits no one")
    func inviteRedeemedByOldAccount() async throws {
        try await withApp { app in
            let inviter = try await register(app, "old1")
            let invitee = try await register(app, "old2")
            try await setCreatedAt(app, invitee.userId, daysAgo: 30)
            let code = try await inviteCode(app, of: inviter)

            #expect(try await send(app, .POST, "v1/social/invites/\(code)/redeem", as: invitee).status == .ok)
            await AchievementHooks.shared.waitUntilIdle()

            #expect(try await redemptions(app, invitee: invitee.userId).isEmpty)
            #expect(try await !unlocked(app, inviter.userId, "social.inviter", tier: "bronze"))
        }
    }

    // MARK: - Migration

    @Test("The social activity migration can run twice and adds show_achievements")
    func migrationIsRerunnable() async throws {
        try await withApp { app in
            try await CreateSocialActivityTables().prepare(on: app.db)
            try await CreateSocialActivityTables().revert(on: app.db)
            try await CreateSocialActivityTables().prepare(on: app.db)
            try await CreateSocialActivityTables().prepare(on: app.db)

            let sql = try #require(app.db as? any SQLDatabase)
            let column = try await sql.raw("""
            SELECT column_default FROM information_schema.columns
            WHERE table_schema = current_schema() AND table_name = 'social_settings' AND column_name = 'show_achievements'
            """).first()?.decode(column: "column_default", as: String?.self)
            #expect(column == "true")
            for table in ["social_activity", "social_congrats", "social_invite_redemptions"] {
                let exists = try await sql.raw("SELECT to_regclass(\(bind: table)) IS NOT NULL AS present").first()?
                    .decode(column: "present", as: Bool.self)
                #expect(exists == true, "\(table)")
            }
        }
    }
}
