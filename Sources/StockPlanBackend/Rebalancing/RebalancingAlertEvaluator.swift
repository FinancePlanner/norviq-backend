import Fluent
import Foundation
import NIOCore
import StockPlanShared
import Vapor

struct RebalancingAlertEvaluator: Sendable {
    static let deviceCapability = "rebalance_drift_v1"

    func evaluate(req: Request) async {
        do {
            let activeModels = try await AllocationModelRecord.query(on: req.db)
                .filter(\.$isActive == true)
                .all()
            for model in activeModels where !Task.isCancelled {
                try await evaluate(model: model, req: req)
            }
        } catch {
            req.logger.error("rebalancing.alerts evaluation failed error_type=\(String(reflecting: type(of: error)))")
        }
    }

    private func evaluate(model: AllocationModelRecord, req: Request) async throws {
        guard let portfolio = try await PortfolioList.find(model.portfolioId, on: req.db),
              portfolio.archivedAt == nil
        else { return }
        guard let overview = try? await req.rebalancingService.overview(
            portfolioId: model.portfolioId,
            userId: portfolio.userId,
            req: req
        ), overview.priceQuality != .incomplete, let allocationModel = overview.model
        else { return }

        let members = try await PortfolioMembershipRecord.query(on: req.db)
            .filter(\.$portfolioId == model.portfolioId)
            .filter(\.$status == PortfolioMembershipStatus.active.rawValue)
            .all()
        let userIds = Array(Set([portfolio.userId] + members.map(\.userId)))
        let scopes = scopes(overview: overview, model: allocationModel)
        for userId in userIds {
            try await reconcile(
                scopes: scopes,
                model: allocationModel,
                portfolio: portfolio,
                userId: userId,
                req: req
            )
        }
    }

    private func reconcile(
        scopes: [Scope],
        model: AllocationModel,
        portfolio: PortfolioList,
        userId: UUID,
        req: Request
    ) async throws {
        guard let modelId = UUID(uuidString: model.id),
              let portfolioId = UUID(uuidString: model.portfolioId)
        else { return }
        let existing = try await RebalancingAlertRecord.query(on: req.db)
            .filter(\.$modelId == modelId)
            .filter(\.$userId == userId)
            .filter(\.$activeScopeKey != nil)
            .all()
        let existingByScope = Dictionary(uniqueKeysWithValues: existing.map { ($0.scopeId, $0) })
        let currentByScope = Dictionary(uniqueKeysWithValues: scopes.map { ($0.id, $0) })

        for record in existing {
            guard let scope = currentByScope[record.scopeId] else {
                try await resolve(record, on: req.db)
                continue
            }
            record.driftBasisPoints = scope.driftBasisPoints
            record.thresholdBasisPoints = scope.thresholdBasisPoints
            if abs(scope.driftBasisPoints) < Int(Double(scope.thresholdBasisPoints) * 0.8) {
                try await resolve(record, on: req.db)
            } else {
                try await record.save(on: req.db)
            }
        }

        for scope in scopes where abs(scope.driftBasisPoints) >= scope.thresholdBasisPoints {
            guard existingByScope[scope.id] == nil else { continue }
            let record = RebalancingAlertRecord()
            record.id = UUID()
            record.portfolioId = portfolioId
            record.modelId = modelId
            record.userId = userId
            record.scopeId = scope.id
            record.scopeName = scope.name
            record.driftBasisPoints = scope.driftBasisPoints
            record.thresholdBasisPoints = scope.thresholdBasisPoints
            record.status = RebalancingAlertStatus.open.rawValue
            record.activeScopeKey = "\(model.id):\(userId.uuidString):\(scope.id)"
            record.triggeredAt = Date()
            try await record.create(on: req.db)
            try await sendPushIfEnabled(record: record, portfolio: portfolio, req: req)
        }
    }

    private func sendPushIfEnabled(record: RebalancingAlertRecord, portfolio: PortfolioList, req: Request) async throws {
        let preference = try await RebalancingNotificationPreferenceRecord.query(on: req.db)
            .filter(\.$portfolioId == record.portfolioId)
            .filter(\.$userId == record.userId)
            .first()
        guard preference?.pushEnabled == true else { return }
        let devices = try await req.pushDeviceService.activeDevices(userId: record.userId, on: req.db).filter {
            let values = (try? JSONDecoder().decode([String].self, from: Data($0.capabilitiesJSON.utf8))) ?? []
            return values.contains(Self.deviceCapability)
        }
        guard !devices.isEmpty else { return }
        let alert = try makeAlert(record)
        _ = await req.application.pushNotificationSender.sendRebalancingDrift(
            alert: alert,
            portfolioName: portfolio.name,
            devices: devices,
            req: req
        )
    }

    private func resolve(_ record: RebalancingAlertRecord, on database: any Database) async throws {
        record.status = RebalancingAlertStatus.resolved.rawValue
        record.resolvedAt = Date()
        record.activeScopeKey = nil
        try await record.save(on: database)
    }

    private func scopes(overview: RebalancingOverview, model: AllocationModel) -> [Scope] {
        var thresholds = [String: Int]()
        for bucket in model.buckets {
            thresholds[bucket.id] = bucket.alertThresholdBasisPoints ?? model.defaultTargetThresholdBasisPoints
            for leaf in bucket.leaves {
                thresholds[leaf.id] = leaf.alertThresholdBasisPoints ?? model.defaultTargetThresholdBasisPoints
            }
        }
        var result = [Scope(
            id: "portfolio",
            name: "Total portfolio",
            driftBasisPoints: overview.totalDriftBasisPoints,
            thresholdBasisPoints: model.totalThresholdBasisPoints
        )]
        func append(_ row: RebalancingAllocationRow) {
            result.append(Scope(
                id: row.id,
                name: row.label,
                driftBasisPoints: row.driftBasisPoints,
                thresholdBasisPoints: thresholds[row.id] ?? model.defaultTargetThresholdBasisPoints
            ))
            row.children.forEach(append)
        }
        overview.rows.forEach(append)
        return result
    }

    private func makeAlert(_ record: RebalancingAlertRecord) throws -> RebalancingAlert {
        try RebalancingAlert(
            id: record.requireID().uuidString,
            portfolioId: record.portfolioId.uuidString,
            modelId: record.modelId.uuidString,
            scopeId: record.scopeId,
            scopeName: record.scopeName,
            driftBasisPoints: record.driftBasisPoints,
            thresholdBasisPoints: record.thresholdBasisPoints,
            status: .open,
            triggeredAt: ISO8601DateFormatter().string(from: record.triggeredAt)
        )
    }

    private struct Scope: Sendable {
        let id: String
        let name: String
        let driftBasisPoints: Int
        let thresholdBasisPoints: Int
    }
}

final class RebalancingAlertPoller: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let state = RebalancingPollerState()

    init(intervalSeconds: Int64) {
        self.intervalSeconds = max(intervalSeconds, 60)
    }

    func didBoot(_ app: Application) throws {
        let scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .seconds(45),
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
        await RebalancingAlertEvaluator().evaluate(req: request)
    }
}

private final class RebalancingPollerState: @unchecked Sendable {
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

    func set(scheduled: RepeatedTask) {
        lock.withLock { self.scheduled = scheduled }
    }

    func set(task: Task<Void, Never>) {
        lock.withLock { self.task = task }
    }

    func finish() {
        lock.withLock {
            task = nil
            running = false
        }
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
