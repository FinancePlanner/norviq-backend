import Foundation
import NIOCore
import StockPlanShared
import Vapor

/// Fills the 08:15 and 22:30 Lisbon slots.
///
/// Same lifecycle shape as `SentimentAggregationJob`: a repeated task, an
/// overlap guard and a shutdown drain, because this codebase has no queue or
/// cron. A five-minute tick asks `MarketBriefSchedule` whether a window is
/// open; the database (unique per slot and language) is the record of what
/// is done, so restarts and extra replicas cost a cheap `exists` query, not a
/// second brief. Failures retry on later ticks, up to
/// `maxAttemptsPerSlot` per slot per process, so a broken provider costs
/// three paid calls rather than one every five minutes until noon.
final class MarketBriefJob: LifecycleHandler, @unchecked Sendable {
    static let maxAttemptsPerSlot = 3

    private let tickIntervalSeconds: Int64
    private let initialDelaySeconds: Int64
    private let state = BackgroundJobState()
    private let attempts = MarketBriefAttempts()

    init(tickIntervalSeconds: Int64 = 300, initialDelaySeconds: Int64 = 60) {
        self.tickIntervalSeconds = max(tickIntervalSeconds, 60)
        self.initialDelaySeconds = max(initialDelaySeconds, 0)
    }

    func didBoot(_ app: Application) throws {
        guard app.environment != .testing else { return }
        let eventLoop = app.eventLoopGroup.next()
        let scheduled = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(initialDelaySeconds),
            delay: .seconds(tickIntervalSeconds)
        ) { _ in
            guard self.state.begin() else { return }
            let task = Task {
                defer { self.state.finish() }
                await self.tick(app, now: Date())
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

    func tick(_ app: Application, now: Date) async {
        guard let due = MarketBriefSchedule.dueSlot(now: now) else { return }
        guard attempts.failures(for: due) < Self.maxAttemptsPerSlot else { return }
        guard let generator = app.marketBriefGenerator else {
            app.logger.warning("market_brief skipped: no generator configured")
            return
        }
        let runner = MarketBriefRunner(generator: generator, repository: app.marketBriefRepository)
        await JobLock.runAsLeader(app, name: "market_brief_job") {
            let req = Request(application: app, on: app.eventLoopGroup.next())
            do {
                let outcome = try await runner.run(due, replace: false, on: req)
                if case let .generated(degraded) = outcome {
                    app.logger.info("market_brief ok date=\(due.tradingDate) slot=\(due.slot.rawValue) degraded=\(degraded)")
                }
            } catch {
                let failures = self.attempts.recordFailure(for: due)
                app.logger.error(
                    "market_brief failed date=\(due.tradingDate) slot=\(due.slot.rawValue) attempt=\(failures)/\(Self.maxAttemptsPerSlot) error=\(String(describing: error))"
                )
            }
        }
    }
}

/// Per-process failure counts per slot. In-memory on purpose: a restart
/// earning three fresh attempts is fine.
private final class MarketBriefAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [MarketBriefSchedule.Due: Int] = [:]

    func failures(for due: MarketBriefSchedule.Due) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[due] ?? 0
    }

    @discardableResult
    func recordFailure(for due: MarketBriefSchedule.Due) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let next = (counts[due] ?? 0) + 1
        counts[due] = next
        return next
    }
}
