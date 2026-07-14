import Fluent
import Foundation
import Vapor

final class PortfolioMembershipRecord: Model, Content, @unchecked Sendable {
    static let schema = "portfolio_memberships"

    @ID(key: .id) var id: UUID?
    @Field(key: "portfolio_id") var portfolioId: UUID
    @Field(key: "user_id") var userId: UUID
    @Field(key: "role") var role: String
    @Field(key: "status") var status: String
    @OptionalField(key: "joined_at") var joinedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        portfolioId: UUID,
        userId: UUID,
        role: String = "editor",
        status: String = "active",
        joinedAt: Date? = Date()
    ) {
        self.id = id
        self.portfolioId = portfolioId
        self.userId = userId
        self.role = role
        self.status = status
        self.joinedAt = joinedAt
    }
}

final class PortfolioInvitationRecord: Model, Content, @unchecked Sendable {
    static let schema = "portfolio_invitations"

    @ID(key: .id) var id: UUID?
    @Field(key: "portfolio_id") var portfolioId: UUID
    @Field(key: "email") var email: String
    @Field(key: "role") var role: String
    @Field(key: "status") var status: String
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "accepted_at") var acceptedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        portfolioId: UUID,
        email: String,
        role: String = "editor",
        status: String = "pending",
        tokenHash: String,
        expiresAt: Date
    ) {
        self.id = id
        self.portfolioId = portfolioId
        self.email = email
        self.role = role
        self.status = status
        self.tokenHash = tokenHash
        self.expiresAt = expiresAt
    }
}

final class PortfolioCashPositionRecord: Model, Content, @unchecked Sendable {
    static let schema = "portfolio_cash_positions"

    @ID(key: .id) var id: UUID?
    @Field(key: "portfolio_id") var portfolioId: UUID
    @Field(key: "label") var label: String
    @Field(key: "currency") var currency: String
    @Field(key: "balance") var balance: Double
    @Field(key: "as_of") var asOf: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        portfolioId: UUID,
        label: String,
        currency: String,
        balance: Double,
        asOf: Date
    ) {
        self.id = id
        self.portfolioId = portfolioId
        self.label = label
        self.currency = currency
        self.balance = balance
        self.asOf = asOf
    }
}

final class RetirementPlanRecord: Model, Content, @unchecked Sendable {
    static let schema = "retirement_plans"

    @ID(key: .id) var id: UUID?
    @Field(key: "portfolio_id") var portfolioId: UUID
    @Field(key: "rule_version") var ruleVersion: String
    @Field(key: "input_json") var inputJSON: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        portfolioId: UUID,
        ruleVersion: String,
        inputJSON: String
    ) {
        self.id = id
        self.portfolioId = portfolioId
        self.ruleVersion = ruleVersion
        self.inputJSON = inputJSON
    }
}

final class AdvancedReportTemplateRecord: Model, Content, @unchecked Sendable {
    static let schema = "advanced_report_templates"

    @ID(key: .id) var id: UUID?
    @Field(key: "owner_user_id") var ownerUserId: UUID
    @Field(key: "input_json") var inputJSON: String
    @Field(key: "revision") var revision: Int
    @Field(key: "is_starter_template") var isStarterTemplate: Bool
    @OptionalField(key: "archived_at") var archivedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        ownerUserId: UUID,
        inputJSON: String,
        revision: Int = 1,
        isStarterTemplate: Bool = false
    ) {
        self.id = id
        self.ownerUserId = ownerUserId
        self.inputJSON = inputJSON
        self.revision = revision
        self.isStarterTemplate = isStarterTemplate
    }
}

final class AdvancedReportScheduleRecord: Model, Content, @unchecked Sendable {
    static let schema = "advanced_report_schedules"

    @ID(key: .id) var id: UUID?
    @Field(key: "owner_user_id") var ownerUserId: UUID
    @Field(key: "input_json") var inputJSON: String
    @OptionalField(key: "next_run_at") var nextRunAt: Date?
    @OptionalField(key: "last_run_at") var lastRunAt: Date?
    @OptionalField(key: "paused_reason") var pausedReason: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        ownerUserId: UUID,
        inputJSON: String,
        nextRunAt: Date? = nil
    ) {
        self.id = id
        self.ownerUserId = ownerUserId
        self.inputJSON = inputJSON
        self.nextRunAt = nextRunAt
    }
}

final class AdvancedReportRunRecord: Model, Content, @unchecked Sendable {
    static let schema = "advanced_report_runs"

    @ID(key: .id) var id: UUID?
    @Field(key: "template_id") var templateId: UUID
    @OptionalField(key: "schedule_id") var scheduleId: UUID?
    @Field(key: "requested_by_user_id") var requestedByUserId: UUID
    @Field(key: "template_revision") var templateRevision: Int
    @Field(key: "template_input_json") var templateInputJSON: String
    @Field(key: "output_formats_json") var outputFormatsJSON: String
    @Field(key: "recipient_user_ids_json") var recipientUserIdsJSON: String
    @Field(key: "status") var status: String
    @OptionalField(key: "scheduled_for") var scheduledFor: Date?
    @OptionalField(key: "claimed_at") var claimedAt: Date?
    @OptionalField(key: "started_at") var startedAt: Date?
    @OptionalField(key: "completed_at") var completedAt: Date?
    @OptionalField(key: "failure_reason") var failureReason: String?
    @Field(key: "attempt_count") var attemptCount: Int
    @OptionalField(key: "retry_at") var retryAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        templateId: UUID,
        scheduleId: UUID? = nil,
        requestedByUserId: UUID,
        templateRevision: Int,
        templateInputJSON: String,
        outputFormatsJSON: String,
        recipientUserIdsJSON: String,
        status: String = "pending",
        scheduledFor: Date? = nil
    ) {
        self.id = id
        self.templateId = templateId
        self.scheduleId = scheduleId
        self.requestedByUserId = requestedByUserId
        self.templateRevision = templateRevision
        self.templateInputJSON = templateInputJSON
        self.outputFormatsJSON = outputFormatsJSON
        self.recipientUserIdsJSON = recipientUserIdsJSON
        self.status = status
        self.scheduledFor = scheduledFor
        attemptCount = 0
    }
}

final class AdvancedReportArtifactRecord: Model, Content, @unchecked Sendable {
    static let schema = "advanced_report_artifacts"

    @ID(key: .id) var id: UUID?
    @Field(key: "run_id") var runId: UUID
    @Field(key: "format") var format: String
    @Field(key: "filename") var filename: String
    @Field(key: "content_type") var contentType: String
    @Field(key: "size_bytes") var sizeBytes: Int64
    @Field(key: "sha256") var sha256: String
    @Field(key: "storage_key") var storageKey: String
    @Field(key: "expires_at") var expiresAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        runId: UUID,
        format: String,
        filename: String,
        contentType: String,
        sizeBytes: Int64,
        sha256: String,
        storageKey: String,
        expiresAt: Date
    ) {
        self.id = id
        self.runId = runId
        self.format = format
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.storageKey = storageKey
        self.expiresAt = expiresAt
    }
}

final class AdvancedReportDeliveryRecord: Model, Content, @unchecked Sendable {
    static let schema = "advanced_report_deliveries"

    @ID(key: .id) var id: UUID?
    @Field(key: "run_id") var runId: UUID
    @Field(key: "recipient_user_id") var recipientUserId: UUID
    @Field(key: "recipient_email") var recipientEmail: String
    @Field(key: "status") var status: String
    @Field(key: "attempt_count") var attemptCount: Int
    @OptionalField(key: "last_attempt_at") var lastAttemptAt: Date?
    @OptionalField(key: "delivered_at") var deliveredAt: Date?
    @OptionalField(key: "failure_reason") var failureReason: String?
    @OptionalField(key: "link_expires_at") var linkExpiresAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        runId: UUID,
        recipientUserId: UUID,
        recipientEmail: String,
        status: String = "pending"
    ) {
        self.id = id
        self.runId = runId
        self.recipientUserId = recipientUserId
        self.recipientEmail = recipientEmail
        self.status = status
        attemptCount = 0
    }
}
