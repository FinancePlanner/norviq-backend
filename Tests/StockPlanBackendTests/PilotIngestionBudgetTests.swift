import Foundation
@testable import StockPlanBackend
import Testing

/// G6: congress ingestion runs every two hours (two FMP feed reads per run,
/// about 24 calls a day) and the feed memo outlives one run.
@Suite("Pilot ingestion FMP budget")
struct PilotIngestionBudgetTests {
    @Test("ingestion defaults to every 7200 s and the memo TTL covers a whole run")
    func defaults() {
        #expect(PilotIngestionJob.defaultIntervalSeconds == 7200)
        #expect(FMPCongressPilotSource.defaultMemoTTL >= TimeInterval(PilotIngestionJob.defaultIntervalSeconds))
        // Two chambers per run, twelve runs a day.
        #expect(2 * 86400 / Int(PilotIngestionJob.defaultIntervalSeconds) == 24)
    }

    @Test("with the default TTL a chamber feed is fetched once across a full run")
    func defaultMemoSpansARun() async throws {
        final class Clock: @unchecked Sendable {
            var date = Date(timeIntervalSince1970: 1_800_000_000)
        }
        actor Calls {
            var count = 0
            func hit() {
                count += 1
            }
        }
        let clock = Clock()
        let calls = Calls()
        let source = FMPCongressPilotSource(now: { clock.date }) { _ in
            await calls.hit()
            return []
        }
        let pilot = PilotSourceIdentity(kind: .politician, chamber: "house", bioguideId: "P000197", aliases: ["Nancy Pelosi"], cik: nil)
        _ = try await source.disclosures(for: pilot)
        clock.date = clock.date.addingTimeInterval(TimeInterval(PilotIngestionJob.defaultIntervalSeconds) - 1)
        _ = try await source.disclosures(for: pilot)
        #expect(await calls.count == 1)
    }
}
