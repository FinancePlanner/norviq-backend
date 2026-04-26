import Foundation
import Vapor

struct IBKRMarketDataProvider: MarketDataProvider {
    let baseURL: String
    let defaultCurrency: String

    var name: String {
        "ibkr"
    }

    init(
        baseURL: String = Environment.get("IBKR_API_BASE_URL") ?? "http://localhost:5000/v1/api",
        defaultCurrency: String = Environment.get("MARKET_DEFAULT_CURRENCY") ?? "USD"
    ) {
        self.baseURL = baseURL
        self.defaultCurrency = defaultCurrency
    }

    func quote(symbol rawSymbol: String, on req: Request) async throws -> MarketProviderQuote {
        let symbol = try normalizeSymbol(rawSymbol)
        let instrument = try await resolveInstrument(for: symbol, on: req)
        let rows = try await fetchSnapshot(
            conid: instrument.conid,
            fields: ["31", "55", "84", "86", "7059", "_updated"],
            on: req
        )

        guard let row = selectSnapshotRow(symbol: symbol, in: rows) ?? rows.first else {
            throw Abort(.badGateway, reason: "IBKR quote response did not include a snapshot row.")
        }

        guard let price = parseDouble(row["31"] ?? row["84"] ?? row["86"]) else {
            throw Abort(.badGateway, reason: "IBKR quote response did not include a valid price.")
        }

        let asOf = parseEpochMilliseconds(row["_updated"]) ?? Date()
        let currency = parseString(row["7059"]) ?? instrument.currency
        return MarketProviderQuote(symbol: symbol, price: price, change: nil, percentChange: nil, high: nil, low: nil, open: nil, previousClose: nil, currency: currency, asOf: asOf)
    }

    func history(symbol rawSymbol: String, from: Date?, to: Date?, on req: Request) async throws -> MarketProviderHistory {
        let symbol = try normalizeSymbol(rawSymbol)
        let instrument = try await resolveInstrument(for: symbol, on: req)

        let uri = makeURL(
            path: "/iserver/marketdata/history",
            query: [
                ("conid", instrument.conid),
                ("period", "1y"),
                ("bar", "1d"),
                ("outsideRth", "true"),
            ]
        )

        let response = try await req.client.get(URI(string: uri)) { clientRequest in
            clientRequest.timeout = .seconds(30)
        }
        guard response.status == HTTPResponseStatus.ok else {
            throw Abort(.badGateway, reason: "IBKR history request failed with status \(response.status.code).")
        }

        let payload = try response.content.decode(IBKRHistoryPayload.self)
        var bars = payload.data.compactMap(toMarketBar)
        if let from {
            bars.removeAll { $0.date < from }
        }
        if let to {
            bars.removeAll { $0.date > to }
        }
        bars.sort { $0.date < $1.date }

        return MarketProviderHistory(
            symbol: symbol,
            currency: payload.currency ?? instrument.currency,
            bars: bars
        )
    }

    func search(query rawQuery: String, on req: Request) async throws -> [MarketProviderSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !query.isEmpty else {
            throw Abort(.badRequest, reason: "Query is required.")
        }

        let uri = makeURL(path: "/iserver/secdef/search")
        let response = try await req.client.post(URI(string: uri)) { clientRequest in
            clientRequest.headers.contentType = .json
            clientRequest.timeout = .seconds(30)
            try clientRequest.content.encode(IBKRSearchRequest(symbol: query))
        }

        guard response.status == HTTPResponseStatus.ok else {
            throw Abort(.badGateway, reason: "IBKR search request failed with status \(response.status.code).")
        }

        let payload = try response.content.decode([IBKRSearchItem].self)
        return payload.compactMap { item in
            guard
                let symbol = item.symbol?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
                !symbol.isEmpty,
                let conid = item.conid?.stringValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
                !conid.isEmpty
            else {
                return nil
            }

            let resolvedName = firstNonEmpty(item.companyName, item.companyHeader, item.name, item.description) ?? symbol
            let resolvedExchange = firstNonEmpty(item.listingExchange, item.exchange) ?? "UNKNOWN"
            let resolvedCurrency = item.currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? defaultCurrency

            return MarketProviderSearchResult(
                symbol: symbol.uppercased(),
                name: resolvedName,
                exchange: resolvedExchange,
                currency: resolvedCurrency,
                conid: conid
            )
        }
    }

    func fx(base rawBase: String, quote rawQuote: String, on req: Request) async throws -> MarketProviderFxRate {
        let base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let quote = rawQuote.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard base.count == 3, quote.count == 3 else {
            throw Abort(.badRequest, reason: "Invalid FX pair. Use 3-letter currency codes.")
        }

        if base == quote {
            return MarketProviderFxRate(base: base, quote: quote, rate: 1.0, asOf: Date())
        }

        let candidates = try await search(query: base, on: req)
        guard let instrument = candidates.first(where: { $0.currency == quote }) ?? candidates.first else {
            throw Abort(.notFound, reason: "No IBKR instrument found for \(base)/\(quote).")
        }

        let rows = try await fetchSnapshot(
            conid: instrument.conid,
            fields: ["31", "84", "_updated"],
            on: req
        )

        guard let row = rows.first else {
            throw Abort(.badGateway, reason: "IBKR FX response did not include a snapshot row.")
        }

        guard let rate = parseDouble(row["31"] ?? row["84"]) else {
            throw Abort(.badGateway, reason: "IBKR FX response did not include a valid rate.")
        }

        let asOf = parseEpochMilliseconds(row["_updated"]) ?? Date()
        return MarketProviderFxRate(base: base, quote: quote, rate: rate, asOf: asOf)
    }

    func profile(symbol _: String, on _: Request) async throws -> MarketProviderCompanyProfile? {
        nil // IBKR doesn't natively expose a /profile equivalent.
    }

    func basicFinancials(symbol _: String, on _: Request) async throws -> MarketProviderBasicFinancials? {
        nil // IBKR doesn't natively expose a /stock/metric equivalent.
    }
}

private extension IBKRMarketDataProvider {
    func resolveInstrument(for symbol: String, on req: Request) async throws -> MarketProviderSearchResult {
        let results = try await search(query: symbol, on: req)

        if let exact = results.first(where: { $0.symbol == symbol }) {
            return exact
        }

        guard let fallback = results.first else {
            throw Abort(.notFound, reason: "No IBKR instrument found for symbol \(symbol).")
        }
        return fallback
    }

    func fetchSnapshot(
        conid: String,
        fields: [String],
        on req: Request
    ) async throws -> [[String: LossyValue]] {
        let uri = makeURL(
            path: "/iserver/marketdata/snapshot",
            query: [
                ("conids", conid),
                ("fields", fields.joined(separator: ",")),
            ]
        )

        let response = try await req.client.get(URI(string: uri)) { clientRequest in
            clientRequest.timeout = .seconds(30)
        }
        guard response.status == HTTPResponseStatus.ok else {
            throw Abort(.badGateway, reason: "IBKR snapshot request failed with status \(response.status.code).")
        }

        if let rows = try? response.content.decode([[String: LossyValue]].self) {
            return rows
        }
        if let row = try? response.content.decode([String: LossyValue].self) {
            return [row]
        }

        throw Abort(.badGateway, reason: "IBKR snapshot response format was not recognized.")
    }

    func selectSnapshotRow(symbol: String, in rows: [[String: LossyValue]]) -> [String: LossyValue]? {
        rows.first(where: { parseString($0["55"])?.uppercased() == symbol })
    }

    func makeURL(path: String, query: [(String, String)] = []) -> String {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let joined = base + "/" + normalizedPath
        guard !query.isEmpty else { return joined }

        let encoded = query.map { key, value in
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return key + "=" + encodedValue
        }
        .joined(separator: "&")

        return joined + "?" + encoded
    }

    func parseString(_ value: LossyValue?) -> String? {
        guard let value else { return nil }
        let trimmed = value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func parseDouble(_ value: LossyValue?) -> Double? {
        guard let raw = parseString(value) else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: ""))
    }

    func parseEpochMilliseconds(_ value: LossyValue?) -> Date? {
        guard let numeric = parseDouble(value) else { return nil }
        return Date(timeIntervalSince1970: numeric / 1000)
    }

    func toMarketBar(_ raw: IBKRHistoryBar) -> MarketProviderPriceBar? {
        guard
            let open = raw.o,
            let high = raw.h,
            let low = raw.l,
            let close = raw.c
        else {
            return nil
        }

        let date: Date? = if let millis = parseDouble(raw.t ?? raw.time) {
            Date(timeIntervalSince1970: millis / 1000)
        } else if let dateValue = raw.date {
            parseIBKRDate(dateValue)
        } else {
            nil
        }

        guard let resolvedDate = date else { return nil }

        let volume = raw.v.flatMap { Int($0) }
        return MarketProviderPriceBar(
            date: resolvedDate,
            open: open,
            high: high,
            low: low,
            close: close,
            volume: volume
        )
    }

    func parseIBKRDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.count == 8, let parsed = parseDate(trimmed, format: "yyyyMMdd") {
            return parsed
        }

        if let parsed = parseDate(trimmed, format: "yyyy-MM-dd") {
            return parsed
        }

        if let parsed = ISO8601DateFormatter().date(from: trimmed) {
            return parsed
        }

        return nil
    }

    func parseDate(_ raw: String, format: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter.date(from: raw)
    }

    func normalizeSymbol(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "Symbol is required.")
        }
        return normalized
    }

    func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first(where: { !$0.isEmpty })
    }
}

private struct IBKRSearchRequest: Content {
    let symbol: String
}

private struct IBKRSearchItem: Decodable {
    let symbol: String?
    let companyName: String?
    let companyHeader: String?
    let name: String?
    let description: String?
    let listingExchange: String?
    let exchange: String?
    let currency: String?
    let conid: LossyValue?
}

private struct IBKRHistoryPayload: Decodable {
    let currency: String?
    let data: [IBKRHistoryBar]
}

private struct IBKRHistoryBar: Decodable {
    let o: Double?
    let h: Double?
    let l: Double?
    let c: Double?
    let v: Double?
    let t: LossyValue?
    let time: LossyValue?
    let date: String?
}

private struct LossyValue: Decodable {
    let stringValue: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(String.self) {
            stringValue = value
            return
        }

        if let value = try? container.decode(Int.self) {
            stringValue = String(value)
            return
        }

        if let value = try? container.decode(Int64.self) {
            stringValue = String(value)
            return
        }

        if let value = try? container.decode(Double.self) {
            stringValue = String(value)
            return
        }

        if let value = try? container.decode(Bool.self) {
            stringValue = value ? "true" : "false"
            return
        }

        if container.decodeNil() {
            stringValue = ""
            return
        }

        throw DecodingError.typeMismatch(
            String.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value.")
        )
    }
}
