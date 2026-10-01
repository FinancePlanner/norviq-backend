import Fluent
import Foundation
import SQLKit

/// CUSIP → US ticker through OpenFIGI's free mapping API, cached forever in
/// `cusip_symbols`. A CUSIP OpenFIGI cannot map is cached as NULL, so it is
/// not asked again. Unauthenticated OpenFIGI allows 10 jobs per request and
/// 25 requests a minute, so `pause` runs between batches (2.5 s in production).
struct CusipSymbolResolver: Sendable {
    static let batchSize = 10

    private let post: @Sendable (_ body: Data) async throws -> Data
    private let pause: @Sendable () async -> Void

    init(post: @escaping @Sendable (_ body: Data) async throws -> Data, pause: @escaping @Sendable () async -> Void) {
        self.post = post
        self.pause = pause
    }

    private struct Job: Encodable {
        let idType = "ID_CUSIP"
        let idValue: String
        let exchCode = "US"
    }

    private struct Result: Decodable {
        struct Match: Decodable { let ticker: String? }
        let data: [Match]?
    }

    func resolve(_ cusips: [String], on db: any Database) async throws -> [String: String] {
        guard let sql = db as? any SQLDatabase else { return [:] }
        // Input order, de-duplicated: the request order is deterministic.
        var seen = Set<String>()
        let wanted = cusips.filter { seen.insert($0).inserted }
        guard !wanted.isEmpty else { return [:] }

        struct Cached: Decodable { let cusip: String; let symbol: String? }
        let cached = try await sql.raw("SELECT cusip, symbol FROM cusip_symbols WHERE cusip = ANY(\(bind: wanted))").all(decoding: Cached.self)
        var out: [String: String] = [:]
        var known = Set<String>()
        for row in cached {
            known.insert(row.cusip)
            if let symbol = row.symbol {
                out[row.cusip] = symbol
            }
        }

        let missing = wanted.filter { !known.contains($0) }
        for (index, start) in stride(from: 0, to: missing.count, by: Self.batchSize).enumerated() {
            if index > 0 {
                await pause()
            }
            let batch = Array(missing[start ..< min(start + Self.batchSize, missing.count)])
            let response = try await post(JSONEncoder().encode(batch.map { Job(idValue: $0) }))
            let results = try JSONDecoder().decode([Result].self, from: response)
            for (cusip, result) in zip(batch, results) {
                let ticker = result.data?.compactMap(\.ticker).first?.uppercased()
                if let ticker {
                    out[cusip] = ticker
                }
                try await sql.raw("""
                INSERT INTO cusip_symbols (cusip, symbol) VALUES (\(bind: cusip), \(bind: ticker))
                ON CONFLICT (cusip) DO NOTHING
                """).run()
            }
        }
        return out
    }
}

typealias CusipResolve = @Sendable (_ cusips: [String]) async throws -> [String: String]
