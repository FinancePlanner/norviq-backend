import Fluent
import Foundation

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
