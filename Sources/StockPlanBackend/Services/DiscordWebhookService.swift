import Vapor

protocol DiscordWebhookService: Sendable {
    func send(_ message: String, on req: Request) async throws
}

struct DefaultDiscordWebhookService: DiscordWebhookService {
    private struct DiscordPayload: Content {
        let content: String
    }

    func send(_ message: String, on req: Request) async throws {
        guard let webhookURL = Environment.get("DISCORD_WEBHOOK_URL"), !webhookURL.isEmpty else {
            req.logger.debug("DISCORD_WEBHOOK_URL not set, skipping Discord notification.")
            return
        }

        let payload = DiscordPayload(content: message)
        let response = try await req.client.post(URI(string: webhookURL)) { clientReq in
            try clientReq.content.encode(payload)
        }

        if response.status.code >= 400 {
            req.logger.warning("Failed to send Discord webhook: \(response.status)")
        }
    }
}

extension Request {
    var discord: any DiscordWebhookService {
        application.discord
    }
}

extension Application {
    private struct DiscordKey: StorageKey {
        typealias Value = any DiscordWebhookService
    }

    var discord: any DiscordWebhookService {
        get {
            storage[DiscordKey.self] ?? DefaultDiscordWebhookService()
        }
        set {
            storage[DiscordKey.self] = newValue
        }
    }
}
