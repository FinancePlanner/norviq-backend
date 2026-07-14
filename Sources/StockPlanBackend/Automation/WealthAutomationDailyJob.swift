import Fluent
import FluentSQL
import Foundation
import NIOCore
import StockPlanShared
import Vapor

final class WealthAutomationDailyJob: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let rebalanceCooldownSeconds: TimeInterval
    private let state = WealthAutomationDailyJobState()

    init(intervalSeconds: Int64 = 86400, rebalanceCooldownSeconds: Int64 = 604_800) {
        self.intervalSeconds = max(300, intervalSeconds)
        self.rebalanceCooldownSeconds = TimeInterval(max(86400, rebalanceCooldownSeconds))
    }

    func didBoot(_ app: Application) throws {
        let scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .seconds(90),
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
        let request = Request(application: app, on: app.eventLoopGroup.next())
        do {
            guard try await acquireLease(on: request.db) else {
                app.logger.debug("wealth-automation daily job lease is held by another replica")
                return
            }
            try await evaluateScreens(request)
            try await evaluateRebalancing(request)
        } catch {
            app.logger.error("wealth-automation daily job failed error_type=\(String(reflecting: type(of: error)))")
        }
    }

    private func acquireLease(on db: any Database) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else { return false }
        let owner = UUID().uuidString
        let rows = try await sql.raw("""
        INSERT INTO automation_job_leases (name, owner, locked_until, updated_at)
        VALUES ('wealth-automation-daily', \(bind: owner), NOW() + INTERVAL '30 minutes', NOW())
        ON CONFLICT (name) DO UPDATE
        SET owner = EXCLUDED.owner, locked_until = EXCLUDED.locked_until, updated_at = NOW()
        WHERE automation_job_leases.locked_until < NOW()
        RETURNING owner
        """).all(decoding: LeaseAcquisition.self)
        return rows.first?.owner == owner
    }

    private func evaluateScreens(_ req: Request) async throws {
        let screens = try await WatchlistScreenModel.query(on: req.db)
            .filter(\.$alertsEnabled == true).all()
        let controller = WealthAutomationController()
        for screen in screens {
            if Task.isCancelled {
                return
            }
            do {
                try await req.usageCounterService.requirePremium(.smartScreening, userId: screen.userId, on: req.db)
                _ = try await controller.evaluate(screen: screen, userId: screen.userId, sendsAlerts: true, req: req)
            } catch {
                req.logger.warning("smart-screen daily evaluation failed screen=\(screen.id?.uuidString ?? "unknown")")
            }
        }
    }

    private func evaluateRebalancing(_ req: Request) async throws {
        let policies = try await RebalancingPolicyModel.query(on: req.db).filter(\.$enabled == true).all()
        let controller = WealthAutomationController()
        for policy in policies {
            if Task.isCancelled {
                return
            }
            do {
                try await req.usageCounterService.requirePremium(.rebalancingRules, userId: policy.userId, on: req.db)
                let now = Date()
                if let lastTriggeredAt = policy.lastTriggeredAt,
                   now.timeIntervalSince(lastTriggeredAt) < rebalanceCooldownSeconds
                {
                    continue
                }
                guard try await RebalanceEventModel.query(on: req.db)
                    .filter(\.$policy.$id == policy.requireID())
                    .filter(\.$status == RebalanceEventStatus.pending.rawValue).first() == nil else { continue }
                let preview = try await controller.makeRebalancePreview(model: policy, userId: policy.userId, req: req)
                guard !preview.triggerReasons.isEmpty else { continue }
                guard preview.warnings.isEmpty else {
                    req.logger.warning(
                        "rebalancing daily evaluation skipped stale valuation policy=\(policy.id?.uuidString ?? "unknown")"
                    )
                    continue
                }
                let event = RebalanceEventModel()
                event.userId = policy.userId
                event.$policy.id = try policy.requireID()
                event.status = RebalanceEventStatus.pending.rawValue
                event.preview = try WealthAutomationCoding.json(preview)
                try await req.db.transaction { db in
                    try await event.create(on: db)
                    policy.lastTriggeredAt = now
                    try await policy.update(on: db)
                }
                let eventId = try event.requireID()
                _ = try await NotificationEventPublisher.publishAndPush(
                    userId: policy.userId,
                    kind: .rebalancing,
                    deduplicationKey: "rebalance:\(eventId.uuidString)",
                    title: "Portfolio review needed",
                    body: "Your rebalancing rule was triggered. Review the draft before making trades.",
                    deepLink: "financeplan://automation/rebalancing/\(policy.portfolioListId.uuidString)",
                    payload: ["event_id": eventId.uuidString, "portfolio_list_id": policy.portfolioListId.uuidString],
                    req: req
                )
            } catch {
                req.logger.warning("rebalancing daily evaluation failed policy=\(policy.id?.uuidString ?? "unknown")")
            }
        }
    }
}

private struct LeaseAcquisition: Decodable {
    let owner: String
}

private final class WealthAutomationDailyJobState: @unchecked Sendable {
    // Every mutable field is accessed only while holding this lock.
    private let lock = NSLock()
    private var running = false
    private var scheduled: RepeatedTask?
    private var task: Task<Void, Never>?

    func begin() -> Bool {
        lock.withLock {
            guard !running else { return false }
            running = true
            return true
        }
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
        lock.withLock {
            scheduled?.cancel()
            scheduled = nil
            task?.cancel()
            task = nil
            running = false
        }
    }
}
