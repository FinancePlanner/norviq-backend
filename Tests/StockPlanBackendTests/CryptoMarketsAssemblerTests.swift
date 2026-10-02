import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Crypto markets assembler")
struct CryptoMarketsAssemblerTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21

    private static func coin(
        _ id: String,
        rank: Int,
        marketCap: Double = 1e9,
        volume: Double = 1e8,
        day: Double? = nil,
        week: Double? = nil,
        ytd: Double? = nil,
        athChange: Double? = nil,
        athDate: String? = nil
    ) -> CryptoMarketCoin {
        CryptoMarketCoin(
            id: id, symbol: id.uppercased(), name: id, rank: rank, sector: "Other",
            price: 1, marketCap: marketCap, volume24h: volume,
            returns: .init(oneDay: day, oneWeek: week, yearToDate: ytd),
            athChangePct: athChange, athDate: athDate
        )
    }

    private static func snapshot(_ coins: [CryptoMarketCoin]) -> CryptoMarketSnapshot {
        CryptoMarketSnapshot(
            source: "coingecko", attribution: "Data provided by CoinGecko",
            asOf: "2026-09-21T00:00:00Z", totalMarketCap: 5e9, btcDominancePct: 40, coins: coins
        )
    }

    private func assemble(
        _ coins: [CryptoMarketCoin],
        _ timeframe: CryptoMarketsTimeframe,
        limit: Int = 100,
        filter: CryptoMarketsFilter = .init(minMarketCap: 1e8, minVolume24h: 1e6, listSize: 10)
    ) -> CryptoMarketsResponse {
        CryptoMarketsAssembler.assemble(
            snapshot: Self.snapshot(coins), timeframe: timeframe, limit: limit,
            isStale: false, filter: filter, now: Self.now
        )
    }

    @Test("changePct follows the requested window")
    func changeFollowsTimeframe() {
        let coins = [Self.coin("a", rank: 1, day: 1, week: 7, athChange: -20)]
        #expect(assemble(coins, .oneDay).coins.first?.changePct == 1)
        #expect(assemble(coins, .oneWeek).coins.first?.changePct == 7)
        #expect(assemble(coins, .allTime).coins.first?.changePct == -20)
        #expect(assemble(coins, .oneMonth).coins.first?.changePct == nil)
    }

    @Test("limit keeps the top coins by rank")
    func limitTruncates() {
        let coins = (1 ... 5).map { Self.coin("c\($0)", rank: $0, day: 1) }
        #expect(assemble(coins, .oneDay, limit: 3).coins.map(\.id) == ["c1", "c2", "c3"])
    }

    @Test("gainers are positive descending, losers negative ascending, both capped")
    func performersSplitAndCap() {
        let coins = (1 ... 30).map { Self.coin("c\($0)", rank: $0, day: Double($0 - 15)) }
        let response = assemble(coins, .oneDay)
        #expect(response.gainers.count == 10)
        #expect(response.gainers.first?.changePct == 15)
        #expect(response.gainers.allSatisfy { ($0.changePct ?? 0) > 0 })
        #expect(response.losers.count == 10)
        #expect(response.losers.first?.changePct == -14)
        #expect(response.losers.allSatisfy { ($0.changePct ?? 0) < 0 })
    }

    @Test("performers skip illiquid and unknown coins but the coin list keeps them")
    func performersFilterLiquidity() {
        let coins = [
            Self.coin("big", rank: 1, day: 5),
            Self.coin("tinycap", rank: 2, marketCap: 1e6, day: 900),
            Self.coin("novolume", rank: 3, volume: 10, day: 800),
            Self.coin("unknown", rank: 4, day: nil),
        ]
        let response = assemble(coins, .oneDay)
        #expect(response.gainers.map(\.id) == ["big"])
        #expect(response.coins.count == 4)
    }

    @Test("all-time ranks by distance from the high")
    func allTimeOrdering() {
        let coins = [
            Self.coin("near", rank: 1, athChange: -2),
            Self.coin("mid", rank: 2, athChange: -40),
            Self.coin("deep", rank: 3, athChange: -95),
        ]
        let response = assemble(coins, .allTime)
        #expect(response.gainers.map(\.id) == ["near", "mid", "deep"])
        #expect(response.losers.map(\.id) == ["deep", "mid", "near"])
        #expect(response.colorMode == .athDistance)
    }

    @Test("ATH board: recent highs within 30 days, newest first")
    func athBoard() {
        let coins = [
            Self.coin("fresh", rank: 1, athChange: -1, athDate: "2026-09-20T10:00:00.000Z"),
            Self.coin("lastweek", rank: 2, athChange: -3, athDate: "2026-09-14T10:00:00.000Z"),
            Self.coin("old", rank: 3, athChange: -60, athDate: "2021-11-10T00:00:00.000Z"),
        ]
        let board = assemble(coins, .oneDay).athBoard
        #expect(board.recentAths.map(\.id) == ["fresh", "lastweek"])
        #expect(board.nearAth.first?.id == "fresh")
        #expect(board.deepestDrawdowns.first?.id == "old")
    }

    @Test("colour scale widens with the window")
    func colorScales() {
        let expected: [CryptoMarketsTimeframe: Double] = [
            .oneDay: 5, .oneWeek: 15, .oneMonth: 30, .yearToDate: 100, .oneYear: 100, .allTime: 90,
        ]
        for (timeframe, maxPct) in expected {
            #expect(CryptoMarketsAssembler.colorScale(for: timeframe).maxPct == maxPct)
        }
    }

    @Test("supported timeframes drop windows no coin can answer")
    func supportedTimeframes() {
        let withoutYTD = [Self.coin("a", rank: 1, day: 1, week: 2, athChange: -5)]
        #expect(assemble(withoutYTD, .oneDay).supportedTimeframes == [.oneDay, .oneWeek, .allTime])
        let withYTD = [Self.coin("a", rank: 1, day: 1, ytd: 3)]
        #expect(assemble(withYTD, .oneDay).supportedTimeframes.contains(.yearToDate))
    }

    @Test("advancers and decliners count the window's movers")
    func summaryCounts() {
        let coins = [
            Self.coin("up", rank: 1, day: 2),
            Self.coin("down", rank: 2, day: -1),
            Self.coin("flat", rank: 3, day: 0),
        ]
        let summary = assemble(coins, .oneDay).summary
        #expect(summary.advancers == 1)
        #expect(summary.decliners == 1)
        #expect(summary.totalMarketCap == 5e9)
    }

    @Test("downsampling keeps endpoints and the requested count")
    func downsample() {
        let points = (0 ..< 168).map(Double.init)
        let sampled = CryptoMarketsAssembler.downsample(points, to: 28)
        #expect(sampled.count == 28)
        #expect(sampled.first == 0)
        #expect(sampled.last == 167)
        #expect(CryptoMarketsAssembler.downsample([1, 2, 3], to: 28) == [1, 2, 3])
    }
}
