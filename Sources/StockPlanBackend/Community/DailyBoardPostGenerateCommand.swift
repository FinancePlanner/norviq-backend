import Foundation
import Vapor

/// Writes a Daily board post now, outside the schedule.
///
///     ./StockPlanBackend daily-board-post-generate [--date 2026-10-19] [--topic etf] [--dry-run] [--replace]
///
/// The date defaults to today in Lisbon and picks the rotation slot. Facts
/// are always fetched live, so a past date gets today's numbers: use it with
/// `--dry-run` to read a slot's draft, not to backfill. Works with
/// `DAILY_BOARD_POST_ENABLED` off, which is how staging is checked before the
/// job is switched on.
struct DailyBoardPostGenerateCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "date", help: "Post date, yyyy-MM-dd. Defaults to today in Lisbon.")
        var date: String?

        @Option(name: "topic", help: "Write this topic instead of the day's rotation slot: mag7, stock, macro, etf, week_recap, week_ahead.")
        var topic: String?

        @Flag(name: "dry-run", help: "Print the facts, the draft and the validator's verdict. Writes nothing.")
        var dryRun: Bool

        @Flag(name: "replace", help: "Delete the date's run row and AI post, then write it again.")
        var replace: Bool
    }

    let help = "Write a Daily board post now, outside the schedule."

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        guard AIProviderConfiguration.load().isConfigured else {
            throw Abort(.serviceUnavailable, reason: "no AI provider key is configured")
        }
        let day = signature.date ?? MarketBriefSchedule.localDate(Date())
        guard DailyBoardDays.date(day) != nil else {
            throw Abort(.badRequest, reason: "--date must be yyyy-MM-dd")
        }
        let topic = try signature.topic.map { raw in
            guard let topic = DailyBoardTopic(rawValue: raw), topic != .index, topic != .news else {
                throw Abort(.badRequest, reason: "unknown --topic \(raw)")
            }
            return topic
        }
        let req = Request(application: app, on: app.eventLoopGroup.next())
        let writer = OpenAIDailyBoardWriter()

        if signature.dryRun {
            let sources = LiveDailyBoardSources()
            guard let candidate = try await DailyBoardPublisher.compose(day: day, topic: topic, sources: sources, on: req) else {
                context.console.print("daily-board-post \(day): no topic had enough data")
                return
            }
            context.console.print(DailyBoardStyle.prompt(for: candidate, day: day))
            context.console.print("")
            do {
                let accepted = try await DailyBoardPublisher.write(candidate, day: day, writer: EchoWriter(inner: writer), on: req)
                context.console.print("ACCEPTED\n\n\(accepted.title)\n\n\(accepted.body)")
            } catch {
                context.console.print("REJECTED: \(error)")
            }
            return
        }

        if signature.replace {
            try await DailyBoardPublisher.reset(tradingDate: day, on: app.db)
        }
        let outcome = try await DailyBoardPublisher.run(tradingDate: day, writer: writer, topic: topic, on: req)
        context.console.print("daily-board-post \(day): \(outcome)")
    }
}

/// Prints every draft, so a dry run shows what the validator turned down.
private struct EchoWriter: DailyBoardWriting {
    let inner: any DailyBoardWriting

    func draft(prompt: String, on req: Request) async throws -> (title: String, body: String) {
        let draft = try await inner.draft(prompt: prompt, on: req)
        print("DRAFT\n\n\(draft.title)\n\n\(draft.body)\n")
        return draft
    }
}
