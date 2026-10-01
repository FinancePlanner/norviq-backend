import Foundation

/// A fund's latest 13F holdings from SEC EDGAR. Free, no key. EDGAR requires a
/// descriptive User-Agent and at most 10 requests a second; the caller's `get`
/// sets the header. One lookup is three requests.
struct SECEdgar13FPilotSource: PilotDisclosureSource {
    typealias Get = @Sendable (_ url: String) async throws -> Data

    private let get: Get
    private let resolve: CusipResolve

    init(get: @escaping Get, resolve: @escaping CusipResolve) {
        self.get = get
        self.resolve = resolve
    }

    func disclosures(for pilot: PilotSourceIdentity) async throws -> [PilotDisclosureInput] {
        guard let rawCik = pilot.cik, let cikNumber = Int(rawCik) else { return [] }
        let padded = String(format: "%010d", cikNumber)
        guard let filing = try await EDGAR13FParser.latest13F(submissions: get("https://data.sec.gov/submissions/CIK\(padded).json")) else {
            return []
        }
        let folder = "https://www.sec.gov/Archives/edgar/data/\(cikNumber)/\(filing.accession.replacingOccurrences(of: "-", with: ""))"
        guard let table = try await EDGAR13FParser.infoTableName(index: get("\(folder)/index.json")) else { return [] }
        let holdings = try await EDGAR13FParser.holdings(infoTable: get("\(folder)/\(table)"))
        let symbols = try await resolve(holdings.map(\.cusip))
        let period = filing.period
        return holdings.compactMap { holding in
            guard let symbol = symbols[holding.cusip] else { return nil }
            return PilotDisclosureInput(
                sourceKey: "\(period)|\(holding.cusip)",
                symbol: symbol,
                side: .hold,
                instrument: .stock,
                transactionDate: nil,
                disclosureDate: nil,
                amountMin: nil,
                amountMax: nil,
                shares: holding.shares,
                marketValue: holding.value,
                period: period
            )
        }
    }
}
