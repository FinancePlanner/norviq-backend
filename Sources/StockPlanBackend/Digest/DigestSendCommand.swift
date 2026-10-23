import Fluent
import Foundation
import Vapor

/// Composes one user's digest for the week ending today, outside the schedule.
///
///     ./StockPlanBackend digest-send --user <uuid> [--dry-run]
///
/// `--dry-run` prints the email and writes nothing. Without it, the digest is
/// claimed and sent like a scheduled one, so it cannot be sent twice for the
/// same week. Refuses users the scheduled job would skip (nothing held, no
/// bank connection). Works with `DIGEST_ENABLED` off, which is how staging is checked
/// before the job is switched on; `DIGEST_EMAIL_ENABLED` still gates sending.
struct DigestSendCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "user", help: "User id")
        var user: String?

        @Flag(name: "dry-run", help: "Print the email; write and send nothing.")
        var dryRun: Bool
    }

    let help = "Compose (and optionally send) one weekly digest now."

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        guard let raw = signature.user, let userId = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "--user must be a user id")
        }
        let req = Request(application: app, on: app.eventLoopGroup.next())
        let preference = try await Self.sendablePreference(userId: userId, on: req.db)
        let timeZone = TimeZone(identifier: preference.timezone) ?? TimeZone(identifier: "UTC")!
        let period = DigestSchedule.period(endingOn: Date(), timeZone: timeZone)

        if signature.dryRun {
            let payload = try await DigestFactsCollector(sources: app.digestDataSources)
                .collect(userId: userId, period: period, preference: preference, previous: nil, on: req)
            let rendered = DigestEmailRenderer(webBaseURL: app.digestConfig.webBaseURL, apiBaseURL: app.digestConfig.apiBaseURL)
                .render(digestId: UUID(), payload: payload, unsubscribeToken: "dry-run")
            context.console.print("Subject: \(rendered.subject)\n\n\(rendered.text)")
            return
        }

        let outcome = try await DigestRunner(config: app.digestConfig, sources: app.digestDataSources)
            .run(preference: preference, period: period, on: req)
        context.console.print("digest-send \(userId) \(period.start)…\(period.end): \(outcome)")
    }

    /// The user's preferences, provided the scheduled job would send to them too.
    /// Without the eligibility check a manual send to an account with nothing
    /// connected emails an empty digest and spends that week's claim.
    static func sendablePreference(userId: UUID, on db: any Database) async throws -> DigestPreference {
        guard let preference = try await DigestPreference.query(on: db).filter(\.$userId == userId).first() else {
            throw Abort(.notFound, reason: "User has no digest preferences; PUT /v1/digest-preferences first.")
        }
        guard try await DigestFactsCollector.isEligible(userId: userId, on: db) else {
            throw Abort(.conflict, reason: "User holds no positions and has no active bank connection; the digest would be empty.")
        }
        return preference
    }
}
