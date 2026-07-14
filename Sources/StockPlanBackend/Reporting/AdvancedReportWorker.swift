import Crypto
import Fluent
import FluentSQL
import Foundation
import NIOCore
import StockPlanShared
import Vapor

final class AdvancedReportWorker: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let generator: AdvancedReportGenerator
    private let lock = NSLock()
    private var scheduled: RepeatedTask?
    private var running = false

    init(gotenbergBaseURL: String, intervalSeconds: Int64 = 10) {
        generator = AdvancedReportGenerator(gotenbergBaseURL: gotenbergBaseURL)
        self.intervalSeconds = max(2, intervalSeconds)
    }

    func didBoot(_ app: Application) throws {
        scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .seconds(2),
            delay: .seconds(intervalSeconds)
        ) { _ in
            guard self.begin() else { return }
            Task {
                defer { self.finish() }
                await self.runOnce(app)
            }
        }
    }

    func shutdown(_: Application) {
        lock.lock()
        scheduled?.cancel()
        scheduled = nil
        lock.unlock()
    }

    func runOnce(_ app: Application) async {
        do {
            try await enqueueDueSchedules(app)
            try await retryDeliveries(app)
            while let runId = try await claimRun(app) {
                await execute(runId: runId, app: app)
            }
        } catch {
            app.logger.error("advanced_report.worker_failed error=\(error)")
        }
    }

    private func enqueueDueSchedules(_ app: Application) async throws {
        for _ in 0 ..< 20 {
            guard let scheduleId = try await claimDueSchedule(app),
                  let schedule = try await AdvancedReportScheduleRecord.find(scheduleId, on: app.db)
            else { break }
            let entitlement = try await app.entitlementResolver.resolve(userId: schedule.ownerUserId, on: app.db)
            guard entitlement.isPro else {
                schedule.nextRunAt = nil
                schedule.pausedReason = "subscription_required"
                try await schedule.save(on: app.db)
                continue
            }
            let input = try decodeReportJSON(ReportScheduleInput.self, schedule.inputJSON)
            guard input.isEnabled,
                  let templateId = UUID(uuidString: input.templateId),
                  let template = try await AdvancedReportTemplateRecord.find(templateId, on: app.db),
                  template.archivedAt == nil
            else {
                schedule.nextRunAt = nil
                schedule.pausedReason = "template_unavailable"
                try await schedule.save(on: app.db)
                continue
            }
            let scheduledFor = schedule.nextRunAt
            let generatedToday = try await requestedArtifactCountToday(
                userId: schedule.ownerUserId,
                on: app.db
            )
            if generatedToday + input.outputFormats.count > 100 {
                schedule.lastRunAt = scheduledFor
                schedule.nextRunAt = try ReportRecurrenceCalculator().next(
                    after: scheduledFor ?? Date(),
                    recurrence: input.recurrence
                )
                schedule.pausedReason = nil
                try await schedule.save(on: app.db)
                app.logger.warning(
                    "advanced_report.schedule_skipped reason=daily_limit schedule_id=\(schedule.id?.uuidString ?? "unknown")"
                )
                continue
            }
            let run = try AdvancedReportRunRecord(
                templateId: templateId,
                scheduleId: schedule.requireID(),
                requestedByUserId: schedule.ownerUserId,
                templateRevision: template.revision,
                templateInputJSON: template.inputJSON,
                outputFormatsJSON: encodeReportJSON(input.outputFormats),
                recipientUserIdsJSON: encodeReportJSON(
                    input.recipientUserIds.isEmpty ? [schedule.ownerUserId.uuidString] : input.recipientUserIds
                ),
                scheduledFor: scheduledFor
            )
            try await run.save(on: app.db)
            schedule.lastRunAt = scheduledFor
            schedule.nextRunAt = try ReportRecurrenceCalculator().next(
                after: scheduledFor ?? Date(),
                recurrence: input.recurrence
            )
            schedule.pausedReason = nil
            try await schedule.save(on: app.db)
        }
    }

    private func claimDueSchedule(_ app: Application) async throws -> UUID? {
        guard let sql = app.db as? any SQLDatabase else { return nil }
        let rows = try await sql.raw("""
        WITH candidate AS (
            SELECT id FROM advanced_report_schedules
            WHERE next_run_at <= NOW()
              AND (
                paused_reason IS NULL
                OR (paused_reason = 'processing' AND updated_at < NOW() - INTERVAL '10 minutes')
              )
            ORDER BY next_run_at ASC
            FOR UPDATE SKIP LOCKED
            LIMIT 1
        )
        UPDATE advanced_report_schedules AS schedule
        SET paused_reason = 'processing', updated_at = NOW()
        FROM candidate WHERE schedule.id = candidate.id
        RETURNING schedule.id
        """).all()
        return try rows.first?.decode(column: "id", as: UUID.self)
    }

    private func requestedArtifactCountToday(
        userId: UUID,
        on database: any Database
    ) async throws -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let runs = try await AdvancedReportRunRecord.query(on: database)
            .filter(\.$requestedByUserId == userId)
            .filter(\.$createdAt >= calendar.startOfDay(for: Date()))
            .all()
        return try runs.reduce(0) { total, run in
            try total + (decodeReportJSON([ReportOutputFormat].self, run.outputFormatsJSON).count)
        }
    }

    private func claimRun(_ app: Application) async throws -> UUID? {
        guard let sql = app.db as? any SQLDatabase else { return nil }
        let rows = try await sql.raw("""
        WITH candidate AS (
            SELECT id FROM advanced_report_runs
            WHERE status = 'pending'
               OR (status = 'retry' AND retry_at <= NOW())
               OR (status = 'claimed' AND claimed_at < NOW() - INTERVAL '10 minutes')
            ORDER BY created_at ASC
            FOR UPDATE SKIP LOCKED
            LIMIT 1
        )
        UPDATE advanced_report_runs AS report_run
        SET status = 'claimed', claimed_at = NOW(), started_at = COALESCE(started_at, NOW())
        FROM candidate WHERE report_run.id = candidate.id
        RETURNING report_run.id
        """).all()
        return try rows.first?.decode(column: "id", as: UUID.self)
    }

    private func execute(runId: UUID, app: Application) async {
        do {
            guard let run = try await AdvancedReportRunRecord.find(runId, on: app.db) else { return }
            run.status = ReportRunStatus.generating.rawValue
            run.attemptCount += 1
            try await run.save(on: app.db)

            let template = try decodeReportJSON(ReportTemplateInput.self, run.templateInputJSON)
            let document = try await ReportDocumentCollector().collect(template: template, on: app.db)
            let formats = try decodeReportJSON([ReportOutputFormat].self, run.outputFormatsJSON)
            let existing = try await AdvancedReportArtifactRecord.query(on: app.db)
                .filter(\.$runId == runId)
                .all()
            for format in formats where existing.contains(where: { $0.format == format.rawValue }) == false {
                let data = try await generator.generate(document: document, format: format, client: app.client)
                guard !data.isEmpty else { throw Abort(.serviceUnavailable, reason: "The report renderer returned an empty file.") }
                let artifactId = UUID()
                let storageKey = try app.advancedReportStorage.store(
                    data,
                    artifactId: artifactId,
                    format: format.rawValue
                )
                let filename = reportFilename(title: document.title, format: format)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let artifact = AdvancedReportArtifactRecord(
                    id: artifactId,
                    runId: runId,
                    format: format.rawValue,
                    filename: filename,
                    contentType: format == .pdf
                        ? "application/pdf"
                        : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    sizeBytes: Int64(data.count),
                    sha256: hash,
                    storageKey: storageKey,
                    expiresAt: Date().addingTimeInterval(90 * 86400)
                )
                try await artifact.save(on: app.db)
            }
            run.status = ReportRunStatus.delivering.rawValue
            try await run.save(on: app.db)
            try await createAndSendDeliveries(run: run, templateName: template.name, app: app)
        } catch {
            await failOrRetry(runId: runId, error: error, app: app)
        }
    }

    private func createAndSendDeliveries(
        run: AdvancedReportRunRecord,
        templateName: String,
        app: Application
    ) async throws {
        let runId = try run.requireID()
        let recipientValues = try decodeReportJSON([String].self, run.recipientUserIdsJSON)
        let recipientIds = recipientValues.compactMap(UUID.init(uuidString:))
        let users = try await User.query(on: app.db).filter(\.$id ~~ recipientIds).all()
        let existing = try await AdvancedReportDeliveryRecord.query(on: app.db)
            .filter(\.$runId == runId)
            .all()
        for user in users where user.isVerified {
            guard let userId = user.id else { continue }
            let delivery = existing.first(where: { $0.recipientUserId == userId })
                ?? AdvancedReportDeliveryRecord(runId: runId, recipientUserId: userId, recipientEmail: user.email)
            if delivery.id == nil {
                try await delivery.save(on: app.db)
            }
            await send(delivery: delivery, templateName: templateName, app: app)
        }
        try await updateRunDeliveryStatus(runId: runId, app: app)
    }

    private func retryDeliveries(_ app: Application) async throws {
        let deliveries = try await AdvancedReportDeliveryRecord.query(on: app.db)
            .group(.or) { group in
                group.filter(\.$status == ReportDeliveryStatus.pending.rawValue)
                group.filter(\.$status == ReportDeliveryStatus.retry.rawValue)
            }
            .filter(\.$attemptCount < 3)
            .limit(20)
            .all()
        for delivery in deliveries {
            guard let run = try await AdvancedReportRunRecord.find(delivery.runId, on: app.db) else { continue }
            let template = try decodeReportJSON(ReportTemplateInput.self, run.templateInputJSON)
            await send(delivery: delivery, templateName: template.name, app: app)
            try await updateRunDeliveryStatus(runId: delivery.runId, app: app)
        }
    }

    private func send(delivery: AdvancedReportDeliveryRecord, templateName: String, app: Application) async {
        do {
            delivery.status = ReportDeliveryStatus.sending.rawValue
            delivery.attemptCount += 1
            delivery.lastAttemptAt = Date()
            try await delivery.save(on: app.db)
            let artifacts = try await AdvancedReportArtifactRecord.query(on: app.db)
                .filter(\.$runId == delivery.runId)
                .sort(\.$createdAt, .ascending)
                .all()
            let linkExpiry = min(
                artifacts.map(\.expiresAt).min() ?? Date().addingTimeInterval(7 * 86400),
                Date().addingTimeInterval(7 * 86400)
            )
            let baseURL = (Environment.get("PUBLIC_API_BASE_URL") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let links = try artifacts.map { artifact -> String in
                let artifactId = try artifact.requireID()
                let signature = app.reportDownloadSigner.signature(
                    artifactId: artifactId,
                    expiresAt: linkExpiry,
                    recipientUserId: delivery.recipientUserId
                )
                return "\(artifact.filename): \(baseURL)/v1/reporting/artifacts/\(artifactId.uuidString)/download?expires=\(Int64(linkExpiry.timeIntervalSince1970))&recipient=\(delivery.recipientUserId.uuidString)&signature=\(signature)"
            }
            let request = Request(application: app, on: app.eventLoopGroup.next())
            try await app.mailer.send(
                MailMessage(
                    to: delivery.recipientEmail,
                    subject: "Your Norviq report is ready: \(templateName)",
                    body: "Your requested report is ready. These private links expire on \(formatISODateTime(linkExpiry) ?? "schedule").\n\n\(links.joined(separator: "\n"))",
                    purpose: "advanced_report"
                ),
                on: request
            )
            delivery.status = ReportDeliveryStatus.delivered.rawValue
            delivery.deliveredAt = Date()
            delivery.linkExpiresAt = linkExpiry
            delivery.failureReason = nil
            try await delivery.save(on: app.db)
        } catch {
            delivery.status = delivery.attemptCount < 3
                ? ReportDeliveryStatus.retry.rawValue
                : ReportDeliveryStatus.failed.rawValue
            delivery.failureReason = String(describing: error).prefix(500).description
            try? await delivery.save(on: app.db)
            app.logger.error("advanced_report.delivery_failed id=\(delivery.id?.uuidString ?? "unknown") error=\(error)")
        }
    }

    private func updateRunDeliveryStatus(runId: UUID, app: Application) async throws {
        guard let run = try await AdvancedReportRunRecord.find(runId, on: app.db) else { return }
        let deliveries = try await AdvancedReportDeliveryRecord.query(on: app.db)
            .filter(\.$runId == runId)
            .all()
        let delivered = deliveries.count(where: { $0.status == ReportDeliveryStatus.delivered.rawValue })
        if deliveries.isEmpty {
            run.status = ReportRunStatus.ready.rawValue
        } else if delivered == deliveries.count {
            run.status = ReportRunStatus.delivered.rawValue
        } else if deliveries.allSatisfy({ $0.attemptCount >= 3 }) {
            run.status = delivered > 0 ? ReportRunStatus.partiallyDelivered.rawValue : ReportRunStatus.failed.rawValue
        } else {
            run.status = ReportRunStatus.delivering.rawValue
        }
        if run.status != ReportRunStatus.delivering.rawValue {
            run.completedAt = Date()
        }
        try await run.save(on: app.db)
    }

    private func failOrRetry(runId: UUID, error: any Error, app: Application) async {
        guard let run = try? await AdvancedReportRunRecord.find(runId, on: app.db) else { return }
        run.failureReason = String(describing: error).prefix(500).description
        run.claimedAt = nil
        if run.attemptCount < 3 {
            run.status = ReportRunStatus.retry.rawValue
            run.retryAt = Date().addingTimeInterval(pow(2, Double(run.attemptCount)) * 30)
        } else {
            run.status = ReportRunStatus.failed.rawValue
            run.completedAt = Date()
        }
        try? await run.save(on: app.db)
        app.logger.error("advanced_report.generation_failed id=\(runId) error=\(error)")
    }

    private func reportFilename(title: String, format: ReportOutputFormat) -> String {
        let slug = title.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(slug.isEmpty ? "norviq-report" : String(slug.prefix(60)))-\(Int(Date().timeIntervalSince1970)).\(format.rawValue)"
    }

    private func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return false }
        running = true
        return true
    }

    private func finish() {
        lock.lock()
        running = false
        lock.unlock()
    }
}

final class AdvancedReportRetentionJob: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private var task: RepeatedTask?

    init(intervalSeconds: Int64 = 3600) {
        self.intervalSeconds = max(60, intervalSeconds)
    }

    func didBoot(_ app: Application) throws {
        task = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .seconds(60),
            delay: .seconds(intervalSeconds)
        ) { _ in
            Task { await self.runOnce(app) }
        }
    }

    func shutdown(_: Application) {
        task?.cancel()
    }

    func runOnce(_ app: Application) async {
        do {
            let expired = try await AdvancedReportArtifactRecord.query(on: app.db)
                .filter(\.$expiresAt < Date())
                .all()
            for artifact in expired {
                do { try app.advancedReportStorage.delete(key: artifact.storageKey) } catch {
                    app.logger.warning("advanced_report.cleanup_file_failed id=\(artifact.id?.uuidString ?? "unknown") error=\(error)")
                }
            }
            let metadataCutoff = Date().addingTimeInterval(-365 * 86400)
            let oldRuns = try await AdvancedReportRunRecord.query(on: app.db)
                .filter(\.$createdAt < metadataCutoff)
                .all()
            for run in oldRuns {
                try await run.delete(on: app.db)
            }
        } catch {
            app.logger.error("advanced_report.cleanup_failed error=\(error)")
        }
    }
}
