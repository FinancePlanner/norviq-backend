import Fluent
import Foundation
import StockPlanShared
import Vapor

/// `GET /v1/realtime/stream`: one server-sent-events stream per signed-in
/// client, carrying Groups events. Sending stays on REST; the stream only
/// announces what REST committed.
///
/// There is no replay. Every connection opens with `ready`, and the client
/// catches up over REST (`GET /groups`, `messages?after=<seq>`), which covers
/// reconnects, deploys and a backgrounded app with one code path.
struct RealtimeStreamController: RouteCollection {
    static let heartbeatInterval: Duration = .seconds(20)
    /// Streams close after this and the client reconnects, which bounds
    /// stuck connections and spreads reconnects out.
    static let maxConnectionDuration: Duration = .seconds(600)
    /// How often a connection reloads who is hidden from its user.
    static let hiddenRefreshInterval: TimeInterval = 60

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped(
            ScopedBearerAuthenticator(),
            SessionToken.guardMiddleware(),
            FirstPartyOnlyMiddleware(),
            GroupsEnabledMiddleware(),
            CommunityAccessMiddleware(),
            RateLimitMiddleware(limit: 30, interval: 60, keyPrefix: "ratelimit:realtime-connect")
        )
        .get("realtime", "stream", use: stream)
    }

    @Sendable
    func stream(req: Request) async throws -> Response {
        let viewer = try req.communityViewer
        let bus = req.application.realtimeBus
        let app = req.application
        let logger = req.logger

        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: .contentType, value: "text/event-stream; charset=utf-8")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        response.headers.replaceOrAdd(name: "X-Accel-Buffering", value: "no")
        // Gzip would hold small frames back until its buffer fills.
        response.headers.responseCompression = .disable
        response.body = .init(managedAsyncStream: { writer in
            let subscription = await bus.subscribe(userId: viewer.userId)
            let continuation = subscription.continuation
            let clock = Task {
                let start = ContinuousClock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.heartbeatInterval)
                    if ContinuousClock.now - start >= Self.maxConnectionDuration {
                        continuation.yield(.reconnect)
                        continuation.finish()
                        return
                    }
                    continuation.yield(.heartbeat)
                }
            }

            do {
                try await SSE.writeRetry(milliseconds: 2000, to: writer)
                let ready = GroupRealtimeEvent(type: .ready, serverTime: Date())
                try await SSE.writeFrame(event: GroupRealtimeEventType.ready.rawValue, encodedData: Self.encode(ready), to: writer)

                var hidden = try await SocialService.blockedEitherWay(for: viewer.userId, on: app.db)
                var hiddenLoadedAt = Date()
                for await signal in subscription.stream {
                    switch signal {
                    case .heartbeat:
                        try await SSE.writeComment("ping", to: writer)
                    case .reconnect:
                        try await SSE.writeFrame(event: GroupRealtimeEventType.reconnect.rawValue, encodedData: "{}", to: writer)
                    case let .event(envelope):
                        if Date().timeIntervalSince(hiddenLoadedAt) > Self.hiddenRefreshInterval {
                            hidden = try await SocialService.blockedEitherWay(for: viewer.userId, on: app.db)
                            hiddenLoadedAt = Date()
                        }
                        if let author = envelope.authorId, hidden.contains(author) {
                            continue
                        }
                        try await SSE.writeFrame(event: envelope.event, encodedData: envelope.data, to: writer)
                    }
                }
            } catch {
                // A write failing means the client went away; anything else is
                // logged, and the client reconnects either way.
                logger.debug("realtime.stream closed error=\(String(reflecting: type(of: error)))")
            }
            clock.cancel()
            await bus.unsubscribe(subscription)
        })
        return response
    }

    static func encode(_ event: GroupRealtimeEvent) -> String {
        (try? JSONEncoder.backendAPI.encode(event)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// Publishes Groups events to the people who should see them. Called after
/// the change is committed.
enum GroupsRealtime {
    /// To every member of `groupId`.
    static func publish(_ event: GroupRealtimeEvent, toMembersOf groupId: UUID, authorId: UUID? = nil, on req: Request) async {
        do {
            let members = try await GroupMemberRecord.query(on: req.db).filter(\.$groupId == groupId).all().map(\.userId)
            await publish(event, to: Set(members), authorId: authorId, on: req)
        } catch {
            req.logger.warning("groups.realtime members lookup failed error=\(String(reflecting: type(of: error)))")
        }
    }

    static func publish(_ event: GroupRealtimeEvent, to userIds: Set<UUID>, authorId: UUID? = nil, on req: Request) async {
        guard !userIds.isEmpty else { return }
        let envelope = RealtimeEnvelope(
            event: event.type.rawValue,
            data: RealtimeStreamController.encode(event),
            authorId: authorId
        )
        await req.application.realtimeBus.publish(envelope, to: userIds)
    }
}
