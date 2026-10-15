import Foundation
import StockPlanShared
import Vapor

/// Generates one brief now, outside the schedule.
///
///     ./StockPlanBackend market-brief-generate --slot morning [--replace]
///
/// Always today's Lisbon date: quotes are fetched live, so a brief for a past
/// date would carry today's numbers. Works with `MARKET_BRIEF_ENABLED` off, which is how staging is checked
/// before the job is switched on.
struct MarketBriefGenerateCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "slot", help: "morning or evening")
        var slot: String?

        @Flag(name: "replace", help: "Delete and regenerate an existing brief for that date and slot.")
        var replace: Bool
    }

    let help = "Generate one market brief now, outside the schedule."

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        guard let raw = signature.slot, let slot = MarketBriefSlot(rawValue: raw) else {
            throw Abort(.badRequest, reason: "--slot must be morning or evening")
        }
        guard let generator = app.marketBriefGenerator else {
            throw Abort(.serviceUnavailable, reason: "market brief generator is not configured")
        }
        let due = MarketBriefSchedule.Due(
            tradingDate: MarketBriefSchedule.localDate(Date()),
            slot: slot
        )
        let req = Request(application: app, on: app.eventLoopGroup.next())
        let outcome = try await MarketBriefRunner(generator: generator, repository: app.marketBriefRepository)
            .run(due, replace: signature.replace, on: req)
        context.console.print("market-brief \(due.tradingDate) \(slot.rawValue): \(outcome)")
    }
}
