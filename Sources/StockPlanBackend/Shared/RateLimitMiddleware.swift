import Redis
import Vapor
import NIOCore
import RediStack

struct RateLimitMiddleware: AsyncMiddleware {
    let limit: Int
    let interval: TimeInterval
    let keyPrefix: String

    init(limit: Int, interval: TimeInterval, keyPrefix: String = "ratelimit") {
        self.limit = limit
        self.interval = interval
        self.keyPrefix = keyPrefix
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // Only proceed if Redis is configured
        guard request.application.redis.configuration != nil else {
            return try await next.respond(to: request)
        }

        let identifier = request.remoteAddress?.ipAddress ?? "unknown"
        let key = RedisKey("\(keyPrefix):\(identifier)")

        // Use more direct Redis commands to avoid RediStack/Vapor version mismatches in types
        let countData = try await request.redis.get(key).get()
        let count: Int
        
        switch countData {
        case .bulkString(let buffer):
            count = buffer.flatMap { buffer in
                var b = buffer
                return b.readString(length: b.readableBytes).flatMap(Int.init)
            } ?? 0
        case .integer(let int):
            count = int
        default:
            count = 0
        }

        if count >= limit {
            throw Abort(.tooManyRequests, reason: "Rate limit exceeded. Please try again later.")
        }

        // Increment count
        _ = try await request.redis.increment(key).get()

        // Set expiration if it's the first request in the window
        if count == 0 {
            _ = try await request.redis.expire(key, after: .seconds(Int64(interval))).get()
        }

        return try await next.respond(to: request)
    }
}
