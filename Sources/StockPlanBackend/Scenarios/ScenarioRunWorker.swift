import Fluent
import FluentSQL
import Foundation
import NIOCore
import Vapor

final class ScenarioRunWorker: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let maxConcurrent: Int
    private let workerID = UUID().uuidString
    private let lock = NSLock()
    private var scheduled: RepeatedTask?
    private var running = false

    init(intervalSeconds: Int64 = 2, maxConcurrent: Int = 2) {
        self.intervalSeconds = max(1, intervalSeconds)
        self.maxConcurrent = max(1, min(maxConcurrent, 8))
    }

    func didBoot(_ app: Application) throws {
        guard envBool("SCENARIO_PLANNING_ENABLED", default: false) else { return }
        scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .seconds(1),
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
        lock.lock(); scheduled?.cancel(); scheduled = nil; lock.unlock()
    }

    func runOnce(_ app: Application) async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< maxConcurrent {
                guard let runID = try? await claim(on: app.db) else { break }
                group.addTask { await self.execute(runID, app: app) }
            }
        }
    }

    private func claim(on database: any Database) async throws -> UUID? {
        guard let sql = database as? any SQLDatabase else { return nil }
        let rows = try await sql.raw("""
        WITH candidate AS (
            SELECT id FROM scenario_runs
            WHERE state = 'queued'
               OR (state = 'running' AND lease_expires_at < NOW())
            ORDER BY created_at ASC
            FOR UPDATE SKIP LOCKED
            LIMIT 1
        )
        UPDATE scenario_runs AS run
        SET state = 'running', progress = GREATEST(progress, 0.01),
            started_at = COALESCE(started_at, NOW()),
            lease_owner = \(bind: workerID), lease_expires_at = NOW() + INTERVAL '60 seconds'
        FROM candidate WHERE run.id = candidate.id
        RETURNING run.id
        """).all()
        return try rows.first?.decode(column: "id", as: UUID.self)
    }

    private func execute(_ id: UUID, app: Application) async {
        do {
            guard let run = try await ScenarioRunModel.query(on: app.db)
                .filter(\.$id == id).with(\.$scenario).with(\.$snapshot).first()
            else { return }
            if run.state == "cancelled" {
                return
            }
            run.progress = 0.15
            try await run.save(on: app.db)
            let result = try ScenarioRunProcessor().process(run: run)
            guard run.state != "cancelled" else { return }
            run.result = result; run.state = "completed"; run.progress = 1
            run.completedAt = Date(); run.leaseOwner = nil; run.leaseExpiresAt = nil
            try await run.save(on: app.db)
        } catch {
            guard let run = try? await ScenarioRunModel.find(id, on: app.db), run.state != "cancelled" else { return }
            run.state = "failed"; run.errorMessage = String(describing: error)
            run.completedAt = Date(); run.leaseOwner = nil; run.leaseExpiresAt = nil
            try? await run.save(on: app.db)
            app.logger.error("scenario_run failed id=\(id) error=\(error)")
        }
    }

    private func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return false }; running = true; return true
    }

    private func finish() {
        lock.lock(); running = false; lock.unlock()
    }
}

struct ScenarioRunProcessor {
    func process(run: ScenarioRunModel) throws -> ScenarioJSON {
        let configuration = run.scenario.configuration.values
        let snapshot = run.snapshot.payload.values
        let initialValue = snapshot["total_value"]?.number ?? 0
        guard initialValue > 0 else { throw Abort(.unprocessableEntity, reason: "Snapshot total_value must be positive") }

        switch run.scenario.kind {
        case "monte_carlo": return monteCarlo(initialValue: initialValue, configuration: configuration, seed: run.seed)
        case "custom": return deterministic(initialValue: initialValue, change: configuration["portfolio_shock"]?.number ?? 0)
        case "historical": return deterministic(initialValue: initialValue, change: configuration["historical_return"]?.number ?? -0.2)
        default: throw Abort(.unprocessableEntity, reason: "Unsupported scenario kind")
        }
    }

    private func deterministic(initialValue: Double, change: Double) -> ScenarioJSON {
        let ending = max(0, initialValue * (1 + change))
        return ScenarioJSON([
            "timeline": .array([
                .object(["elapsed_months": .number(0), "value": .number(initialValue)]),
                .object(["elapsed_months": .number(1), "value": .number(ending)]),
            ]),
            "maximum_drawdown": .number(max(0, -change)),
            "ending_value": .number(ending),
        ])
    }

    private func monteCarlo(initialValue: Double, configuration: [String: ScenarioJSONValue], seed: String) -> ScenarioJSON {
        let pathCount = max(1, min(Int(configuration["path_count"]?.number ?? 10000), 50000))
        let months = max(1, min(Int(configuration["horizon_months"]?.number ?? 360), 600))
        let values = ScenarioEngine().monteCarloTerminalValues(
            initialValue: initialValue,
            monthlyContribution: configuration["monthly_contribution"]?.number ?? 0,
            annualReturn: configuration["annual_return"]?.number ?? 0.07,
            annualVolatility: configuration["annual_volatility"]?.number ?? 0.15,
            horizonMonths: months,
            pathCount: pathCount,
            seed: UInt64(seed) ?? 0
        ).sorted()
        func percentile(_ value: Double) -> Double {
            values[min(values.count - 1, Int(Double(values.count - 1) * value))]
        }
        return ScenarioJSON([
            "path_count": .number(Double(pathCount)), "horizon_months": .number(Double(months)),
            "p10": .number(percentile(0.10)), "p25": .number(percentile(0.25)),
            "p50": .number(percentile(0.50)), "p75": .number(percentile(0.75)),
            "p90": .number(percentile(0.90)),
        ])
    }
}
