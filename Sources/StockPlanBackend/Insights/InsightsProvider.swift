import Foundation
import Vapor

protocol InsightsProvider: Sendable {
    var isEnabled: Bool { get }
    func fetchEvents(days: Int, limit: Int, on req: Request) async throws -> HermesEventsResponse
    func fetchSummary(days: Int, on req: Request) async throws -> HermesSummaryResponse
    func fetchSentiment(topic: String?, days: Int, on req: Request) async throws -> HermesSentimentResponse
    func fetchNetWorth(on req: Request) async throws -> HermesNetWorthResponse
    func fetchTickerPosts(symbol: String, days: Int, limit: Int, on req: Request) async throws -> HermesTickerPostsResponse
    func health(on req: Request) async -> Bool
}

/// Talks to the self-hosted Hermes finance API over the private Tailscale
/// network. The base URL is the VPS tailnet address (never a public host).
struct HermesInsightsProvider: InsightsProvider {
    let baseURL: String
    let apiToken: String?

    var isEnabled: Bool {
        true
    }

    func fetchEvents(days: Int, limit: Int, on req: Request) async throws -> HermesEventsResponse {
        try await fetchJSON(
            path: "/finance/events",
            query: [("days", String(days)), ("limit", String(limit))],
            on: req
        )
    }

    func fetchSummary(days: Int, on req: Request) async throws -> HermesSummaryResponse {
        try await fetchJSON(path: "/finance/summary", query: [("days", String(days))], on: req)
    }

    func fetchSentiment(topic: String?, days: Int, on req: Request) async throws -> HermesSentimentResponse {
        var query = [("days", String(days))]
        if let topic, !topic.isEmpty {
            query.append(("topic", topic))
        }
        return try await fetchJSON(path: "/finance/sentiment", query: query, on: req)
    }

    func fetchNetWorth(on req: Request) async throws -> HermesNetWorthResponse {
        try await fetchJSON(path: "/finance/net-worth", query: [], on: req)
    }

    func fetchTickerPosts(symbol: String, days: Int, limit: Int, on req: Request) async throws -> HermesTickerPostsResponse {
        try await fetchJSON(
            path: "/finance/ticker/\(symbol)/posts",
            query: [("days", String(days)), ("limit", String(limit))],
            on: req
        )
    }

    func health(on req: Request) async -> Bool {
        do {
            let response: HermesHealthResponse = try await fetchJSON(path: "/healthz", query: [], on: req)
            return response.ok
        } catch {
            return false
        }
    }
}

struct DisabledInsightsProvider: InsightsProvider {
    var isEnabled: Bool {
        false
    }

    func fetchEvents(days _: Int, limit _: Int, on _: Request) async throws -> HermesEventsResponse {
        throw disabledError()
    }

    func fetchSummary(days _: Int, on _: Request) async throws -> HermesSummaryResponse {
        throw disabledError()
    }

    func fetchSentiment(topic _: String?, days _: Int, on _: Request) async throws -> HermesSentimentResponse {
        throw disabledError()
    }

    func fetchNetWorth(on _: Request) async throws -> HermesNetWorthResponse {
        throw disabledError()
    }

    func fetchTickerPosts(symbol _: String, days _: Int, limit _: Int, on _: Request) async throws -> HermesTickerPostsResponse {
        throw disabledError()
    }

    func health(on _: Request) async -> Bool {
        false
    }

    private func disabledError() -> Abort {
        Abort(.serviceUnavailable, reason: "Insights provider not configured. Set HERMES_BASE_URL to enable Hermes sync.")
    }
}

private extension HermesInsightsProvider {
    func fetchJSON<ResponseBody: Decodable>(
        path: String,
        query: [(String, String)],
        on req: Request
    ) async throws -> ResponseBody {
        let uri = try makeURI(path: path, query: query)
        let response = try await req.client.get(uri) { clientRequest in
            if let apiToken, !apiToken.isEmpty {
                clientRequest.headers.bearerAuthorization = BearerAuthorization(token: apiToken)
            }
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.timeout = .seconds(15)
        }

        switch response.status {
        case .ok:
            do {
                return try response.content.decode(ResponseBody.self)
            } catch {
                throw Abort(.badGateway, reason: "Failed to decode Hermes response for \(path).")
            }

        case .unauthorized, .forbidden:
            throw Abort(.badGateway, reason: "Hermes rejected the request. Check HERMES_API_TOKEN.")

        case .notFound:
            throw Abort(.notFound, reason: "Hermes resource not found for \(path).")

        default:
            throw Abort(.badGateway, reason: "Hermes request failed for \(path) with status \(response.status.code).")
        }
    }

    func makeURI(path: String, query: [(String, String)]) throws -> URI {
        let trimmedBaseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: trimmedBaseURL + path) else {
            throw Abort(.internalServerError, reason: "Invalid Hermes base URL configuration.")
        }

        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }

        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "Unable to build Hermes request URL.")
        }

        return URI(string: url.absoluteString)
    }
}
