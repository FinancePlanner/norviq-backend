import Fluent
import FluentSQL
import Foundation
import Vapor

final class AIConversation: Model, @unchecked Sendable {
    static let schema = "ai_conversations"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "title_encrypted") var titleEncrypted: Data
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @Field(key: "expires_at") var expiresAt: Date
    init() {}
    init(userId: UUID, titleEncrypted: Data, expiresAt: Date) {
        self.userId = userId; self.titleEncrypted = titleEncrypted; self.expiresAt = expiresAt
    }
}

final class AIAssistantMessage: Model, @unchecked Sendable {
    static let schema = "ai_messages"
    @ID(key: .id) var id: UUID?
    @Parent(key: "conversation_id") var conversation: AIConversation
    @Field(key: "user_id") var userId: UUID
    @Field(key: "role") var role: String
    @Field(key: "content_encrypted") var contentEncrypted: Data
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(conversationId: UUID, userId: UUID, role: String, contentEncrypted: Data) {
        $conversation.id = conversationId; self.userId = userId
        self.role = role; self.contentEncrypted = contentEncrypted
    }
}

final class AIAssistantPreference: Model, @unchecked Sendable {
    static let schema = "ai_preferences"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "proactive_tips_enabled") var proactiveTipsEnabled: Bool
    @Field(key: "push_enabled") var pushEnabled: Bool
    @Field(key: "timezone") var timezone: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
    init(userId: UUID) {
        self.userId = userId; proactiveTipsEnabled = false; pushEnabled = false; timezone = "UTC"
    }
}

final class AIAssistantUsage: Model, @unchecked Sendable {
    static let schema = "ai_usage_monthly"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "month_start") var monthStart: Date
    @Field(key: "request_count") var requestCount: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
    init(userId: UUID, monthStart: Date) {
        self.userId = userId; self.monthStart = monthStart; requestCount = 0
    }
}

extension AIAssistantUsage {
    /// Adds one to this month's counter and returns the new total.
    ///
    /// Reading the row and then saving it is two statements, so two turns that
    /// overlap both see "no row yet" and both insert one; the second violates
    /// `user_id + month_start`. One upsert cannot interleave with itself: the
    /// loser of the race takes the DO UPDATE branch instead of failing.
    static func incrementRequestCount(
        userId: UUID,
        month: Date,
        on database: any Database
    ) async throws -> Int {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "AI usage requires a SQL database.")
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let monthStart = formatter.string(from: month)

        let row = try await sql.raw("""
        INSERT INTO ai_usage_monthly (id, user_id, month_start, request_count, created_at, updated_at)
        VALUES (\(bind: UUID()), \(bind: userId), \(bind: monthStart)::date, 1, now(), now())
        ON CONFLICT (user_id, month_start)
        DO UPDATE SET request_count = ai_usage_monthly.request_count + 1, updated_at = now()
        RETURNING request_count
        """).first()

        guard let count = try row?.decode(column: "request_count", as: Int.self) else {
            throw Abort(.internalServerError, reason: "AI usage counter did not return a count.")
        }
        return count
    }
}

final class AIAssistantTip: Model, @unchecked Sendable {
    static let schema = "ai_tips"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "kind") var kind: String
    @Field(key: "title_encrypted") var titleEncrypted: Data
    @Field(key: "body_encrypted") var bodyEncrypted: Data
    @Field(key: "importance") var importance: Int
    @OptionalField(key: "action_path") var actionPath: String?
    @Field(key: "is_seen") var isSeen: Bool
    @Field(key: "is_dismissed") var isDismissed: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Field(key: "expires_at") var expiresAt: Date
    init() {}
}

final class AIPendingAction: Model, @unchecked Sendable {
    static let schema = "ai_pending_actions"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @OptionalField(key: "conversation_id") var conversationId: UUID?
    @Field(key: "tool_name") var toolName: String
    @Field(key: "arguments_encrypted") var argumentsEncrypted: Data
    @Field(key: "summary_encrypted") var summaryEncrypted: Data
    @Field(key: "status") var status: String
    @Field(key: "expires_at") var expiresAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
}

final class AIActionAudit: Model, @unchecked Sendable {
    static let schema = "ai_action_audits"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "pending_action_id") var pendingActionId: UUID
    @Field(key: "tool_name") var toolName: String
    @Field(key: "status") var status: String
    @OptionalField(key: "details_encrypted") var detailsEncrypted: Data?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
}
