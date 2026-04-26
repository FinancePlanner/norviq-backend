import Foundation
import Vapor

protocol EarningsProvider: Sendable {
    var name: String { get }
    func fetchCalendar(query: EarningsQueryRequest, on req: Request) async throws -> [FinnhubEarningsItem]
}

struct FinnhubEarningsProvider: EarningsProvider {
    let baseURL: String
    let apiKey: String

    var name: String {
        "finnhub"
    }

    init(
        baseURL: String = "https://finnhub.io/api/v1",
        apiKey: String = Environment.get("FINNHUB_API_KEY") ?? ""
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    func fetchCalendar(query: EarningsQueryRequest, on req: Request) async throws -> [FinnhubEarningsItem] {
        var queryItems: [(String, String)] = []
        if let from = query.from, !from.isEmpty {
            queryItems.append(("from", from))
        }
        if let to = query.to, !to.isEmpty {
            queryItems.append(("to", to))
        }
        if let symbol = query.symbol, !symbol.isEmpty {
            queryItems.append(("symbol", symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()))
        }
        if let international = query.international {
            queryItems.append(("international", String(international)))
        }

        let payload: FinnhubEarningsPayload = try await fetchJSON(
            path: "/calendar/earnings",
            query: queryItems,
            on: req
        )

        return payload.earningsCalendar ?? []
    }

    private func fetchJSON<ResponseBody: Decodable>(
        path: String,
        query: [(String, String)],
        on req: Request
    ) async throws -> ResponseBody {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.serviceUnavailable, reason: "FINNHUB_API_KEY is not configured.")
        }

        let uri = try makeURI(path: path, query: query)
        let response = try await req.client.get(uri) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: "X-Finnhub-Token", value: apiKey)
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
        }

        switch response.status {
        case .ok:
            do {
                return try response.content.decode(ResponseBody.self)
            } catch {
                throw Abort(.badGateway, reason: "Failed to decode Finnhub response for \\(path).")
            }

        case .notFound:
            throw Abort(.notFound, reason: "Finnhub resource not found for \\(path).")

        case .unauthorized, .forbidden:
            throw Abort(.badGateway, reason: "Finnhub rejected the request. Check FINNHUB_API_KEY.")

        default:
            let body = response.body
                .flatMap { buffer in
                    buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes)
                }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let reason = body.isEmpty
                ? "Finnhub request failed for \\(path) with status \\(response.status.code)."
                : "Finnhub request failed for \\(path) with status \\(response.status.code): \\(body)"
            throw Abort(.badGateway, reason: reason)
        }
    }

    private func makeURI(path: String, query: [(String, String)]) throws -> URI {
        let trimmedBaseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: trimmedBaseURL + path) else {
            throw Abort(.internalServerError, reason: "Invalid Finnhub base URL configuration.")
        }

        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }

        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "Unable to build Finnhub request URL.")
        }

        return URI(string: url.absoluteString)
    }
}

struct DisabledEarningsProvider: EarningsProvider {
    let name: String = "disabled"

    func fetchCalendar(query _: EarningsQueryRequest, on _: Request) async throws -> [FinnhubEarningsItem] {
        throw Abort(.notImplemented, reason: "Earnings provider fetch is not configured.")
    }
}
