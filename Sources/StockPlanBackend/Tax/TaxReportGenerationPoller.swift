import Fluent
import Foundation
import NIOCore
import Vapor

final class TaxReportGenerationPoller: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let state = TaxReportGenerationPollerState()

    init(intervalSeconds: Int64 = 10) {
        self.intervalSeconds = max(5, intervalSeconds)
    }

    func didBoot(_ app: Application) throws {
        let scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .seconds(1),
            delay: .seconds(intervalSeconds)
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
        do {
            let candidates = try await TaxReport.query(on: app.db)
                .filter(\.$status ~~ ["pending", "retry", "generating"])
                .sort(\.$createdAt, .ascending)
                .limit(25)
                .all()
            let now = Date()
            for report in candidates where report.nextAttemptAt.map({ $0 <= now }) ?? true {
                try Task.checkCancellation()
                try await process(report, app: app)
            }
        } catch is CancellationError {
            return
        } catch {
            app.logger.error("tax_report.poll_failed error=\(error)")
        }
    }

    private func process(_ report: TaxReport, app: Application) async throws {
        guard let reportID = report.id else { return }
        let attempt = (report.attemptCount ?? 0) + 1
        report.status = "generating"
        report.attemptCount = attempt
        report.nextAttemptAt = nil
        try await report.save(on: app.db)
        app.logger.info("tax_report.generation_started report_id=\(reportID) attempt=\(attempt)")

        await app.taxReportGenerator.generate(reportID: reportID, application: app)
        guard let refreshed = try await TaxReport.find(reportID, on: app.db) else { return }
        if refreshed.status == "ready" {
            refreshed.nextAttemptAt = nil
            try await refreshed.save(on: app.db)
            app.logger.info("tax_report.generation_completed report_id=\(reportID) attempt=\(attempt)")
            return
        }

        if attempt >= 5 {
            refreshed.status = "failed"
            refreshed.nextAttemptAt = nil
            try await refreshed.save(on: app.db)
            app.logger.error("tax_report.generation_exhausted report_id=\(reportID) attempts=\(attempt)")
            return
        }

        let delay = min(3600, 30 * (1 << max(0, attempt - 1)))
        refreshed.status = "retry"
        refreshed.nextAttemptAt = Date().addingTimeInterval(TimeInterval(delay))
        try await refreshed.save(on: app.db)
        app.logger.warning(
            "tax_report.generation_retry report_id=\(reportID) attempt=\(attempt) delay_seconds=\(delay)"
        )
    }
}

private final class TaxReportGenerationPollerState: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: RepeatedTask?
    private var task: Task<Void, Never>?
    private var running = false

    func begin() -> Bool {
        lock.withLock {
            guard !running else { return false }
            running = true
            return true
        }
    }

    func finish() {
        lock.withLock {
            running = false
            task = nil
        }
    }

    func set(scheduled: RepeatedTask) {
        lock.withLock { self.scheduled = scheduled }
    }

    func set(task: Task<Void, Never>) {
        lock.withLock { self.task = task }
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
