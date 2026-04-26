import NIOCore
import Redis
import RediStack
import Vapor

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
        guard request.application.redis.configuration != nil else {
            if request.application.environment == .production {
                throw Abort(.serviceUnavailable, reason: "Rate limiting is unavailable.")
            }
            return try await next.respond(to: request)
        }

        let identifier = request.remoteAddress?.ipAddress ?? "unknown"
        let key = RedisKey("\(keyPrefix):\(identifier)")
        let count: Int
        do {
            count = try await request.redis.increment(key).get()
            if count == 1 {
                _ = try await request.redis.expire(key, after: .seconds(Int64(interval))).get()
            }
        } catch {
            if request.application.environment == .production {
                request.logger.error("rate_limit unavailable prefix=\(keyPrefix)")
                throw Abort(.serviceUnavailable, reason: "Rate limiting is unavailable.")
            }
            return try await next.respond(to: request)
        }

        guard count <= limit else {
            throw Abort(.tooManyRequests, reason: "Rate limit exceeded. Please try again later.")
        }
        return try await next.respond(to: request)
    }
}
