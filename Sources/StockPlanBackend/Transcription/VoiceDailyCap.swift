import Foundation
import Redis
import RediStack
import Vapor

/// Per-user daily voice allowance, metered in seconds.
///
/// Seconds rather than calls: transcription is billed by audio length, so one
/// long note costs many short ones, and a per-call counter would wave it
/// through. Its own Redis bucket, so voice cannot starve the chat allowance.
enum VoiceDailyCap {
    static let bucket = "voice_daily_seconds"
    static let defaultDailySeconds = 900

    static let limitReachedReason =
        "That's your voice transcription for today. You can still type — I'll answer the same way."

    static var dailySeconds: Int {
        // A malformed value must not silently disable the feature.
        Environment.get("TRANSCRIBE_DAILY_SECONDS").flatMap(Int.init) ?? defaultDailySeconds
    }

    /// Charges `seconds` against today's budget, throwing once it is spent.
    ///
    /// Mirrors `AIDailyCap`: when Redis is unreachable, production refuses and
    /// development continues, so a local bot is usable without a cache running.
    static func charge(_ req: Request, userId: UUID, seconds: Int) async throws {
        guard req.application.redis.configuration != nil else {
            if req.application.environment == .production {
                throw Abort(.serviceUnavailable, reason: "Voice is unavailable right now.")
            }
            return
        }

        let key = RedisKey("\(bucket):\(userId.uuidString):\(AIDailyCap.dayBucket(Date()))")
        let total: Int
        do {
            total = try await req.redis.increment(key, by: max(seconds, 1)).get()
            if total <= max(seconds, 1) {
                _ = try await req.redis.expire(key, after: .seconds(86400)).get()
            }
        } catch {
            if req.application.environment == .production {
                req.logger.error("voice_daily_cap unavailable userId=\(userId)")
                throw Abort(.serviceUnavailable, reason: "Voice is unavailable right now.")
            }
            return
        }

        guard total <= dailySeconds else {
            throw Abort(.tooManyRequests, reason: limitReachedReason)
        }
    }
}
