import Foundation
import NIOCore
import Redis
import RediStack
import Vapor

/// Shared per-user daily Redis counter for Norviq-paid LLM endpoints.
enum AIDailyCap {
    static func enforce(
        _ req: Request,
        userId: UUID,
        unavailableReason: String,
        limitReachedReason: String
    ) async throws {
        try AICostControls.requireEnabled(reason: unavailableReason)

        let limit = AICostControls.dailyLimit
        guard req.application.redis.configuration != nil else {
            if req.application.environment == .production {
                throw Abort(.serviceUnavailable, reason: unavailableReason)
            }
            return
        }

        let day = dayBucket(Date())
        let key = RedisKey("ai_daily:\(userId.uuidString):\(day)")
        let count: Int
        do {
            count = try await req.redis.increment(key).get()
            if count == 1 {
                _ = try await req.redis.expire(key, after: .seconds(86400)).get()
            }
        } catch {
            if req.application.environment == .production {
                req.logger.error("ai_daily_cap unavailable userId=\(userId)")
                throw Abort(.serviceUnavailable, reason: unavailableReason)
            }
            return
        }

        guard count <= limit else {
            throw Abort(.tooManyRequests, reason: limitReachedReason)
        }
    }

    static func dayBucket(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
