import Foundation
@testable import StockPlanBackend
import Testing

@Suite("FMPCongressPilotSource")
struct FMPCongressPilotSourceTests {
    private func row(first: String = "Nancy", last: String = "Pelosi", id: String? = "P000197", symbol: String? = "NVDA", type: String = "Purchase", amount: String = "$1,000,001 - $5,000,000", assetType: String? = "Stock", description: String? = nil) -> FMPCongressTrade {
        FMPCongressTrade(symbol: symbol, disclosureDate: "2026-07-01", transactionDate: "2026-06-20", firstName: first, lastName: last, office: nil, district: "CA11", state: "CA", party: "Democrat", owner: "Spouse", assetDescription: description, assetType: assetType, type: type, amount: amount, link: "https://example.test/\(symbol ?? "x")", senateID: id)
    }

    private let pelosi = PilotSourceIdentity(kind: .politician, chamber: "house", bioguideId: "P000197", aliases: ["Nancy Pelosi"], cik: nil)

    private func source(_ rows: [FMPCongressTrade]) -> FMPCongressPilotSource {
        FMPCongressPilotSource { _ in rows }
    }

    @Test("maps purchase, partial sale and full sale; drops exchanges")
    func sides() async throws {
        let out = try await source([
            row(type: "Purchase"),
            row(symbol: "AAPL", type: "Sale (Partial)"),
            row(symbol: "MSFT", type: "Sale (Full)"),
            row(symbol: "KO", type: "Exchange"),
        ]).disclosures(for: pelosi)
        #expect(out.map(\.symbol) == ["NVDA", "AAPL", "MSFT"])
        #expect(out.map(\.side) == [.buy, .sell, .sellFull])
        #expect(out[0].amountMin == 1_000_001)
        #expect(out[0].amountMax == 5_000_000)
    }

    @Test("options: calls and puts detected; bonds and funds dropped")
    func instruments() async throws {
        let out = try await source([
            row(assetType: "Stock Option", description: "NVIDIA Corp - Call options; strike $120"),
            row(symbol: "SPY", assetType: "Stock Option", description: "SPDR S&P 500 Put"),
            row(symbol: "T 4 1/2", assetType: "Corporate Bond"),
            row(symbol: "VFIAX", assetType: "Mutual Fund"),
            row(symbol: "QQQ", assetType: "ETF"),
        ]).disclosures(for: pelosi)
        #expect(out.map(\.symbol) == ["NVDA", "SPY", "QQQ"])
        #expect(out.map(\.instrument) == [.call, .put, .stock])
    }

    @Test("matches by bioguide id; falls back to exact alias when the id is missing")
    func matching() async throws {
        let out = try await source([
            row(first: "Paul", last: "Pelosi", id: "X000001", symbol: "AAA"),
            row(first: "Nancy", last: "Pelosi", id: nil, symbol: "BBB"),
            row(first: "N.", last: "Pelosi", id: "P000197", symbol: "CCC"),
            row(symbol: nil),
        ]).disclosures(for: pelosi)
        #expect(out.map(\.symbol) == ["BBB", "CCC"])
    }

    @Test("the feed is fetched once per chamber within the TTL, across pilots")
    func memoized() async throws {
        let calls = Counter()
        let src = FMPCongressPilotSource { chamber in
            await calls.increment(chamber)
            return []
        }
        let other = PilotSourceIdentity(kind: .politician, chamber: "house", bioguideId: "H001082", aliases: ["Kevin Hern"], cik: nil)
        _ = try await src.disclosures(for: pelosi)
        _ = try await src.disclosures(for: other)
        #expect(await calls.counts == ["house": 1])
    }

    @Test("source key is stable across calls and distinct per row")
    func sourceKey() async throws {
        let src = source([row(), row(symbol: "AAPL")])
        let a = try await src.disclosures(for: pelosi)
        let b = try await src.disclosures(for: pelosi)
        #expect(a.map(\.sourceKey) == b.map(\.sourceKey))
        #expect(Set(a.map(\.sourceKey)).count == 2)
    }

    @Test("decodes the recorded FMP fixtures, senateID included")
    func fixtures() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pilots")
        for name in ["house-latest.json", "senate-latest.json"] {
            let rows = try JSONDecoder().decode([FMPCongressTrade].self, from: Data(contentsOf: dir.appendingPathComponent(name)))
            #expect(rows.count == 25)
            #expect(rows.allSatisfy { $0.senateID?.isEmpty == false })
        }
    }
}

private actor Counter {
    var counts: [String: Int] = [:]
    func increment(_ key: String) {
        counts[key, default: 0] += 1
    }
}
