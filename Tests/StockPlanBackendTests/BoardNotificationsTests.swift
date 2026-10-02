import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// Records board pushes; every other kind is a no-op.
private final class BoardPushRecorder: PushNotificationSending, @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [BoardPushMessage] = []
    var messages: [BoardPushMessage] {
        lock.withLock { _messages }
    }

    func sendBoardEvent(message: BoardPushMessage, devices: [PushDevice], req _: Request) async -> TargetPushSendSummary {
        lock.withLock { _messages.append(message) }
        return .init(delivered: devices.count, failed: 0)
    }

    func sendTargetHit(target _: Target, currentPrice _: Double, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
        .init(delivered: 0, failed: 0)
    }

    func sendBudgetAlert(snapshot _: BudgetSnapshot, threshold _: Int, remainingAmount _: Double, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
        .init(delivered: 0, failed: 0)
    }

    func sendEarningsReminder(symbol _: String, earningsDate _: String, leadDays _: Int, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
        .init(delivered: 0, failed: 0)
    }

    func sendTaxOpportunity(opportunity _: TaxOpportunityResponse, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
        .init(delivered: 0, failed: 0)
    }

    func sendAutomationAlert(message _: AutomationPushMessage, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
        .init(delivered: 0, failed: 0)
    }

    func sendRebalancingDrift(alert _: RebalancingAlert, portfolioName _: String, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
        .init(delivered: 0, failed: 0)
    }
}

@Suite("Board notifications", .serialized)
struct BoardNotificationsTests {
    private func withApp(_ test: (Application, BoardPushRecorder) async throws -> Void) async throws {
        try await DatabaseTestLock.withSharedAccess {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                let recorder = BoardPushRecorder()
                app.pushNotificationSender = recorder
                try await test(app, recorder)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private struct Reply {
        let status: HTTPStatus
        let body: Data

        func decode<T: Decodable>(_: T.Type) throws -> T {
            try JSONDecoder.backendAPI.decode(T.self, from: body)
        }
    }

    /// A user with accepted guidelines and a registered iPhone.
    private func member(_ app: Application, _ id: String) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "bn_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "bn+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var auth: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            auth = try res.content.decode(AuthResponse.self)
        })
        let member = try #require(auth)
        #expect(try await send(app, .POST, "v1/community/guidelines/accept", as: member).status == .noContent)
        let user = try #require(try await User.query(on: app.db).filter(\.$username == "bn_\(id)").first())
        try await PushDevice(
            userId: user.requireID(),
            deviceToken: "token-\(id)",
            platform: PushPlatform.ios.rawValue,
            apnsEnvironment: PushAPNSEnvironment.development.rawValue,
            authorizationStatus: PushAuthorizationStatus.authorized.rawValue,
            isActive: true,
            lastSeenAt: Date()
        ).save(on: app.db)
        return member
    }

    private func send(
        _ app: Application, _ method: HTTPMethod, _ path: String, as auth: AuthResponse, body: (any Content)? = nil
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

    private func post(_ app: Application, as auth: AuthResponse) async throws -> BoardPostSummary {
        _ = try await send(app, .POST, "v1/boards", as: auth, body: CreateBoardRequest(slug: "notify", name: "Notify", description: ""))
        let reply = try await send(
            app, .POST, "v1/boards/notify/posts", as: auth,
            body: CreateBoardPostRequest(kind: .text, title: "Ana's post", url: nil, body: "Body", tags: [])
        )
        #expect(reply.status == .ok)
        return try reply.decode(BoardPostSummary.self)
    }

    private func comment(
        _ app: Application, _ postId: UUID, as auth: AuthResponse, parent: UUID? = nil, text: String = "Nice post"
    ) async throws -> BoardComment {
        let reply = try await send(
            app, .POST, "v1/board-posts/\(postId)/comments", as: auth, body: CreateBoardCommentRequest(parentId: parent, body: text)
        )
        #expect(reply.status == .ok)
        return try reply.decode(BoardComment.self)
    }

    private func feed(_ app: Application, as auth: AuthResponse) async throws -> BoardNotificationPage {
        try await send(app, .GET, "v1/community/notifications", as: auth).decode(BoardNotificationPage.self)
    }

    @Test("A comment notifies the post's author; a reply notifies the comment's author, never yourself")
    func replies() async throws {
        try await withApp { app, pushes in
            let ana = try await member(app, "ana")
            let bo = try await member(app, "bo")
            let post = try await post(app, as: ana)

            let first = try await comment(app, post.id, as: bo, text: "Great point")
            _ = try await comment(app, post.id, as: ana, parent: first.id, text: "Thanks!")
            _ = try await comment(app, post.id, as: ana, text: "Talking to myself")

            let anaFeed = try await feed(app, as: ana)
            #expect(anaFeed.items.map(\.kind) == [.reply])
            #expect(anaFeed.items.first?.actorUsername == "bn_bo")
            #expect(anaFeed.items.first?.excerpt == "Great point")
            #expect(anaFeed.items.first?.boardSlug == "notify")
            #expect(anaFeed.unreadCount == 1)

            let boFeed = try await feed(app, as: bo)
            #expect(boFeed.items.map(\.excerpt) == ["Thanks!"])

            #expect(pushes.messages.map(\.title) == ["@bn_bo commented on your post", "@bn_ana replied to you"])
            #expect(pushes.messages.allSatisfy { $0.kind == .reply && $0.postId == post.id })
            #expect(pushes.messages.first?.deepLink == "financeplan://boards/notify/posts/\(post.id.uuidString)")
        }
    }

    @Test("Upvotes notify once per voter, push at most once an hour per post, and never for your own post")
    func upvotes() async throws {
        try await withApp { app, pushes in
            let ana = try await member(app, "ana")
            let bo = try await member(app, "bo")
            let cy = try await member(app, "cy")
            let post = try await post(app, as: ana)

            for _ in 0 ..< 3 {
                _ = try await send(app, .POST, "v1/board-posts/\(post.id)/vote", as: bo)
            }
            _ = try await send(app, .POST, "v1/board-posts/\(post.id)/vote", as: cy)
            _ = try await send(app, .POST, "v1/board-posts/\(post.id)/vote", as: ana)

            let anaFeed = try await feed(app, as: ana)
            #expect(anaFeed.items.filter { $0.kind == .upvote }.count == 2, "bo once despite toggling, cy once, not ana herself")
            #expect(pushes.messages.count == 1, "the second voter inside the hour is feed-only")
            #expect(pushes.messages.first?.title == "@bn_bo upvoted your post")
        }
    }

    @Test("Push settings silence pushes but the feed still records")
    func settings() async throws {
        try await withApp { app, pushes in
            let ana = try await member(app, "ana")
            let bo = try await member(app, "bo")
            let post = try await post(app, as: ana)

            let initial = try await send(app, .GET, "v1/community/notification-settings", as: ana).decode(BoardNotificationSettings.self)
            #expect(initial == .default)
            let updated = try await send(
                app, .PUT, "v1/community/notification-settings", as: ana,
                body: BoardNotificationSettings(replyPush: false, upvotePush: false)
            ).decode(BoardNotificationSettings.self)
            #expect(updated == BoardNotificationSettings(replyPush: false, upvotePush: false))

            _ = try await comment(app, post.id, as: bo)
            _ = try await send(app, .POST, "v1/board-posts/\(post.id)/vote", as: bo)
            #expect(pushes.messages.isEmpty)
            #expect(try await feed(app, as: ana).items.count == 2)
        }
    }

    @Test("Mark read, unread count, and the feed drops deleted posts and blocked people")
    func readAndHiding() async throws {
        try await withApp { app, _ in
            let ana = try await member(app, "ana")
            let bo = try await member(app, "bo")
            let cy = try await member(app, "cy")
            let post = try await post(app, as: ana)
            _ = try await comment(app, post.id, as: bo)
            _ = try await comment(app, post.id, as: cy)

            var page = try await feed(app, as: ana)
            #expect(page.unreadCount == 2)
            let first = try #require(page.items.first)
            #expect(try await send(app, .POST, "v1/community/notifications/read", as: ana, body: MarkBoardNotificationsReadRequest(ids: [first.id])).status == .noContent)
            #expect(try await send(app, .GET, "v1/community/notifications/unread-count", as: ana).decode(BoardUnreadCount.self).unreadCount == 1)
            #expect(try await send(app, .POST, "v1/community/notifications/read", as: ana, body: MarkBoardNotificationsReadRequest(ids: nil)).status == .noContent)
            page = try await feed(app, as: ana)
            #expect(page.unreadCount == 0)
            let allRead = page.items.allSatisfy(\.isRead)
            #expect(allRead)

            _ = try await send(app, .POST, "v1/community/blocks", as: ana, body: UserBlockRequest(username: "bn_cy"))
            #expect(try await feed(app, as: ana).items.map(\.actorUsername) == ["bn_bo"])

            _ = try await send(app, .DELETE, "v1/board-posts/\(post.id)", as: ana)
            #expect(try await feed(app, as: ana).items.isEmpty)
        }
    }

    @Test("Someone you blocked can't notify you")
    func blockedCannotNotify() async throws {
        try await withApp { app, pushes in
            let ana = try await member(app, "ana")
            let bo = try await member(app, "bo")
            let post = try await post(app, as: ana)
            _ = try await send(app, .POST, "v1/community/blocks", as: ana, body: UserBlockRequest(username: "bn_bo"))
            // Bo can't see the post, so the comment and vote are refused outright.
            #expect(try await send(app, .POST, "v1/board-posts/\(post.id)/comments", as: bo, body: CreateBoardCommentRequest(parentId: nil, body: "hi")).status == .notFound)
            _ = try await send(app, .POST, "v1/board-posts/\(post.id)/vote", as: bo)
            #expect(try await feed(app, as: ana).items.isEmpty)
            #expect(pushes.messages.isEmpty)
        }
    }
}
