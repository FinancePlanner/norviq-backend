import Fluent
import Foundation
import NIOCore
import StockPlanShared
import Vapor

final class TaxProjectionPoller: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let initialDelaySeconds: Int64
    private let state = TaxProjectionPollerState()

    init(intervalSeconds: Int64 = 86400, initialDelaySeconds: Int64 = 90) {
        self.intervalSeconds = max(3600, intervalSeconds)
        self.initialDelaySeconds = max(0, initialDelaySeconds)
    }

    func didBoot(_ app: Application) throws {
        let scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .seconds(initialDelaySeconds),
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
            try await enqueueDailyJobs(app)
            try await processDueJobs(app)
        } catch {
            app.logger.error("tax.projection poll failed error=\(error)")
        }
    }

    private func enqueueDailyJobs(_ app: Application) async throws {
        let profiles = try await TaxProfile.query(on: app.db).filter(\.$isComplete == true).all()
        let day = Self.dayFormatter.string(from: Date())
        for profile in profiles {
            let key = "daily:\(profile.userId.uuidString):\(profile.jurisdiction):\(profile.taxYear):\(day)"
            let exists = try await TaxProjectionJob.query(on: app.db).filter(\.$idempotencyKey == key).first() != nil
            guard !exists else { continue }
            let job = TaxProjectionJob()
            job.userId = profile.userId
            job.taxYear = profile.taxYear
            job.reason = "daily"
            job.idempotencyKey = key
            job.status = "pending"
            job.attemptCount = 0
            job.nextAttemptAt = Date()
            try await job.create(on: app.db)
        }
    }

    private func processDueJobs(_ app: Application) async throws {
        let jobs = try await TaxProjectionJob.query(on: app.db)
            .filter(\.$status ~~ ["pending", "retry"])
            .filter(\.$nextAttemptAt <= Date())
            .sort(\.$nextAttemptAt, .ascending)
            .limit(50)
            .all()
        for job in jobs {
            job.status = "running"
            job.attemptCount += 1
            try await job.save(on: app.db)
            do {
                guard let profile = try await TaxProfile.query(on: app.db)
                    .filter(\.$userId == job.userId)
                    .filter(\.$taxYear == job.taxYear)
                    .first(),
                    let jurisdiction = TaxJurisdiction(rawValue: profile.jurisdiction)
                else { throw Abort(.notFound, reason: "Tax profile not found for projection job.") }
                let dashboard = try await app.taxService.dashboard(
                    userId: job.userId,
                    jurisdiction: jurisdiction,
                    taxYear: job.taxYear,
                    on: app.db
                )
                let req = Request(application: app, on: app.eventLoopGroup.next())
                try await TaxNotificationEvaluator().evaluate(dashboard: dashboard, userId: job.userId, req: req)
                job.status = "complete"
                job.lastError = nil
            } catch {
                job.lastError = String(describing: error)
                if job.attemptCount >= 5 {
                    job.status = "failed"
                } else {
                    job.status = "retry"
                    let delay = min(3600, 60 * (1 << max(0, job.attemptCount - 1)))
                    job.nextAttemptAt = Date().addingTimeInterval(TimeInterval(delay))
                }
            }
            try await job.save(on: app.db)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private final class TaxProjectionPollerState: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: RepeatedTask?
    private var task: Task<Void, Never>?
    private var running = false

    func begin() -> Bool {
        lock.withLock { guard !running else { return false }; running = true; return true }
    }

    func finish() {
        lock.withLock { running = false; task = nil }
    }

    func set(scheduled: RepeatedTask) {
        lock.withLock { self.scheduled = scheduled }
    }

    func set(task: Task<Void, Never>) {
        lock.withLock { self.task = task }
    }

    func cancel() {
        lock.withLock { scheduled?.cancel(); task?.cancel(); scheduled = nil; task = nil; running = false }
    }
}
