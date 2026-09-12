import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Reconstructs portfolio value history from stored price bars.
///
///     swift run App portfolio-backfill [--user <uuid>] [--days 365] [--dry-run]
///
/// Operator-triggered rather than automatic, and safely re-runnable. It never
/// overwrites a day that already has a row, so observed truth always wins over
/// reconstruction and running it twice changes nothing the second time.
///
/// Reconstruction is approximate, which is why its rows are marked `backfill`:
/// `Stock` rows are mutable and carry no sell or trim log, so a position is
/// assumed to have been held, at today's share count, since its buy date; and
/// cash has no history at all, so today's balance is held flat across the
/// window. Days where any held symbol cannot be priced are skipped entirely,
/// under the same rule the live job uses.
struct PortfolioBackfillCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "user", help: "Only backfill this user's portfolios.")
        var user: String?

        @Option(name: "days", help: "How many days back to reconstruct (default 365).")
        var days: Int?

        @Flag(name: "dry-run", help: "Report what would be written without writing it.")
        var dryRun: Bool
    }

    let help = "Reconstruct portfolio value history from stored price bars."

    struct Report {
        var written = 0
        var skippedExisting = 0
        var skippedIncomplete = 0
        var skippedEmpty = 0
        var portfolios = 0

        var summary: String {
            """
            portfolios=\(portfolios) written=\(written) \
            skipped_existing=\(skippedExisting) \
            skipped_incomplete=\(skippedIncomplete) \
            skipped_empty=\(skippedEmpty)
            """
        }
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let days = max(1, signature.days ?? 365)
        let userId = try signature.user.map { raw -> UUID in
            guard let id = UUID(uuidString: raw) else {
                throw Abort(.badRequest, reason: "Invalid user id: \(raw)")
            }
            return id
        }

        let report = try await backfill(
            userId: userId,
            days: days,
            dryRun: signature.dryRun,
            on: app.db,
            logger: app.logger
        )

        let prefix = signature.dryRun ? "portfolio-backfill (dry run):" : "portfolio-backfill:"
        context.console.print("\(prefix) \(report.summary)")
    }

    /// Separated from `run` so it is callable from tests without a console.
    @discardableResult
    func backfill(
        userId: UUID?,
        days: Int,
        dryRun: Bool,
        now: Date = Date(),
        on db: any Database,
        logger: Logger? = nil
    ) async throws -> Report {
        let valuator = PortfolioSnapshotValuator()
        let end = PortfolioSnapshotValuator.startOfDay(now)
        let start = PortfolioSnapshotValuator.addDays(end, days: -days)

        let query = PortfolioList.query(on: db)
            .filter(\.$archivedAt == nil)
            .filter(\.$mode == PortfolioMode.actual.rawValue)
        if let userId {
            query.filter(\.$userId == userId)
        }
        let lists = try await query.all()

        var report = Report()
        report.portfolios = lists.count

        for list in lists {
            guard let listId = list.id else { continue }

            let series = try await valuator.historicalSeries(
                userId: list.userId,
                portfolioListId: listId,
                from: start,
                to: end,
                on: db
            )
            guard !series.isEmpty else { continue }

            // One query for the whole window rather than an existence check per
            // day.
            let existingDays = try await Set(
                PortfolioValueSnapshot.query(on: db)
                    .filter(\.$userId == list.userId)
                    .filter(\.$portfolioListId == listId)
                    .filter(\.$capturedOn >= start)
                    .filter(\.$capturedOn <= end)
                    .all()
                    .map { PortfolioSnapshotValuator.startOfDay($0.capturedOn) }
            )

            for (day, valuation) in series {
                if existingDays.contains(day) {
                    // Never overwrite. A live row is what actually happened; an
                    // earlier backfill row is no worse than this one would be.
                    report.skippedExisting += 1
                    continue
                }
                if valuation.isEmpty {
                    report.skippedEmpty += 1
                    continue
                }
                guard valuation.isFullyPriced else {
                    report.skippedIncomplete += 1
                    continue
                }

                report.written += 1
                guard !dryRun else { continue }

                let snapshot = PortfolioValueSnapshot(
                    userId: list.userId,
                    portfolioListId: listId,
                    capturedOn: day,
                    currency: list.baseCurrency,
                    marketValue: valuation.marketValue,
                    costBasis: valuation.costBasis,
                    cashBalance: valuation.cashBalance,
                    positionCount: valuation.positionCount,
                    source: .backfill,
                    pricedSymbols: valuation.pricedSymbols,
                    missingSymbols: valuation.missingSymbols
                )
                do {
                    try await snapshot.save(on: db)
                } catch {
                    // Lost a race with the live job for today. Its row is the
                    // better one; leave it.
                    report.written -= 1
                    report.skippedExisting += 1
                    logger?.debug(
                        "portfolio_backfill row already present",
                        metadata: ["portfolio_list_id": .string(listId.uuidString)]
                    )
                }
            }
        }

        return report
    }
}
