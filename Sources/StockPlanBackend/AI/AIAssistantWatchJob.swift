import Fluent
import FluentSQL
import Foundation
import NIOCore
import Vapor

/// Runs standing tasks that are due.
///
/// Each due watch gets one unattended, read-only assistant turn with its spec
/// as the prompt (`AIAssistantTurnCoordinator.runProactive`). The answer is
/// appended to the watch's thread as a proactive message captioned
/// "Standing task" and pushed. A conditional watch ("… when Y") stays silent
/// while the model answers `NO_UPDATE`, and switches itself off after it fires
/// once, so a condition that stays true does not ping every hour.
///
/// **Replicas.** Every API replica boots this job. A watch is claimed by one
/// `UPDATE … WHERE id IN (SELECT … FOR UPDATE SKIP LOCKED) RETURNING id` that
/// also advances `next_run_at`, so a row is taken by exactly one replica: a
/// concurrent claimer skips the locked row, and a later one no longer finds it
/// due. The claim commits before the model call, so a crash mid-run skips that
/// run rather than repeating it.
final class AIAssistantWatchJob: LifecycleHandler, @unchecked Sendable {
    /// One unattended turn. Injectable so tests need no model.
    typealias Runner = @Sendable (
        _ userId: UUID,
        _ conversation: AIConversation,
        _ prompt: String,
        _ req: Request
    ) async throws -> String

    private let intervalSeconds: Int64
    private let batchSize: Int
    private let runner: Runner
    private var scheduled: RepeatedTask?

    init(intervalSeconds: Int64 = 300, batchSize: Int = 25, runner: Runner? = nil) {
        self.intervalSeconds = max(30, intervalSeconds)
        self.batchSize = max(1, batchSize)
        self.runner = runner ?? { userId, conversation, prompt, req in
            try await AIAssistantTurnCoordinator.runProactive(
                userId: userId, conversation: conversation, prompt: prompt, req: req
            )
        }
    }

    func didBoot(_ app: Application) throws {
        scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .minutes(2),
            delay: .seconds(intervalSeconds)
        ) { _ in
            Task { await self.runOnce(app) }
        }
    }

    func shutdown(_: Application) {
        scheduled?.cancel()
        scheduled = nil
    }

    struct RunSummary: Equatable, Sendable {
        var claimed = 0
        var posted = 0
        var silent = 0
        var failed = 0
    }

    @discardableResult
    func runOnce(_ app: Application) async -> RunSummary {
        var summary = RunSummary()
        let ids: [UUID]
        do {
            ids = try await Self.claimDue(limit: batchSize, on: app.db)
        } catch {
            app.logger.warning("ai_assistant.watch_claim_failed error=\(String(reflecting: error).prefix(500))")
            return summary
        }
        summary.claimed = ids.count
        for id in ids {
            do {
                if try await run(watchId: id, app: app) {
                    summary.posted += 1
                } else {
                    summary.silent += 1
                }
            } catch {
                summary.failed += 1
                app.logger.warning("ai_assistant.watch_run_failed watch_id=\(id) error=\(String(reflecting: error).prefix(300))")
            }
        }
        return summary
    }

    /// Atomically takes up to `limit` due watches and moves each one's
    /// `next_run_at` to its first anchor after now.
    static func claimDue(limit: Int, on database: any Database) async throws -> [UUID] {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Standing tasks require a SQL database.")
        }
        let rows = try await sql.raw("""
        UPDATE assistant_watches AS w
        SET next_run_at = w.next_run_at + make_interval(
                -- interval_minutes is BIGINT (Fluent `.int`); make_interval takes int.
                mins => (w.interval_minutes * (floor(extract(epoch FROM (now() - w.next_run_at)) / 60 / w.interval_minutes) + 1))::int
            ),
            last_run_at = now(),
            updated_at = now()
        WHERE w.id IN (
            SELECT id FROM assistant_watches
            WHERE enabled AND next_run_at <= now()
            ORDER BY next_run_at
            LIMIT \(bind: limit)
            FOR UPDATE SKIP LOCKED
        )
        RETURNING w.id
        """).all()
        return try rows.map { try $0.decode(column: "id", as: UUID.self) }
    }

    /// Runs one claimed watch. Returns whether a message was posted.
    private func run(watchId: UUID, app: Application) async throws -> Bool {
        guard let watch = try await AIAssistantWatch.find(watchId, on: app.db), watch.enabled else { return false }
        guard let conversation = try await AIConversation.query(on: app.db)
            .filter(\.$id == watch.conversationId).filter(\.$userId == watch.userId).first()
        else {
            watch.enabled = false
            try await watch.save(on: app.db)
            return false
        }

        let crypto = app.userPIIEncryptionService
        let title = try crypto.decryptString(watch.titleEncrypted)
        let spec = try crypto.decryptString(watch.specEncrypted)
        let condition = try watch.conditionEncrypted.map { try crypto.decryptString($0) }
        let prompt = AIAssistantProactive.runPrompt(spec: spec, condition: condition, scheduleHuman: watch.scheduleHuman)

        let req = Request(application: app, on: app.eventLoopGroup.next())
        let answer = try await runner(watch.userId, conversation, prompt, req)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if condition != nil, answer.isEmpty || answer.uppercased().hasPrefix(AIAssistantProactive.noUpdateToken) {
            // Nothing to say. Keep the thread from retiring under a live task.
            conversation.expiresAt = Date().addingTimeInterval(30 * 86400)
            try await conversation.save(on: app.db)
            return false
        }

        let message = try await AIAssistantProactive.append(
            text: answer,
            sourceLabel: AIAssistantProactive.standingTaskLabel,
            userId: watch.userId,
            conversation: conversation,
            app: app
        )
        if condition != nil {
            watch.enabled = false
            try await watch.save(on: app.db)
        }
        // Pushed regardless of the assistant push preference: confirming a
        // standing task is itself the request to be pinged.
        await AIAssistantProactive.push(message: message, title: title, body: answer, userId: watch.userId, req: req)
        return true
    }
}
