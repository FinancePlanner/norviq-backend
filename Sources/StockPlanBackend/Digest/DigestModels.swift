import Fluent
import Foundation
import Vapor

final class DigestPreference: Model, @unchecked Sendable {
    static let schema = "digest_preferences"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "email_enabled")
    var emailEnabled: Bool

    @Field(key: "push_enabled")
    var pushEnabled: Bool

    @Field(key: "telegram_enabled")
    var telegramEnabled: Bool

    @Field(key: "sentiment_alerts_enabled")
    var sentimentAlertsEnabled: Bool

    /// ISO weekday, 1 = Monday … 7 = Sunday.
    @Field(key: "weekday")
    var weekday: Int

    @Field(key: "local_hour")
    var localHour: Int

    /// IANA identifier, e.g. `Europe/Lisbon`.
    @Field(key: "timezone")
    var timezone: String

    /// `MacroCountry` raw value for the personal-inflation section; nil skips it.
    @OptionalField(key: "country")
    var country: String?

    @Field(key: "unsubscribe_token")
    var unsubscribeToken: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        emailEnabled: Bool = false,
        pushEnabled: Bool = false,
        telegramEnabled: Bool = false,
        sentimentAlertsEnabled: Bool = false,
        weekday: Int = DigestPreference.defaultWeekday,
        localHour: Int = DigestPreference.defaultLocalHour,
        timezone: String = "UTC",
        country: String? = nil,
        unsubscribeToken: String = DigestPreference.makeUnsubscribeToken()
    ) {
        self.id = id
        self.userId = userId
        self.emailEnabled = emailEnabled
        self.pushEnabled = pushEnabled
        self.telegramEnabled = telegramEnabled
        self.sentimentAlertsEnabled = sentimentAlertsEnabled
        self.weekday = weekday
        self.localHour = localHour
        self.timezone = timezone
        self.country = country
        self.unsubscribeToken = unsubscribeToken
    }

    static let defaultWeekday = 7
    static let defaultLocalHour = 18

    var anyChannelEnabled: Bool {
        emailEnabled || pushEnabled || telegramEnabled
    }

    /// 32 random bytes, URL-safe. Unguessable, so it can sit in an email link
    /// without a signature.
    static func makeUnsubscribeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum WeeklyDigestStatus: String, Codable, Sendable {
    /// Claimed; composing.
    case pending
    /// Payload written; delivering.
    case composed
    /// At least one channel delivered.
    case sent
    /// Nothing delivered (compose failed, or every channel failed).
    case failed
}

final class WeeklyDigest: Model, @unchecked Sendable {
    static let schema = "weekly_digests"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    /// `yyyy-MM-dd` in the user's zone, inclusive.
    @Field(key: "period_start")
    var periodStart: String

    /// `yyyy-MM-dd` in the user's zone, inclusive (the send day).
    @Field(key: "period_end")
    var periodEnd: String

    /// A `WeeklyDigestStatus` raw value.
    @Field(key: "status")
    var status: String

    /// JSON-encoded `DigestPayload`.
    @OptionalField(key: "payload")
    var payload: String?

    @OptionalField(key: "narrative")
    var narrative: String?

    @OptionalField(key: "model")
    var model: String?

    @OptionalField(key: "token_count")
    var tokenCount: Int?

    @OptionalField(key: "error")
    var error: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    func decodedPayload() throws -> DigestPayload? {
        guard let payload else { return nil }
        return try JSONDecoder().decode(DigestPayload.self, from: Data(payload.utf8))
    }
}

enum DigestChannel: String, Codable, Sendable, CaseIterable {
    case email
    case push
    case telegram
}

enum DigestDeliveryStatus: String, Codable, Sendable {
    case sending
    case sent
    case failed
}

final class WeeklyDigestDelivery: Model, @unchecked Sendable {
    static let schema = "weekly_digest_deliveries"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "digest_id")
    var digestId: UUID

    /// A `DigestChannel` raw value.
    @Field(key: "channel")
    var channel: String

    /// A `DigestDeliveryStatus` raw value.
    @Field(key: "status")
    var status: String

    @OptionalField(key: "error")
    var error: String?

    @OptionalField(key: "sent_at")
    var sentAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}
}
