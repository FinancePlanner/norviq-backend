import Fluent
import Foundation
import NIOCore
import Vapor

final class MarketHistoryIngestionJob: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private var scheduled: RepeatedTask?
    private let lock = NSLock()
    private var running = false

    init(intervalSeconds: Int64 = 86400) {
        self.intervalSeconds = max(intervalSeconds, 3600)
    }

    func didBoot(_ app: Application) throws {
        guard envBool("SCENARIO_PLANNING_ENABLED", default: false) else { return }
        scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: .seconds(30), delay: .seconds(intervalSeconds)) { _ in
            guard self.begin() else { return }
            Task { defer { self.finish() }; await self.runOnce(app) }
        }
    }

    func shutdown(_: Application) {
        lock.lock(); scheduled?.cancel(); scheduled = nil; lock.unlock()
    }

    func runOnce(_ app: Application) async {
        do {
            let holdingSymbols = try await Stock.query(on: app.db).all().map { $0.symbol.uppercased() }
            let proxies = try await HoldingRiskProfileModel.query(on: app.db).all().compactMap { $0.benchmarkProxy?.uppercased() }
            for symbol in Set(holdingSymbols + proxies).sorted() {
                try await ingest(symbol: symbol, app: app)
            }
        } catch { app.logger.warning("scenario_history_ingestion failed error=\(error)") }
    }

    private func ingest(symbol: String, app: Application) async throws {
        let calendar = Calendar(identifier: .gregorian); let today = calendar.startOfDay(for: Date())
        let fallbackStart = calendar.date(byAdding: .year, value: -30, to: today) ?? today
        let coverage = try await MarketPriceBarRepository().coverage(instrumentKey: symbol, from: fallbackStart, to: today, on: app.db)
        let incrementalStart = coverage.lastDate.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? fallbackStart
        let start = coverage.missingWeekdays > 5 ? fallbackStart : incrementalStart
        guard start <= today else { return }
        let request = Request(application: app, on: app.eventLoopGroup.next())
        let response = try await app.marketDataService.refreshHistory(
            symbol: symbol, from: Self.day(start), to: Self.day(today), on: request
        )
        try await MarketPriceBarRepository().upsert(
            instrumentKey: symbol, currency: response.currency, provider: "market", bars: response.bars, on: app.db
        )
        let updatedCoverage = try await MarketPriceBarRepository().coverage(
            instrumentKey: symbol, from: fallbackStart, to: today, on: app.db
        )
        PrometheusMetrics.shared.recordScenarioHistoryCoverage(
            covered: updatedCoverage.barCount,
            expected: updatedCoverage.barCount + updatedCoverage.missingWeekdays
        )
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date)
    }

    private func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }; guard !running else { return false }; running = true; return true
    }

    private func finish() {
        lock.lock(); running = false; lock.unlock()
    }
}
