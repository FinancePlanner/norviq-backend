import Fluent
import Vapor
import Foundation
import Crypto

/// Webhook delivery model representing a queued webhook to be sent with retry logic.
final class WebhookDelivery: Model, Content, @unchecked Sendable {
    static let schema = "webhook_deliveries"
    
    @ID(key: .id)
    var id: UUID?
    
    @Field(key: "webhook_key")
    var webhookKey: String
    
    @Field(key: "url")
    var url: String
    
    @Field(key: "method")
    var method: String
    
    @OptionalField(key: "headers")
    var headers: [String: String]?
    
    @OptionalField(key: "payload")
    var payload: Data?
    
    @Field(key: "attempt_count")
    var attemptCount: Int
    
    @OptionalField(key: "next_retry_at")
    var nextRetryAt: Date?
    
    @OptionalField(key: "last_error")
    var lastError: String?
    
    @Enum(key: "status")
    var status: WebhookStatus
    
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?
    
    init() {}
    
    init(
        id: UUID? = nil,
        webhookKey: String,
        url: String,
        method: String,
        headers: [String: String]? = nil,
        payload: Data? = nil,
        attemptCount: Int = 0,
        nextRetryAt: Date? = nil,
        lastError: String? = nil,
        status: WebhookStatus = .pending,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.webhookKey = webhookKey
        self.url = url
        self.method = method
        self.headers = headers
        self.payload = payload
        self.attemptCount = attemptCount
        self.nextRetryAt = nextRetryAt
        self.lastError = lastError
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Webhook delivery status enum.
enum WebhookStatus: String, Codable, Sendable, Comparable {
    case pending
    case success
    case failed
    case exhausted
    
    static func == (lhs: WebhookStatus, rhs: WebhookStatus) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
    
    static func < (lhs: WebhookStatus, rhs: WebhookStatus) -> Bool {
        let order: [WebhookStatus] = [.pending, .success, .failed, .exhausted]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

// MARK: - Webhook Key Generation
extension WebhookDelivery {
    /// Computes a deterministic webhook key from url, method, and canonical payload.
    static func computeKey(url: String, method: String, payload: Data?) -> String {
        var payloadString = ""
        if let payload = payload {
            payloadString = String(decoding: payload, as: UTF8.self)
        }
        let combined = "\(url)|\(method)|\(payloadString)"
        let hash = SHA256.hash(data: Data(combined.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
