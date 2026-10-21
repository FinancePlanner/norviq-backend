import Foundation
import NIOCore
import Vapor

/// One event on a user's realtime stream. `data` is the encoded JSON payload;
/// `authorId` lets each connection drop events from people hidden from it.
struct RealtimeEnvelope: Sendable, Equatable {
    let event: String
    let data: String
    let authorId: UUID?
}

/// What a connection's stream yields: events to forward, plus the
/// connection's own heartbeat and close signals, so one loop handles all of
/// them.
enum RealtimeSignal: Sendable, Equatable {
    case event(RealtimeEnvelope)
    case heartbeat
    case reconnect
}

/// Fans committed changes out to connected clients. Delivery is best effort:
/// a client that misses an event (a full buffer, a deploy, a dropped
/// connection) catches up over REST when its next stream opens, so nothing
/// here needs to be durable.
///
/// The in-process bus is only correct with one API replica. Scaling out needs
/// a Redis-backed bus behind this same protocol.
protocol RealtimeBus: Sendable {
    func subscribe(userId: UUID) async -> RealtimeSubscription
    func unsubscribe(_ subscription: RealtimeSubscription) async
    func publish(_ envelope: RealtimeEnvelope, to userIds: Set<UUID>) async
    /// Ends every open stream, so a shutting-down pod lets its clients
    /// reconnect to the new one straight away.
    func finishAll() async
}

struct RealtimeSubscription: Sendable {
    let userId: UUID
    let connectionId: UUID
    let stream: AsyncStream<RealtimeSignal>
    let continuation: AsyncStream<RealtimeSignal>.Continuation
}

actor InProcessRealtimeBus: RealtimeBus {
    /// A user with more tabs and devices than this loses the oldest one.
    static let maxConnectionsPerUser = 5
    /// A slow client drops the oldest events past this; it catches up over REST.
    static let bufferSize = 256

    private var connections: [UUID: [(id: UUID, continuation: AsyncStream<RealtimeSignal>.Continuation)]] = [:]

    func subscribe(userId: UUID) -> RealtimeSubscription {
        let (stream, continuation) = AsyncStream<RealtimeSignal>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.bufferSize)
        )
        let connectionId = UUID()
        var open = connections[userId] ?? []
        while open.count >= Self.maxConnectionsPerUser {
            open.removeFirst().continuation.finish()
        }
        open.append((connectionId, continuation))
        connections[userId] = open
        return RealtimeSubscription(userId: userId, connectionId: connectionId, stream: stream, continuation: continuation)
    }

    func unsubscribe(_ subscription: RealtimeSubscription) {
        subscription.continuation.finish()
        var open = connections[subscription.userId] ?? []
        open.removeAll { $0.id == subscription.connectionId }
        connections[subscription.userId] = open.isEmpty ? nil : open
    }

    func publish(_ envelope: RealtimeEnvelope, to userIds: Set<UUID>) {
        for userId in userIds {
            for connection in connections[userId] ?? [] {
                connection.continuation.yield(.event(envelope))
            }
        }
    }

    func finishAll() {
        for connection in connections.values.flatMap(\.self) {
            connection.continuation.finish()
        }
        connections.removeAll()
    }

    func connectionCount(userId: UUID) -> Int {
        connections[userId]?.count ?? 0
    }
}

extension Application {
    private struct RealtimeBusKey: StorageKey {
        typealias Value = any RealtimeBus
    }

    var realtimeBus: any RealtimeBus {
        get {
            if let bus = storage[RealtimeBusKey.self] {
                return bus
            }
            let bus = InProcessRealtimeBus()
            storage[RealtimeBusKey.self] = bus
            return bus
        }
        set { storage[RealtimeBusKey.self] = newValue }
    }
}

/// Closes every realtime stream when the app shuts down.
struct RealtimeShutdown: LifecycleHandler {
    func shutdownAsync(_ application: Application) async {
        await application.realtimeBus.finishAll()
    }
}

/// Server-sent events framing shared by the assistant and realtime streams.
enum SSE {
    static func writeFrame(event: String, encodedData: String, to writer: any AsyncBodyStreamWriter) async throws {
        var buffer = ByteBufferAllocator().buffer(capacity: event.utf8.count + encodedData.utf8.count + 16)
        buffer.writeString("event: \(event)\ndata: \(encodedData)\n\n")
        try await writer.writeBuffer(buffer)
    }

    /// A comment line, ignored by clients; keeps proxies from timing out.
    static func writeComment(_ text: String, to writer: any AsyncBodyStreamWriter) async throws {
        try await writer.writeBuffer(ByteBuffer(string: ": \(text)\n\n"))
    }

    /// Tells `EventSource` how long to wait before reconnecting.
    static func writeRetry(milliseconds: Int, to writer: any AsyncBodyStreamWriter) async throws {
        try await writer.writeBuffer(ByteBuffer(string: "retry: \(milliseconds)\n\n"))
    }
}
