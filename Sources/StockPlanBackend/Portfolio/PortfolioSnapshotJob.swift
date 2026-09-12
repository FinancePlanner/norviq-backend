import Fluent
import Foundation
import NIOCore
import StockPlanShared
import Vapor

/// Records one `portfolio_value_snapshots` row per portfolio list per trading day.
///
/// The tick is a retry, not a sample. It runs hourly by default while writing at
/// most one row per day: the unique constraint on (user, list, day) makes every
/// run after the first a no-op, so a pod that boots at 14:00 after a deploy
/// still captures today, and a pod that restarts twenty times does not produce
/// twenty points.
///
/// Days on which the market did not trade are skipped rather than carried
/// forward. A flat weekend segment would read as a stall, and a 0.0% Monday
/// delta as "nothing happened" rather than "nothing was open". Skipping means
/// the day-over-day change is honestly "versus the previous trading day".
final class PortfolioSnapshotJob: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let state = PortfolioSnapshotJobState()
    private let valuator = PortfolioSnapshotValuator()

    init(intervalSeconds: Int64 = 3600) {
        self.intervalSeconds = max(300, intervalSeconds)
    }

    func didBoot(_ app: Application) throws {
        let scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .seconds(180), delay: .seconds(intervalSeconds)
        ) { _ in
            guard self.state.begin() else { return }
            let task = Task {
                defer { self.state.finish() }
                await self.runOnce(app)
            }
            self.state.set(task: task)
        }
        state.set(scheduled: scheduled)
    }

    func shutdown(_: Application) {
        state.cancel()
    }

    func runOnce(_ app: Application) async {
        await JobLock.runAsLeader(app, name: "portfolio_snapshot_job") {
            await self.runOnceAsLeader(app)
        }
    }

    func runOnceAsLeader(_ app: Application) async {
        do {
            // Real portfolios only. Model and simulated lists are hypotheticals;
            // recording a value history for them would be recording fiction.
            let lists = try await PortfolioList.query(on: app.db)
                .filter(\.$archivedAt == nil)
                .filter(\.$mode == PortfolioMode.actual.rawValue)
                .all()
            for list in lists where !Task.isCancelled {
                do {
                    _ = try await capture(list: list, on: app.db, logger: app.logger)
                } catch {
                    app.logger.warning(
                        "portfolio_snapshot capture failed",
                        metadata: [
                            "portfolio_list_id": .string(list.id?.uuidString ?? "unknown"),
                            "error": .string(String(reflecting: error)),
                        ]
                    )
                }
            }
        } catch {
            app.logger.error(
                "portfolio_snapshot run failed",
                metadata: ["error": .string(String(reflecting: error))]
            )
        }
    }

    /// Why a tick wrote nothing for a portfolio. Returned rather than logged so
    /// tests can assert on the decision instead of on log output.
    enum CaptureOutcome: Equatable {
        case captured
        /// A row already exists for today — the common case on a repeat tick.
        case alreadyCaptured
        /// No held symbol has a price dated today, so the market did not trade.
        case marketClosed
        /// Some symbols could not be priced. Writing a partial valuation would
        /// render as a plunge; an absent day renders as an absent point.
        case incompletePricing(missing: Int)
        /// Nothing to record.
        case empty
    }

    @discardableResult
    func capture(
        list: PortfolioList,
        now: Date = Date(),
        on db: any Database,
        logger: Logger? = nil
    ) async throws -> CaptureOutcome {
        guard let listId = list.id else { return .empty }
        let day = PortfolioSnapshotValuator.startOfDay(now)

        // Cheap existence check first: a repeat tick does no valuation work.
        let existing = try await PortfolioValueSnapshot.query(on: db)
            .filter(\.$userId == list.userId)
            .filter(\.$portfolioListId == listId)
            .filter(\.$capturedOn == day)
            .first()
        if existing != nil {
            return .alreadyCaptured
        }

        let valuation = try await valuator.value(
            userId: list.userId,
            portfolioListId: listId,
            asOf: now,
            pricing: .live,
            on: db
        )

        guard !valuation.isEmpty else { return .empty }

        // A portfolio of only cash has no symbols to date the market by, so it is
        // captured whenever the job runs; there is no price to be stale.
        if valuation.positionCount > 0 {
            guard try await marketTraded(
                userId: list.userId,
                portfolioListId: listId,
                on: day,
                db: db
            ) else {
                return .marketClosed
            }
        }

        guard valuation.isFullyPriced else {
            logger?.warning(
                "portfolio_snapshot skipped: incomplete pricing",
                metadata: [
                    "portfolio_list_id": .string(listId.uuidString),
                    "priced": .string(String(valuation.pricedSymbols)),
                    "missing": .string(String(valuation.missingSymbols)),
                ]
            )
            return .incompletePricing(missing: valuation.missingSymbols)
        }

        let snapshot = PortfolioValueSnapshot(
            userId: list.userId,
            portfolioListId: listId,
            capturedOn: day,
            // The list's own base currency, not the quote currency: the snapshot
            // records what this portfolio is denominated in.
            currency: list.baseCurrency,
            marketValue: valuation.marketValue,
            costBasis: valuation.costBasis,
            cashBalance: valuation.cashBalance,
            positionCount: valuation.positionCount,
            source: .live,
            pricedSymbols: valuation.pricedSymbols,
            missingSymbols: valuation.missingSymbols
        )

        do {
            try await snapshot.save(on: db)
        } catch {
            // A unique violation means another replica won the race between the
            // existence check and this write. The row exists either way, which is
            // all the job wanted.
            let recheck = try await PortfolioValueSnapshot.query(on: db)
                .filter(\.$userId == list.userId)
                .filter(\.$portfolioListId == listId)
                .filter(\.$capturedOn == day)
                .first()
            guard recheck != nil else { throw error }
            return .alreadyCaptured
        }

        return .captured
    }

    /// Whether the market traded on `day`, inferred from the portfolio's own
    /// holdings rather than a hardcoded holiday calendar: if no held symbol has
    /// a bar or a quote dated `day`, nothing traded. Self-maintaining, and
    /// correct for whichever exchange the holdings actually sit on.
    private func marketTraded(
        userId: UUID,
        portfolioListId: UUID,
        on day: Date,
        db: any Database
    ) async throws -> Bool {
        let symbols = try await PortfolioSnapshotValuator.uniqueSymbols(
            Stock.query(on: db)
                .filter(\.$userId == userId)
                .filter(\.$portfolioListId == portfolioListId)
                .all()
                .map(\.symbol)
        )
        guard !symbols.isEmpty else { return false }

        let next = PortfolioSnapshotValuator.addDays(day, days: 1)

        let barCount = try await MarketPriceBar.query(on: db)
            .filter(\.$instrumentKey ~~ symbols)
            .filter(\.$date >= day)
            .filter(\.$date < next)
            .count()
        if barCount > 0 {
            return true
        }

        let quoteCount = try await QuoteCache.query(on: db)
            .filter(\.$symbol ~~ symbols)
            .filter(\.$asOf >= day)
            .filter(\.$asOf < next)
            .count()
        return quoteCount > 0
    }
}

private final class PortfolioSnapshotJobState: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: RepeatedTask?
    private var task: Task<Void, Never>?
    private var running = false

    func begin() -> Bool {
        lock.withLock {
            if running {
                return false
            }
            running = true
            return true
        }
    }

    func set(scheduled: RepeatedTask) {
        lock.withLock { self.scheduled = scheduled }
    }

    func set(task: Task<Void, Never>) {
        lock.withLock { self.task = task }
    }

    func finish() {
        lock.withLock { task = nil; running = false }
    }

    func cancel() {
        lock.withLock {
            scheduled?.cancel()
            task?.cancel()
            scheduled = nil
            task = nil
            running = false
        }
    }
}
