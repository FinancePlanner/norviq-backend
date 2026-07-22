import Foundation
import Vapor

/// Banco Central do Brasil SGS time-series client (no API key).
/// Docs: https://dadosabertos.bcb.gov.br/dataset/1178-taxa-de-juros---selic
struct BCBSgsProvider: Sendable {
    let name = "bcb_sgs"
    var baseURL: String = "https://api.bcb.gov.br"

    /// Selic target rate (meta). Code 432 — daily percent.
    static let selicMetaCode = 432

    struct Observation: Equatable {
        let date: String // yyyy-MM-dd
        let value: Double
    }

    func fetchSelic(on req: Request, lastN: Int = 260) async throws -> [Observation] {
        try await fetchSeries(code: Self.selicMetaCode, lastN: lastN, on: req)
    }

    func fetchSeries(code: Int, lastN: Int, on req: Request) async throws -> [Observation] {
        let path = "/dados/serie/bcdata.sgs.\(code)/dados/ultimos/\(max(lastN, 1))"
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: trimmed + path) else {
            throw Abort(.internalServerError, reason: "Invalid BCB base URL.")
        }
        components.queryItems = [URLQueryItem(name: "formato", value: "json")]
        guard let url = components.url else {
            throw Abort(.internalServerError, reason: "Unable to build BCB request URL.")
        }
        let response = try await req.client.get(URI(string: url.absoluteString)) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.timeout = .seconds(20)
        }
        guard response.status == .ok else {
            throw Abort(.badGateway, reason: "BCB SGS request failed with status \(response.status.code).")
        }
        let rows: [BCBSgsRow]
        do {
            rows = try response.content.decode([BCBSgsRow].self)
        } catch {
            throw Abort(.badGateway, reason: "Failed to decode BCB SGS response.")
        }
        return Self.parse(rows)
    }

    static func parse(_ rows: [BCBSgsRow]) -> [Observation] {
        rows.compactMap { row in
            guard let value = Double(row.valor.replacingOccurrences(of: ",", with: ".")) else { return nil }
            let date = normalizeDate(row.data)
            return Observation(date: date, value: (value * 100).rounded() / 100)
        }
    }

    /// BCB dates arrive as `dd/MM/yyyy`.
    static func normalizeDate(_ raw: String) -> String {
        let parts = raw.split(separator: "/")
        guard parts.count == 3 else { return raw }
        let day = parts[0]
        let month = parts[1]
        let year = parts[2]
        return "\(year)-\(month)-\(day)"
    }
}

struct BCBSgsRow: Decodable {
    let data: String
    let valor: String
}
