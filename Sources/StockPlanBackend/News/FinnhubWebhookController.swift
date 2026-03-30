import Vapor
import Foundation

struct FinnhubWebhookController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("webhooks", "finnhub").post("news", use: receiveNews)
    }

    @Sendable
    func receiveNews(req: Request) async throws -> FinnhubNewsWebhookResponse {
        try verifySecret(req)
        let payload = try decodePayload(req)
        return try await req.application.newsService.ingestFinnhubWebhook(payload: payload, on: req.db)
    }
}

private extension FinnhubWebhookController {
    func decodePayload(_ req: Request) throws -> FinnhubNewsWebhookRequest {
        if let payload = try? req.content.decode(FinnhubNewsWebhookRequest.self), !payload.news.isEmpty {
            return payload
        }

        if let items = try? req.content.decode([FinnhubNewsWebhookItem].self), !items.isEmpty {
            return FinnhubNewsWebhookRequest(news: items)
        }

        throw Abort(
            .badRequest,
            reason: "Invalid Finnhub webhook payload. Expected a news array under `news`, `data`, `articles`, or a top-level array."
        )
    }

    func verifySecret(_ req: Request) throws {
        let configuredSecret = Environment.get("FINNHUB_WEBHOOK_SECRET")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configuredSecret, !configuredSecret.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "FINNHUB_WEBHOOK_SECRET is not configured.")
        }

        let providedSecret = req.headers.first(name: "X-Finnhub-Secret")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? req.query[String.self, at: "secret"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let providedSecret, !providedSecret.isEmpty else {
            throw Abort(.unauthorized, reason: "Missing Finnhub webhook secret.")
        }

        guard providedSecret == configuredSecret else {
            throw Abort(.unauthorized, reason: "Invalid Finnhub webhook secret.")
        }
    }
}
