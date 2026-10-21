import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Realtime bus")
struct RealtimeBusTests {
    private func envelope(_ name: String) -> RealtimeEnvelope {
        RealtimeEnvelope(event: name, data: "{}", authorId: nil)
    }

    @Test("Events reach every connection of the addressed users only")
    func routing() async {
        let bus = InProcessRealtimeBus()
        let (ana, bo) = (UUID(), UUID())
        let phone = await bus.subscribe(userId: ana)
        let laptop = await bus.subscribe(userId: ana)
        let other = await bus.subscribe(userId: bo)
        await bus.publish(envelope("message.created"), to: [ana])
        await bus.finishAll()

        #expect(await collect(phone.stream) == [.event(envelope("message.created"))])
        #expect(await collect(laptop.stream) == [.event(envelope("message.created"))])
        #expect(await collect(other.stream).isEmpty)
    }

    @Test("A sixth connection closes the oldest")
    func connectionCap() async {
        let bus = InProcessRealtimeBus()
        let user = UUID()
        var subscriptions: [RealtimeSubscription] = []
        for _ in 0 ... InProcessRealtimeBus.maxConnectionsPerUser {
            await subscriptions.append(bus.subscribe(userId: user))
        }
        #expect(await bus.connectionCount(userId: user) == InProcessRealtimeBus.maxConnectionsPerUser)
        // The first stream is finished, so collecting it returns at once.
        #expect(await collect(subscriptions[0].stream).isEmpty)
        await bus.unsubscribe(subscriptions[1])
        #expect(await bus.connectionCount(userId: user) == InProcessRealtimeBus.maxConnectionsPerUser - 1)
        await bus.finishAll()
        #expect(await bus.connectionCount(userId: user) == 0)
    }

    private func collect(_ stream: AsyncStream<RealtimeSignal>) async -> [RealtimeSignal] {
        var signals: [RealtimeSignal] = []
        for await signal in stream {
            signals.append(signal)
        }
        return signals
    }
}

/// Records group pushes; every other kind is a no-op.
private final class GroupPushRecorder: PushNotificationSending, @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [(message: GroupPushMessage, devices: Int)] = []

    var messages: [GroupPushMessage] {
        lock.withLock { _messages.map(\.message) }
    }

    func sendGroupEvent(message: GroupPushMessage, devices: [PushDevice], req _: Request) async -> TargetPushSendSummary {
        lock.withLock { _messages.append((message, devices.count)) }
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

/// Live events and push from the Groups routes.
@Suite("Groups realtime and push", .serialized)
struct GroupsRealtimeRouteTests {
    private func withApp(_ test: (Application, GroupPushRecorder) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("SOCIAL_ENABLED", "1", 1)
            setenv("GROUPS_ENABLED", "1", 1)
            defer {
                unsetenv("SOCIAL_ENABLED")
                unsetenv("GROUPS_ENABLED")
            }
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                let recorder = GroupPushRecorder()
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

    private func register(_ app: Application, _ id: String) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "grt_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "grt+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            response = try res.content.decode(AuthResponse.self)
        })
        let auth = try #require(response)
        #expect(try await send(app, .POST, "v1/community/guidelines/accept", as: auth).status == .noContent)
        try await PushDevice(
            userId: auth.userId,
            deviceToken: "token-grt-\(id)",
            platform: PushPlatform.ios.rawValue,
            apnsEnvironment: PushAPNSEnvironment.development.rawValue,
            authorizationStatus: PushAuthorizationStatus.authorized.rawValue,
            isActive: true,
            lastSeenAt: Date()
        ).save(on: app.db)
        return auth
    }

    private func send(
        _ app: Application,
        _ method: HTTPMethod,
        _ path: String,
        as auth: AuthResponse,
        body: (any Content)? = nil
    ) async throws -> (status: HTTPStatus, body: Data) {
        var result: (HTTPStatus, Data)?
        try await app.testing().test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: auth.token)
            if let body {
                try req.content.encode(body)
            }
        }, afterResponse: { res async throws in
            result = (res.status, Data(res.body.readableBytesView))
        })
        return try #require(result)
    }

    /// The next forwarded event on `subscription`, or nil after a second.
    private func nextEvent(_ subscription: RealtimeSubscription) async -> RealtimeEnvelope? {
        let timeout = Task {
            guard await (try? Task.sleep(for: .seconds(1))) != nil else { return }
            subscription.continuation.finish()
        }
        defer { timeout.cancel() }
        for await signal in subscription.stream {
            if case let .event(envelope) = signal {
                return envelope
            }
        }
        return nil
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0 ..< 40 where !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("A message reaches other members live, and pushes them once per minute")
    func messageFanOut() async throws {
        try await withApp { app, recorder in
            let ana = try await register(app, "ana")
            let bo = try await register(app, "bo")
            let created = try await send(app, .POST, "v1/groups", as: ana, body: CreateGroupRequest(
                name: "Dividend club", description: nil, iconEmoji: nil, topic: .community, ticker: nil, visibility: .private
            ))
            let group = try JSONDecoder.backendAPI.decode(GroupDetail.self, from: created.body)
            let channelId = try #require(group.channels.first?.id)
            let link = try await JSONDecoder.backendAPI.decode(
                GroupInviteLink.self,
                from: send(app, .POST, "v1/groups/\(group.group.id)/invites", as: ana, body: CreateGroupInviteRequest.default).body
            )
            #expect(try await send(app, .POST, "v1/group-invites/\(link.code)/redeem", as: bo).status == .ok)

            let live = await app.realtimeBus.subscribe(userId: bo.userId)
            let sent = try await send(
                app, .POST, "v1/group-channels/\(channelId)/messages", as: ana,
                body: SendGroupMessageRequest(clientMessageId: "rt-1", body: "Ex-div date is Friday")
            )
            #expect(sent.status == .created)
            let envelope = try #require(await nextEvent(live))
            #expect(envelope.event == "message.created")
            #expect(envelope.authorId == ana.userId)
            let event = try JSONDecoder.backendAPI.decode(GroupRealtimeEvent.self, from: Data(envelope.data.utf8))
            #expect(event.message?.body == "Ex-div date is Friday")
            #expect(event.channelId == channelId)
            await app.realtimeBus.unsubscribe(live)

            await waitFor { !recorder.messages.isEmpty }
            let push = try #require(recorder.messages.first)
            #expect(push.kind == .message)
            #expect(push.title == "Dividend club · #general")
            #expect(push.body == "@grt_ana: Ex-div date is Friday")
            #expect(push.deepLink == "financeplan://groups/\(group.group.id.uuidString)/channels/\(channelId.uuidString)")
            #expect(push.threadID == "group-channel-\(channelId.uuidString)")

            // A second message inside the window doesn't push again where
            // Redis is configured; without Redis there's no throttle.
            _ = try await send(
                app, .POST, "v1/group-channels/\(channelId)/messages", as: ana,
                body: SendGroupMessageRequest(clientMessageId: "rt-2", body: "and pays on the 30th")
            )
            try await Task.sleep(for: .milliseconds(500))
            let expected = app.redis.configuration == nil ? 2 : 1
            #expect(recorder.messages.count == expected)
        }
    }

    @Test("Muted members get no push; reading syncs the reader's other devices")
    func pushRulesAndReadSync() async throws {
        try await withApp { app, recorder in
            let ana = try await register(app, "mute")
            let bo = try await register(app, "mutebo")
            let created = try await send(app, .POST, "v1/groups", as: ana, body: CreateGroupRequest(
                name: "Quiet room", description: nil, iconEmoji: nil, topic: .custom, ticker: nil, visibility: .private
            ))
            let group = try JSONDecoder.backendAPI.decode(GroupDetail.self, from: created.body)
            let channelId = try #require(group.channels.first?.id)
            let link = try await JSONDecoder.backendAPI.decode(
                GroupInviteLink.self,
                from: send(app, .POST, "v1/groups/\(group.group.id)/invites", as: ana, body: CreateGroupInviteRequest.default).body
            )
            _ = try await send(app, .POST, "v1/group-invites/\(link.code)/redeem", as: bo)
            #expect(try await send(
                app, .PUT, "v1/groups/\(group.group.id)/notifications", as: bo,
                body: GroupNotificationSettingsRequest(pushEnabled: false)
            ).status == .ok)

            let message = try await JSONDecoder.backendAPI.decode(
                GroupMessage.self,
                from: send(
                    app, .POST, "v1/group-channels/\(channelId)/messages", as: ana,
                    body: SendGroupMessageRequest(clientMessageId: "m-1", body: "hello")
                ).body
            )
            let recipients = try await GroupNotifier.recipients(
                for: message, on: Request(application: app, on: app.eventLoopGroup.next())
            )
            #expect(recipients.isEmpty)
            try await Task.sleep(for: .milliseconds(300))
            #expect(recorder.messages.isEmpty)

            let readerDevice = await app.realtimeBus.subscribe(userId: bo.userId)
            #expect(try await send(
                app, .POST, "v1/group-channels/\(channelId)/read", as: bo, body: MarkGroupChannelReadRequest(seq: 1)
            ).status == .noContent)
            let envelope = try #require(await nextEvent(readerDevice))
            #expect(envelope.event == "channel.read")
            await app.realtimeBus.unsubscribe(readerDevice)
        }
    }
}
