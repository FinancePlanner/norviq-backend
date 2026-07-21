import Fluent
import Foundation
import NIOCore
import Vapor

final class ThesisWatchIngestionJob: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let maxSymbolsPerRun: Int
    private let state = ThesisWatchIngestionState()
    private var scheduled: RepeatedTask?

    init(intervalSeconds: Int64 = 900, maxSymbolsPerRun: Int = 30) {
        self.intervalSeconds = max(intervalSeconds, 300)
        self.maxSymbolsPerRun = max(maxSymbolsPerRun, 1)
    }

    func didBoot(_ app: Application) throws {
        scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .seconds(45),
            delay: .seconds(intervalSeconds)
        ) { _ in
            Task { await self.tick(app) }
        }
    }

    func shutdown(_: Application) {
        scheduled?.cancel()
        scheduled = nil
    }

    func runOnce(_ app: Application) async {
        await tick(app)
    }

    private func tick(_ app: Application) async {
        guard await state.begin() else {
            app.logger.debug("thesis_watch_ingestion skipped overlapping tick")
            return
        }
        defer { Task { await state.finish() } }

        do {
            let holdingSymbols = try await Stock.query(on: app.db).all().map(\.symbol)
            let watchlistSymbols = try await WatchlistItem.query(on: app.db)
                .filter(\.$status == "active")
                .all()
                .map(\.symbol)
            let symbols = Array(Set(holdingSymbols + watchlistSymbols)).sorted()
            let batch = await state.nextBatch(from: symbols, limit: maxSymbolsPerRun)
            let request = Request(application: app, on: app.eventLoopGroup.next())
            try await app.marketNewsArchiveService.refreshTrackedNews(symbols: batch, on: request)
            _ = try? await app.marketNewsArchiveService.generalNews(limit: 50, on: request)
            try await app.thesisWatchService.refreshClusters(on: app.db)
            app.logger.info("thesis_watch_ingestion ok refreshed_symbols=\(batch.count) tracked_symbols=\(symbols.count)")
        } catch {
            app.logger.warning("thesis_watch_ingestion failed error=\(String(describing: error))")
        }
    }
}

private actor ThesisWatchIngestionState {
    private var isRunning = false
    private var cursor = 0

    func begin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    func finish() {
        isRunning = false
    }

    func nextBatch(from symbols: [String], limit: Int) -> [String] {
        guard !symbols.isEmpty else {
            cursor = 0
            return []
        }
        let count = min(limit, symbols.count)
        let batch = (0 ..< count).map { symbols[(cursor + $0) % symbols.count] }
        cursor = (cursor + count) % symbols.count
        return batch
    }
}
