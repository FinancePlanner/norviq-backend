import Vapor

protocol DiscordWebhookService: Sendable {
    func send(_ message: String, on req: Request) async throws
}

struct DefaultDiscordWebhookService: DiscordWebhookService {
    struct DiscordPayload: Content {
        struct AllowedMentions: Content {
            let parse: [String]
        }

        let content: String
        /// Messages quote user text (report notes, titles, board posts), so
        /// nothing in them may ping @everyone, a role or a person.
        let allowedMentions: AllowedMentions

        enum CodingKeys: String, CodingKey {
            case content
            case allowedMentions = "allowed_mentions"
        }
    }

    static func payload(_ message: String) -> DiscordPayload {
        DiscordPayload(content: message, allowedMentions: .init(parse: []))
    }

    func send(_ message: String, on req: Request) async throws {
        guard let webhookURL = Environment.get("DISCORD_WEBHOOK_URL"), !webhookURL.isEmpty else {
            req.logger.debug("DISCORD_WEBHOOK_URL not set, skipping Discord notification.")
            return
        }

        let payload = Self.payload(message)
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
