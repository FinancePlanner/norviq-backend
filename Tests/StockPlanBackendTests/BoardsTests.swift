import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Community validation")
struct CommunityValidationTests {
    @Test("Slugs are lowercased, bounded and not reserved")
    func slugs() throws {
        #expect(try CommunityValidation.slug("  DCA-Club ") == "dca-club")
        #expect(throws: (any Error).self) { try CommunityValidation.slug("ab") }
        #expect(throws: (any Error).self) { try CommunityValidation.slug("admin") }
        #expect(throws: (any Error).self) { try CommunityValidation.slug("activity") }
        #expect(throws: (any Error).self) { try CommunityValidation.slug("-lead") }
        #expect(throws: (any Error).self) { try CommunityValidation.slug("no spaces") }
        #expect(throws: (any Error).self) { try CommunityValidation.slug("ação") }
    }

    @Test("Tags drop '#', dedupe, keep order and cap at five")
    func tags() throws {
        #expect(try CommunityValidation.tags(["#ETF", "dca", "etf", " "]) == ["etf", "dca"])
        #expect(throws: (any Error).self) { try CommunityValidation.tags(["a", "b", "c", "d", "e", "f"]) }
        #expect(throws: (any Error).self) { try CommunityValidation.tags(["bad tag"]) }
    }

    @Test("Links need http(s) and a host; the domain drops www.")
    func links() throws {
        #expect(try CommunityValidation.link("https://www.Example.com/a?b=1").domain == "example.com")
        #expect(try CommunityValidation.link("http://sub.example.org").domain == "sub.example.org")
        #expect(throws: (any Error).self) { try CommunityValidation.link("javascript:alert(1)") }
        #expect(throws: (any Error).self) { try CommunityValidation.link("https://localhost") }
        #expect(throws: (any Error).self) { try CommunityValidation.link("https://user@example.com") }
        #expect(throws: (any Error).self) { try CommunityValidation.link(nil) }
    }
}

/// Boards against a real database: creation limits, posts, votes, threads,
/// sorting, blocks, reports, and admin moderation.
@Suite("Boards routes", .serialized)
struct BoardsRouteTests {
    static let adminEmail = "brd+admin@example.com"

    private func withApp(admins: String? = BoardsRouteTests.adminEmail, _ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            if let admins {
                setenv("NORVIQ_ADMIN_EMAILS", admins, 1)
            } else {
                unsetenv("NORVIQ_ADMIN_EMAILS")
            }
            unsetenv("INSIGHTS_ADMIN_EMAILS")
            unsetenv("SOCIAL_MODERATOR_EMAILS")
            defer { unsetenv("NORVIQ_ADMIN_EMAILS") }
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

    // MARK: - Helpers

    private struct Reply {
        let status: HTTPStatus
        let body: Data

        func decode<T: Decodable>(_: T.Type) throws -> T {
            try JSONDecoder.backendAPI.decode(T.self, from: body)
        }

        var code: String? {
            try? decode(APIErrorEnvelope.self).code
        }
    }

    private func register(_ app: Application, _ id: String) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "brd_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "brd+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
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

    private func send(
        _ app: Application,
        _ method: HTTPMethod,
        _ path: String,
        as auth: AuthResponse,
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

    /// A user who has accepted the guidelines and can post.
    private func member(_ app: Application, _ id: String) async throws -> AuthResponse {
        let auth = try await register(app, id)
        #expect(try await send(app, .POST, "v1/community/guidelines/accept", as: auth).status == .noContent)
        return auth
    }

    private func createBoard(_ app: Application, _ slug: String, as auth: AuthResponse) async throws -> Reply {
        try await send(app, .POST, "v1/boards", as: auth, body: CreateBoardRequest(slug: slug, name: "Board \(slug)", description: "About \(slug)"))
    }

    private func createPost(
        _ app: Application,
        _ slug: String,
        as auth: AuthResponse,
        kind: BoardPostKind = .text,
        title: String = "A post title",
        url: String? = nil,
        tags: [String] = []
    ) async throws -> BoardPostSummary {
        let reply = try await send(
            app, .POST, "v1/boards/\(slug)/posts", as: auth,
            body: CreateBoardPostRequest(kind: kind, title: title, url: url, body: kind == .link ? nil : "Body", tags: tags)
        )
        #expect(reply.status == .ok)
        return try reply.decode(BoardPostSummary.self)
    }

    private func comment(
        _ app: Application, _ postId: UUID, as auth: AuthResponse, parent: UUID? = nil
    ) async throws -> Reply {
        try await send(app, .POST, "v1/board-posts/\(postId)/comments", as: auth, body: CreateBoardCommentRequest(parentId: parent, body: "A reply"))
    }

    private func list(_ app: Application, _ query: String, as auth: AuthResponse) async throws -> BoardPostPage {
        let reply = try await send(app, .GET, "v1/boards/\(query)", as: auth)
        #expect(reply.status == .ok)
        return try reply.decode(BoardPostPage.self)
    }

    private func sanction(
        _ app: Application, _ username: String, _ kind: CommunitySanctionKind, as admin: AuthResponse, hours: Int? = nil
    ) async throws -> Reply {
        try await send(
            app, .POST, "v1/admin/community/sanctions", as: admin,
            body: CreateSanctionRequest(username: username, kind: kind, reason: "Testing", durationHours: hours)
        )
    }

    // MARK: - Boards

    @Test("Posting needs accepted guidelines; boards are capped at three a day")
    func boardCreation() async throws {
        try await withApp { app in
            let fresh = try await register(app, "fresh")
            let blocked = try await createBoard(app, "early", as: fresh)
            #expect(blocked.status == .forbidden)
            #expect(blocked.code == "guidelines_required")

            let alice = try await member(app, "alice")
            for slug in ["one", "two", "three"] {
                #expect(try await createBoard(app, "b-\(slug)", as: alice).status == .ok)
            }
            let fourth = try await createBoard(app, "b-four", as: alice)
            #expect(fourth.status == .tooManyRequests)
            #expect(fourth.code == "board_limit_reached")

            let bob = try await member(app, "bob")
            #expect(try await createBoard(app, "b-one", as: bob).status == .conflict)
            #expect(try await createBoard(app, "admin", as: bob).status == .badRequest)

            let boards = try await send(app, .GET, "v1/boards", as: bob).decode(BoardListResponse.self)
            #expect(boards.items.count == 3)
            #expect(boards.items.allSatisfy { $0.creatorUsername == "brd_alice" })
        }
    }

    // MARK: - Posts and votes

    @Test("Link posts keep their domain; votes toggle and the score follows")
    func postsAndVotes() async throws {
        try await withApp { app in
            let alice = try await member(app, "alice")
            let bob = try await member(app, "bob")
            _ = try await createBoard(app, "dca", as: alice)

            let link = try await createPost(app, "dca", as: alice, kind: .link, title: "DCA guide", url: "https://www.example.com/dca", tags: ["#DCA"])
            #expect(link.domain == "example.com")
            #expect(link.tags == ["dca"])
            #expect(link.participantCount == 1)

            let textWithURL = try await send(
                app, .POST, "v1/boards/dca/posts", as: alice,
                body: CreateBoardPostRequest(kind: .text, title: "Text post", url: "https://example.com", body: nil, tags: [])
            )
            #expect(textWithURL.status == .badRequest)

            let first = try await send(app, .POST, "v1/board-posts/\(link.id)/vote", as: bob).decode(BoardVoteResponse.self)
            #expect(first == BoardVoteResponse(score: 1, voted: true))
            let page = try await list(app, "dca/posts", as: bob)
            #expect(page.items.first?.viewerHasVoted == true)
            let second = try await send(app, .POST, "v1/board-posts/\(link.id)/vote", as: bob).decode(BoardVoteResponse.self)
            #expect(second == BoardVoteResponse(score: 0, voted: false))
        }
    }

    @Test("New, top and active sorts, plus kind and tag filters")
    func sortingAndFilters() async throws {
        try await withApp { app in
            let alice = try await member(app, "alice")
            let bob = try await member(app, "bob")
            _ = try await createBoard(app, "etfs", as: alice)

            let older = try await createPost(app, "etfs", as: alice, title: "Older post", tags: ["vanguard"])
            let ask = try await createPost(app, "etfs", as: alice, kind: .ask, title: "Ask: which ETF?")
            let newest = try await createPost(app, "etfs", as: alice, kind: .show, title: "Show: my allocation")

            #expect(try await list(app, "etfs/posts?sort=new", as: bob).items.map(\.id) == [newest.id, ask.id, older.id])

            _ = try await send(app, .POST, "v1/board-posts/\(older.id)/vote", as: bob)
            #expect(try await list(app, "etfs/posts?sort=top", as: bob).items.first?.id == older.id)

            #expect(try await comment(app, ask.id, as: bob).status == .ok)
            #expect(try await list(app, "etfs/posts?sort=active", as: bob).items.first?.id == ask.id)

            #expect(try await list(app, "etfs/posts?kind=ask", as: bob).items.map(\.id) == [ask.id])
            #expect(try await list(app, "etfs/posts?kind=show", as: bob).items.map(\.id) == [newest.id])
            #expect(try await list(app, "etfs/posts?tag=Vanguard", as: bob).items.map(\.id) == [older.id])
        }
    }

    // MARK: - Comments

    @Test("Threads cap at depth 8; participants count people; 'new' counts others' comments")
    func comments() async throws {
        try await withApp { app in
            let alice = try await member(app, "alice")
            let bob = try await member(app, "bob")
            _ = try await createBoard(app, "threads", as: alice)
            let post = try await createPost(app, "threads", as: alice)

            // Alice opens her post, so later comments are "new" to her.
            #expect(try await send(app, .GET, "v1/board-posts/\(post.id)", as: alice).status == .ok)

            var parent: UUID?
            for depth in 0 ... CommunityValidation.maxCommentDepth {
                let reply = try await comment(app, post.id, as: depth.isMultiple(of: 2) ? bob : alice, parent: parent)
                #expect(reply.status == .ok)
                let created = try reply.decode(BoardComment.self)
                #expect(created.depth == depth)
                parent = created.id
            }
            #expect(try await comment(app, post.id, as: bob, parent: parent).status == .badRequest)

            let detail = try await send(app, .GET, "v1/board-posts/\(post.id)", as: alice).decode(BoardPostDetail.self)
            #expect(detail.comments.count == CommunityValidation.maxCommentDepth + 1)
            #expect(detail.post.commentCount == 9)
            // Alice (author) and Bob.
            #expect(detail.post.participantCount == 2)
            // Bob wrote 5 of the 9; Alice's own 4 are not news to her.
            #expect(detail.post.newCommentCount == 5)
            // Only Alice has opened it; repeat visits do not count.
            #expect(detail.post.viewCount == 1)

            let again = try await send(app, .GET, "v1/board-posts/\(post.id)", as: alice).decode(BoardPostDetail.self)
            #expect(again.post.newCommentCount == 0)

            // Deleted comments keep their slot.
            let first = try #require(detail.comments.first)
            #expect(try await send(app, .DELETE, "v1/board-comments/\(first.id)", as: alice).status == .forbidden)
            #expect(try await send(app, .DELETE, "v1/board-comments/\(first.id)", as: bob).status == .noContent)
            let afterDelete = try await send(app, .GET, "v1/board-posts/\(post.id)", as: alice).decode(BoardPostDetail.self)
            let gone = try #require(afterDelete.comments.first { $0.id == first.id })
            #expect(gone.isDeleted)
            #expect(gone.body.isEmpty)
            #expect(gone.authorUsername == nil)
        }
    }

    // MARK: - Moderation

    @Test("A mute blocks writing but not reading or reporting; an expired mute is ignored")
    func mute() async throws {
        try await withApp { app in
            let admin = try await register(app, "admin")
            let alice = try await member(app, "alice")
            let troll = try await member(app, "troll")
            _ = try await createBoard(app, "general", as: alice)
            let post = try await createPost(app, "general", as: alice)

            #expect(try await sanction(app, "brd_troll", .mute, as: admin, hours: 24).status == .ok)
            let blocked = try await send(
                app, .POST, "v1/boards/general/posts", as: troll,
                body: CreateBoardPostRequest(kind: .text, title: "Spam spam", url: nil, body: nil, tags: [])
            )
            #expect(blocked.status == .forbidden)
            #expect(blocked.code == "community_muted")
            #expect(try await comment(app, post.id, as: troll).code == "community_muted")
            #expect(try await send(app, .POST, "v1/board-posts/\(post.id)/vote", as: troll).code == "community_muted")
            #expect(try await send(app, .GET, "v1/boards/general/posts", as: troll).status == .ok)
            let report = BoardReportRequest(postId: post.id, commentId: nil, reason: .spam, note: nil)
            #expect(try await send(app, .POST, "v1/board-reports", as: troll, body: report).status == .accepted)

            let status = try await send(app, .GET, "v1/community/me", as: troll).decode(CommunityViewerStatus.self)
            #expect(status.activeSanction?.kind == .mute)
            #expect(status.activeSanction?.expiresAt != nil)

            // Age the mute out.
            let row = try #require(try await CommunitySanction.query(on: app.db).first())
            row.expiresAt = Date().addingTimeInterval(-60)
            try await row.save(on: app.db)
            #expect(try await comment(app, post.id, as: troll).status == .ok)
        }
    }

    @Test("A ban hides boards except the status route; lifting it restores access")
    func ban() async throws {
        try await withApp { app in
            let admin = try await register(app, "admin")
            let alice = try await member(app, "alice")
            _ = try await createBoard(app, "general", as: alice)

            let issued = try await sanction(app, "brd_alice", .ban, as: admin)
            #expect(issued.status == .ok)
            let ban = try issued.decode(UserSanction.self)
            #expect(ban.expiresAt == nil)

            let denied = try await send(app, .GET, "v1/boards", as: alice)
            #expect(denied.status == .forbidden)
            #expect(denied.code == "community_banned")
            let me = try await send(app, .GET, "v1/community/me", as: alice)
            #expect(me.status == .ok)
            #expect(try me.decode(CommunityViewerStatus.self).activeSanction?.kind == .ban)

            let log = try await send(app, .GET, "v1/admin/community/sanctions", as: admin).decode(UserSanctionListResponse.self)
            #expect(log.items.map(\.username) == ["brd_alice"])

            #expect(try await send(app, .DELETE, "v1/admin/community/sanctions/\(ban.id)", as: admin).status == .noContent)
            #expect(try await send(app, .GET, "v1/boards", as: alice).status == .ok)
        }
    }

    @Test("Admin routes are admin-only, and admins can't be sanctioned")
    func adminGate() async throws {
        try await withApp { app in
            let admin = try await register(app, "admin")
            let alice = try await member(app, "alice")
            _ = try await createBoard(app, "general", as: alice)

            #expect(try await send(app, .DELETE, "v1/admin/boards/general", as: alice).status == .forbidden)
            #expect(try await sanction(app, "brd_admin", .ban, as: alice).status == .forbidden)
            #expect(try await sanction(app, "brd_admin", .ban, as: admin).status == .badRequest)

            let status = try await send(app, .GET, "v1/community/me", as: admin).decode(CommunityViewerStatus.self)
            #expect(status.isAdmin)
        }
    }

    @Test("A social suspension removes Boards like a ban, and lifting it restores them")
    func socialSuspensionActsAsBan() async throws {
        try await withApp { app in
            let alice = try await member(app, "alice")
            let user = try #require(try await User.query(on: app.db).filter(\.$username == "brd_alice").first())
            try await SocialModerationController.setSuspended(user.requireID(), suspended: true, on: app.db)

            let denied = try await send(app, .GET, "v1/boards", as: alice)
            #expect(denied.status == .forbidden)
            #expect(denied.code == "community_banned")
            let status = try await send(app, .GET, "v1/community/me", as: alice).decode(CommunityViewerStatus.self)
            #expect(status.activeSanction?.kind == .ban)
            #expect(status.activeSanction?.expiresAt == nil)

            try await SocialModerationController.setSuspended(user.requireID(), suspended: false, on: app.db)
            #expect(try await send(app, .GET, "v1/boards", as: alice).status == .ok)
        }
    }

    @Test("One admin list: the legacy social moderator list grants Boards admin too")
    func legacyModeratorListIsAdmin() async throws {
        try await withApp(admins: nil) { app in
            setenv("SOCIAL_MODERATOR_EMAILS", Self.adminEmail, 1)
            defer { unsetenv("SOCIAL_MODERATOR_EMAILS") }
            let admin = try await register(app, "admin")
            #expect(try await send(app, .GET, "v1/admin/community/sanctions", as: admin).status == .ok)
            #expect(try await send(app, .GET, "v1/admin/social/reports", as: admin).status == .ok)

            // NORVIQ_ADMIN_EMAILS, once set, is the whole list.
            setenv("NORVIQ_ADMIN_EMAILS", "someone-else@example.com", 1)
            #expect(try await send(app, .GET, "v1/admin/social/reports", as: admin).status == .forbidden)
        }
    }

    @Test("With no admin list configured, nobody is an admin")
    func adminFailsClosed() async throws {
        try await withApp(admins: nil) { app in
            let admin = try await register(app, "admin")
            #expect(try await send(app, .GET, "v1/admin/community/sanctions", as: admin).status == .forbidden)
        }
    }

    @Test("Deleting a board hides it and its posts; admins can delete anyone's post")
    func adminDeletes() async throws {
        try await withApp { app in
            let admin = try await register(app, "admin")
            let alice = try await member(app, "alice")
            _ = try await createBoard(app, "doomed", as: alice)
            _ = try await createBoard(app, "kept", as: alice)
            let doomedPost = try await createPost(app, "doomed", as: alice)
            let keptPost = try await createPost(app, "kept", as: alice)

            #expect(try await send(app, .DELETE, "v1/board-posts/\(keptPost.id)", as: admin).status == .noContent)
            #expect(try await list(app, "kept/posts", as: alice).items.isEmpty)
            #expect(try await send(app, .GET, "v1/boards/kept", as: alice).decode(BoardSummary.self).postCount == 0)

            #expect(try await send(app, .DELETE, "v1/admin/boards/doomed", as: admin).status == .noContent)
            #expect(try await send(app, .GET, "v1/boards/doomed", as: alice).status == .notFound)
            #expect(try await send(app, .GET, "v1/board-posts/\(doomedPost.id)", as: alice).status == .notFound)
            // The address stays taken.
            #expect(try await createBoard(app, "doomed", as: alice).status == .conflict)
            let boards = try await send(app, .GET, "v1/boards", as: alice).decode(BoardListResponse.self)
            #expect(boards.items.map(\.slug) == ["kept"])
        }
    }

    // MARK: - Safety

    @Test("Blocking hides the other person's posts; reports reach the admin queue")
    func blocksAndReports() async throws {
        try await withApp { app in
            let admin = try await register(app, "admin")
            let alice = try await member(app, "alice")
            let bob = try await member(app, "bob")
            _ = try await createBoard(app, "general", as: alice)
            let bobPost = try await createPost(app, "general", as: bob, title: "Bob's take")
            _ = try await createPost(app, "general", as: alice, title: "Alice's take")

            #expect(try await send(app, .POST, "v1/community/blocks", as: alice, body: UserBlockRequest(username: "@brd_bob")).status == .noContent)
            #expect(try await list(app, "general/posts", as: alice).items.map(\.title) == ["Alice's take"])
            // Either direction.
            #expect(try await list(app, "general/posts", as: bob).items.map(\.title) == ["Bob's take"])
            #expect(try await send(app, .GET, "v1/board-posts/\(bobPost.id)", as: alice).status == .notFound)

            #expect(try await send(app, .DELETE, "v1/community/blocks/brd_bob", as: alice).status == .noContent)
            #expect(try await list(app, "general/posts", as: alice).items.count == 2)

            let report = BoardReportRequest(postId: bobPost.id, commentId: nil, reason: .harassment, note: "Not nice")
            #expect(try await send(app, .POST, "v1/board-reports", as: alice, body: report).status == .accepted)
            let both = BoardReportRequest(postId: bobPost.id, commentId: bobPost.id, reason: .spam, note: nil)
            #expect(try await send(app, .POST, "v1/board-reports", as: alice, body: both).status == .badRequest)

            let queue = try await send(app, .GET, "v1/admin/community/reports", as: admin).decode(BoardReportListResponse.self)
            let item = try #require(queue.items.first)
            #expect(queue.items.count == 1)
            #expect(item.excerpt == "Bob's take")
            #expect(item.boardSlug == "general")
            #expect(item.targetAuthorUsername == "brd_bob")
            #expect(item.reporterUsername == "brd_alice")

            #expect(try await send(app, .POST, "v1/admin/community/reports/\(item.id)/resolve", as: admin).status == .noContent)
            #expect(try await send(app, .GET, "v1/admin/community/reports", as: admin).decode(BoardReportListResponse.self).items.isEmpty)
        }
    }
}
