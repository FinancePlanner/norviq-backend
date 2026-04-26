import Fluent
import Foundation
import Vapor

protocol WebhookDeliveryService: Sendable {
    func createDelivery(
        url: String,
        method: String,
        headers: [String: String]?,
        payload: Data?,
        on db: any Database
    ) async throws -> WebhookDelivery

    func processDueWebhooks(limit: Int, on db: any Database) async throws
}

enum WebhookDeliveryServiceError: AbortError {
    case invalidURL
    case invalidMethod
    case httpError(Int)

    var status: HTTPResponseStatus {
        switch self {
        case .invalidURL: .badRequest
        case .invalidMethod: .badRequest
        case .httpError: .badGateway
        }
    }

    var reason: String {
        switch self {
        case .invalidURL: "Invalid webhook URL"
        case .invalidMethod: "Invalid HTTP method"
        case let .httpError(code): "Webhook delivery failed with status \(code)"
        }
    }
}

final class DefaultWebhookDeliveryService: WebhookDeliveryService {
    private let repository: any WebhookRepository
    private let client: Client
    private let maxAttempts = 5

    init(repository: any WebhookRepository, client: Client) {
        self.repository = repository
        self.client = client
    }

    func createDelivery(
        url: String,
        method: String,
        headers: [String: String]?,
        payload: Data?,
        on db: any Database
    ) async throws -> WebhookDelivery {
        guard URL(string: url) != nil else {
            throw WebhookDeliveryServiceError.invalidURL
        }

        let methodUpper = method.uppercased()
        let key = WebhookDelivery.computeKey(url: url, method: methodUpper, payload: payload)

        if let existing = try await repository.findByKey(key, on: db) {
            let twentyFourHoursAgo = Date().addingTimeInterval(-24 * 3600)
            if let createdAt = existing.createdAt, createdAt >= twentyFourHoursAgo {
                return existing
            }
        }

        let webhook = WebhookDelivery(
            webhookKey: key,
            url: url,
            method: methodUpper,
            headers: headers,
            payload: payload,
            attemptCount: 0,
            nextRetryAt: Date(),
            lastError: nil,
            status: .pending
        )
        return try await repository.create(webhook, on: db)
    }

    func processDueWebhooks(limit: Int, on db: any Database) async throws {
        let dueWebhooks = try await repository.findDue(limit: limit, on: db)
        for webhook in dueWebhooks {
            do {
                try await attemptDelivery(webhook, on: db)
            } catch {
                // Failure already recorded by attemptDelivery via repository
                continue
            }
        }
    }

    private func attemptDelivery(_ webhook: WebhookDelivery, on db: any Database) async throws {
        // Validate URL
        guard URL(string: webhook.url) != nil else {
            webhook.status = .failed
            webhook.lastError = "Invalid URL"
            try await webhook.save(on: db)
            return
        }

        // Build request (ClientRequest expects a URI)
        let uri = URI(string: webhook.url)
        let method = HTTPMethod(rawValue: webhook.method)
        var clientRequest = ClientRequest(
            method: method,
            url: uri
        )
        for (name, value) in webhook.headers ?? [:] {
            clientRequest.headers.add(name: name, value: value)
        }
        if let payload = webhook.payload {
            clientRequest.body = ByteBuffer(data: payload)
            clientRequest.headers.contentType = .json
        }

        do {
            let response = try await client.send(clientRequest)
            let statusCode = response.status.code
            if (200 ... 299).contains(statusCode) {
                try await repository.markSent(webhook, on: db)
            } else if statusCode == 429 {
                try await repository.markFailed(webhook, error: "Rate limited (429)", on: db)
                if webhook.attemptCount >= maxAttempts {
                    try await repository.markExhausted(webhook, on: db)
                }
            } else if (400 ... 499).contains(statusCode) {
                webhook.status = .failed
                webhook.lastError = "Client error: \(statusCode)"
                try await webhook.save(on: db)
            } else {
                try await repository.markFailed(webhook, error: "Server error: \(statusCode)", on: db)
                if webhook.attemptCount >= maxAttempts {
                    try await repository.markExhausted(webhook, on: db)
                }
            }
        } catch {
            try await repository.markFailed(webhook, error: error.localizedDescription, on: db)
            if webhook.attemptCount >= maxAttempts {
                try await repository.markExhausted(webhook, on: db)
            }
        }
    }
}
