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
            row(symbol: "IBM", type: "Sale"),
        ]).disclosures(for: pelosi)
        #expect(out.map(\.symbol) == ["NVDA", "AAPL", "MSFT", "IBM"])
        #expect(out.map(\.side) == [.buy, .sell, .sellFull, .sell])
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
            row(symbol: "SMCI", assetType: "Stock Option", description: "Super Micro Computer"),
            row(symbol: "WMB", assetType: "Stock Option", description: "The Williams Cos Inc"),
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

    @Test("identical feed rows stay distinct, stably, and for any pilot")
    func duplicates() async throws {
        let src = source([row(), row(), row(symbol: "AAPL")])
        let a = try await src.disclosures(for: pelosi)
        let b = try await src.disclosures(for: pelosi)
        #expect(a.count == 3)
        #expect(Set(a.map(\.sourceKey)).count == 3)
        #expect(a.map(\.sourceKey) == b.map(\.sourceKey))
    }

    @Test("the recorded house feed keeps its three identical Hern rows")
    func fixtureDuplicates() async throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pilots")
        let rows = try JSONDecoder().decode([FMPCongressTrade].self, from: Data(contentsOf: dir.appendingPathComponent("house-latest.json")))
        let hern = PilotSourceIdentity(kind: .politician, chamber: "house", bioguideId: "H001082", aliases: [], cik: nil)
        let out = try await source(rows).disclosures(for: hern)
        let bsx = out.filter { $0.symbol == "BSX" && $0.transactionDate == "2026-09-03" }
        #expect(bsx.count == 3)
        #expect(Set(bsx.map(\.sourceKey)).count == 3)
        #expect(Set(out.map(\.sourceKey)).count == out.count)
    }

    @Test("concurrent callers share one fetch")
    func concurrent() async throws {
        let calls = Counter()
        let src = FMPCongressPilotSource { chamber in
            await calls.increment(chamber)
            try await Task.sleep(for: .milliseconds(100))
            return []
        }
        async let a = src.disclosures(for: pelosi)
        async let b = src.disclosures(for: pelosi)
        _ = try await (a, b)
        #expect(await calls.counts == ["house": 1])
    }

    @Test("a failed fetch is cached for the TTL, then retried")
    func failureCachedThenRetries() async throws {
        let calls = Counter()
        let clock = Clock()
        let src = FMPCongressPilotSource(ttl: 600, now: { clock.date }) { chamber in
            await calls.increment(chamber)
            throw URLError(.timedOut)
        }
        for _ in 0 ..< 2 {
            await #expect(throws: (any Error).self) { _ = try await src.disclosures(for: pelosi) }
        }
        #expect(await calls.counts == ["house": 1])
        clock.advance(601)
        await #expect(throws: (any Error).self) { _ = try await src.disclosures(for: pelosi) }
        #expect(await calls.counts == ["house": 2])
    }

    @Test("the memo expires after the TTL")
    func ttl() async throws {
        let calls = Counter()
        let clock = Clock()
        let src = FMPCongressPilotSource(ttl: 600, now: { clock.date }) { chamber in
            await calls.increment(chamber)
            return []
        }
        _ = try await src.disclosures(for: pelosi)
        clock.advance(599)
        _ = try await src.disclosures(for: pelosi)
        #expect(await calls.counts == ["house": 1])
        clock.advance(2)
        _ = try await src.disclosures(for: pelosi)
        #expect(await calls.counts == ["house": 2])
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var date: Date {
        lock.lock(); defer { lock.unlock() }; return current
    }

    func advance(_ s: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(s); lock.unlock()
    }
}

private actor Counter {
    var counts: [String: Int] = [:]
    func increment(_ key: String) {
        counts[key, default: 0] += 1
    }
}
