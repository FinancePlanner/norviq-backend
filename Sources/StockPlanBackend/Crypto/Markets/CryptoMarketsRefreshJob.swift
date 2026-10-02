import Foundation
import NIOCore
import Vapor

/// Keeps the crypto markets snapshot warm so requests never wait on
/// CoinGecko. Mirrors MacroRefreshJob: repeated task, overlap guard, leader
/// lock across replicas, `runOnce` for tests.
final class CryptoMarketsRefreshJob: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    /// FMP history calls per tick for missing YTD bases (0 disables). Kept
    /// small: FMP's quota is shared with stock quotes and news. Once the
    /// covered coins have a base, ticks cost nothing extra until next year.
    private let ytdFillBudget: Int
    private let initialDelaySeconds: Int64
    private let state = BackgroundJobState()

    init(intervalSeconds: Int64, ytdFillBudget: Int = 5, initialDelaySeconds: Int64 = 15) {
        self.ytdFillBudget = max(ytdFillBudget, 0)
        // Floor protects the CoinGecko monthly quota from a mistyped env var.
        self.intervalSeconds = max(intervalSeconds, 120)
        self.initialDelaySeconds = max(initialDelaySeconds, 0)
    }

    func didBoot(_ app: Application) throws {
        guard app.environment != .testing else {
            app.logger.debug("crypto_markets_refresh not scheduled in testing environment")
            return
        }
        app.logger.info("crypto_markets_refresh scheduled interval=\(intervalSeconds)s")

        let eventLoop = app.eventLoopGroup.next()
        let scheduled = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(initialDelaySeconds),
            delay: .seconds(intervalSeconds)
        ) { _ in
            guard self.state.begin() else {
                app.logger.debug("crypto_markets_refresh skipped overlapping tick")
                return
            }
            let task = Task {
                defer { self.state.finish() }
                await self.tick(app)
            }
            self.state.track(task: task)
        }
        state.set(scheduled: scheduled)
    }

    func shutdown(_: Application) {
        state.stopAcceptingRuns()
    }

    func shutdownAsync(_: Application) async {
        await state.stopAndDrain()
    }

    func runOnce(_ app: Application) async {
        await tick(app)
    }

    private func tick(_ app: Application) async {
        await JobLock.runAsLeader(app, name: "crypto_markets_refresh_job") {
            if Task.isCancelled {
                return
            }
            let req = Request(application: app, on: app.eventLoopGroup.next())
            do {
                let snapshot = try await app.cryptoMarketsService.refreshSnapshot(
                    ytdFillBudget: self.ytdFillBudget, on: req
                )
                app.logger.info("crypto_markets_refresh ok source=\(snapshot.source) coins=\(snapshot.coins.count)")
            } catch {
                app.logger.warning("crypto_markets_refresh failed error=\(error)")
            }
        }
    }
}
