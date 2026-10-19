import Foundation
import Vapor

/// Writes today's Daily board post now, outside the schedule.
///
///     ./StockPlanBackend daily-board-post-generate [--replace]
///
/// Always today's Lisbon date, and only on a weekday: quotes are fetched live,
/// so a post for a past date would carry today's numbers. Run before 22:30 it
/// cites intraday moves, and the scheduled job then leaves that date alone.
/// Works with `DAILY_BOARD_POST_ENABLED` off, which is how staging is checked
/// before the job is switched on.
struct DailyBoardPostGenerateCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Flag(name: "replace", help: "Delete today's run row and AI post, then write it again.")
        var replace: Bool
    }

    let help = "Write today's Daily board post now, outside the schedule."

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        guard AIProviderConfiguration.load().isConfigured else {
            throw Abort(.serviceUnavailable, reason: "no AI provider key is configured")
        }
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MarketBriefSchedule.timeZone
        guard (2 ... 6).contains(calendar.component(.weekday, from: now)) else {
            throw Abort(.badRequest, reason: "today is not a trading day in Lisbon")
        }
        let tradingDate = MarketBriefSchedule.localDate(now)
        if signature.replace {
            try await DailyBoardPublisher.reset(tradingDate: tradingDate, on: app.db)
        }
        let req = Request(application: app, on: app.eventLoopGroup.next())
        let outcome = try await DailyBoardPublisher.run(
            tradingDate: tradingDate,
            writer: OpenAIDailyBoardWriter(),
            on: req
        )
        context.console.print("daily-board-post \(tradingDate): \(outcome)")
    }
}
