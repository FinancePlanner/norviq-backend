import Fluent
import FluentSQL
import Foundation
import NIOCore
import Redis
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
        if let depth = try? await ScenarioRunModel.query(on: app.db).filter(\.$state == "queued").count() {
            PrometheusMetrics.shared.setScenarioQueueDepth(depth)
        }
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
        let clock = ContinuousClock(); let started = clock.now
        do {
            guard let run = try await ScenarioRunModel.query(on: app.db)
                .filter(\.$id == id).with(\.$scenario).with(\.$snapshot).first()
            else { return }
            if run.state == "cancelled" {
                return
            }
            run.progress = 0.15
            try await run.save(on: app.db)
            let simulation = Task {
                let result = try await ScenarioRunProcessor().process(run: run, on: app.db)
                try Task.checkCancellation(); return result
            }
            let heartbeat = Task { await self.renewLease(runID: id, simulation: simulation, app: app) }
            let result = try await simulation.value
            heartbeat.cancel()
            guard let current = try await ScenarioRunModel.find(id, on: app.db), current.state != "cancelled" else { return }
            run.result = result; run.state = "completed"; run.progress = 1
            run.completedAt = Date(); run.leaseOwner = nil; run.leaseExpiresAt = nil
            try await run.save(on: app.db)
            await cache(result: result, runID: id, app: app)
            let warningCodes = result.values["warnings"]?.array?.compactMap {
                $0.object?["code"]?.string
            } ?? []
            PrometheusMetrics.shared.recordScenarioDataQuality(
                proxyCount: warningCodes.count(where: { $0 == "proxy_used" }),
                missingHistoryCount: warningCodes.count(where: {
                    $0 == "missing_history" || $0 == "missing_bootstrap_history"
                })
            )
            let paths = Int(run.scenario.configuration.values["path_count"]?.number ?? 0)
            PrometheusMetrics.shared.recordScenarioCompleted(paths: paths, duration: started.duration(to: clock.now))
        } catch {
            guard let run = try? await ScenarioRunModel.find(id, on: app.db), run.state != "cancelled" else { return }
            run.state = "failed"; run.errorMessage = String(describing: error)
            run.completedAt = Date(); run.leaseOwner = nil; run.leaseExpiresAt = nil
            try? await run.save(on: app.db)
            PrometheusMetrics.shared.recordScenarioFailed()
            app.logger.error("scenario_run failed id=\(id) error=\(error)")
        }
    }

    private func renewLease(
        runID: UUID, simulation: Task<ScenarioJSON, any Error>, app: Application
    ) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled,
                  let run = try? await ScenarioRunModel.find(runID, on: app.db) else { return }
            guard run.state == "running", run.leaseOwner == workerID else { simulation.cancel(); return }
            run.leaseExpiresAt = Date().addingTimeInterval(60); try? await run.save(on: app.db)
        }
    }

    private func cache(result: ScenarioJSON, runID: UUID, app: Application) async {
        guard app.redis.configuration != nil,
              let data = try? JSONEncoder().encode(result), let value = String(data: data, encoding: .utf8)
        else { return }
        let key = RedisKey("scenario:result:\(runID.uuidString.lowercased())")
        try? await app.redis.set(key, to: value).get()
        _ = try? await app.redis.expire(key, after: .seconds(86400)).get()
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
    func process(run: ScenarioRunModel, on database: any Database) async throws -> ScenarioJSON {
        var configuration = run.scenario.configuration.values
        let snapshot = run.snapshot.payload.values
        let initialValue = snapshot["total_value"]?.number ?? 0
        guard initialValue > 0 else { throw Abort(.unprocessableEntity, reason: "Snapshot total_value must be positive") }

        // Inject linked goal for every scenario kind so historical/custom runs get impact metrics.
        if let goalID = run.scenario.financialGoalId,
           let goal = try await FinancialGoalModel.owned(by: run.userId, on: database).filter(\.$id == goalID).first()
        {
            configuration["target_amount"] = .number(goal.targetAmount)
            if configuration["monthly_contribution"] == nil {
                configuration["monthly_contribution"] = .number(goal.monthlyContribution)
            }
            if configuration["annual_contribution_growth"] == nil {
                configuration["annual_contribution_growth"] = .number(goal.annualContributionGrowth)
            }
            if configuration["inflation"] == nil {
                configuration["inflation"] = .number(goal.inflationAssumption)
            }
            let calendar = Calendar(identifier: .gregorian)
            let targetMonths = calendar.dateComponents(
                [.month], from: run.snapshot.valuationTimestamp, to: goal.targetDate
            ).month ?? 1
            if configuration["horizon_months"] == nil {
                configuration["horizon_months"] = .number(Double(max(1, min(targetMonths, 600))))
            }
            configuration["goal_horizon_months"] = .number(Double(max(1, min(targetMonths, 600))))
            configuration["financial_goal_id"] = .string(goalID.uuidString)
        }

        switch run.scenario.kind {
        case "monte_carlo": return try await monteCarlo(
                initialValue: initialValue, snapshot: snapshot, configuration: configuration,
                seed: run.seed, valuationDate: run.snapshot.valuationTimestamp, on: database
            )
        case "custom": return custom(snapshot: snapshot, configuration: configuration)
        case "historical": return try await historical(snapshot: snapshot, configuration: configuration, on: database)
        default: throw Abort(.unprocessableEntity, reason: "Unsupported scenario kind")
        }
    }

    private func historical(
        snapshot: [String: ScenarioJSONValue], configuration: [String: ScenarioJSONValue], on database: any Database
    ) async throws -> ScenarioJSON {
        let preset = configuration["catalog_id"]?.string ?? configuration["catalogId"]?.string ?? "covid_crash"
        let dates = switch preset {
        case "dot_com_decline": ("2000-03-24", "2002-10-09")
        case "global_financial_crisis": ("2007-10-09", "2009-03-09")
        case "2022_rate_shock": ("2022-01-03", "2022-10-12")
        case "tech_2022": ("2022-01-03", "2022-10-14")
        default: ("2020-02-19", "2020-03-23")
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        guard let start = formatter.date(from: dates.0), let end = formatter.date(from: dates.1) else { throw Abort(.internalServerError) }
        let holdings = snapshot["holdings"]?.array?.compactMap(\.object) ?? []
        let initial = holdings.reduce(0) { $0 + ($1["value_in_base_currency"]?.number ?? 0) }
        var ending = 0.0; var contributions: [ScenarioJSONValue] = []; var warnings: [ScenarioJSONValue] = []
        var seriesByHolding: [String: [(date: Date, close: Double)]] = [:]
        var valueByHolding: [String: Double] = [:]
        for holding in holdings {
            let value = holding["value_in_base_currency"]?.number ?? 0
            let symbol = holding["instrument_key"]?.string ?? ""
            var series = try await MarketPriceBarRepository().adjustedCloses(instrumentKey: symbol, from: start, to: end, on: database)
            var usedProxy: String?
            if series.count < 2, let proxy = holding["benchmark_proxy"]?.string {
                series = try await MarketPriceBarRepository().adjustedCloses(instrumentKey: proxy, from: start, to: end, on: database)
                usedProxy = proxy
            }
            let change = series.count >= 2 ? (series.last!.close / series.first!.close - 1) : 0
            let result = max(0, value * (1 + change)); ending += result
            let id = holding["id"]?.string ?? symbol
            seriesByHolding[id] = series; valueByHolding[id] = value
            contributions.append(.object(["key": .string(id), "amount": .number(result - value), "percentage_points": .number(initial == 0 ? 0 : (result - value) / initial)]))
            if let usedProxy {
                warnings.append(.object(["code": .string("proxy_used"), "holding_id": .string(id), "message": .string("Used benchmark proxy \(usedProxy).")]))
            } else if series.count < 2 {
                warnings.append(.object(["code": .string("missing_history"), "holding_id": .string(id), "message": .string("No aligned history was available.")]))
            }
        }
        let allDates = Set(seriesByHolding.values.flatMap { $0.map(\.date) }).sorted()
        var timeline: [ScenarioJSONValue] = []; var peak = initial; var maximumDrawdown = 0.0
        for date in allDates {
            var portfolioValue = 0.0
            for (id, series) in seriesByHolding {
                guard let first = series.first?.close else { portfolioValue += valueByHolding[id] ?? 0; continue }
                let current = series.last(where: { $0.date <= date })?.close ?? first
                portfolioValue += (valueByHolding[id] ?? 0) * current / first
            }
            peak = max(peak, portfolioValue)
            if peak > 0 {
                maximumDrawdown = max(maximumDrawdown, (peak - portfolioValue) / peak)
            }
            timeline.append(.object([
                "elapsed_days": .number(max(0, date.timeIntervalSince(start) / 86400)), "date": .string(formatter.string(from: date)),
                "value": .number(portfolioValue), "percentage_change": .number(initial > 0 ? portfolioValue / initial - 1 : 0),
            ]))
        }
        if timeline.isEmpty {
            timeline = [.object(["elapsed_days": .number(0), "date": .string(dates.0), "value": .number(initial), "percentage_change": .number(0)])]
        }
        let values = timeline.compactMap { $0.object?["value"]?.number }
        let recoveryDays = recoveryElapsed(
            timeline: timeline, initialValue: initial, elapsedKey: "elapsed_days"
        )
        let recoveryMonths = recoveryDays.map { $0 / 30.4375 }
        var result: [String: ScenarioJSONValue] = [
            "timeline": .array(timeline), "maximum_drawdown": .number(maximumDrawdown), "ending_value": .number(ending),
            "holding_contributions": .array(contributions), "warnings": .array(warnings),
            "catalog_id": .string(preset), "catalog_version": .string(ScenarioCatalog.version),
            "assumptions": .object([
                "valuation_currency": snapshot["base_currency"] ?? .null,
                "financial_goal_id": configuration["financial_goal_id"] ?? .null,
            ]),
        ]
        mergeImpact(
            into: &result,
            initialValue: initial,
            stressedValue: ending,
            configuration: configuration,
            recoveryMonths: recoveryMonths,
            timelineValues: values
        )
        return ScenarioJSON(result)
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

    func custom(
        snapshot: [String: ScenarioJSONValue], configuration: [String: ScenarioJSONValue]
    ) -> ScenarioJSON {
        let holdings = snapshot["holdings"]?.array?.compactMap(\.object) ?? []
        let holdingShocks = shocks(configuration["holding_shocks"])
        let classShocks = shocks(configuration["asset_class_shocks"])
        let sectorShocks = shocks(configuration["sector_shocks"])
        let regionShocks = shocks(configuration["region_shocks"])
        let currencyShocks = shocks(configuration["currency_shocks"])
        let rateShift = (configuration["parallel_rate_shift_bps"]?.number ?? 0) / 10000
        let volatilityMultiplier = max(0, configuration["volatility_multiplier"]?.number ?? 1)
        let initial = holdings.reduce(0) { $0 + ($1["value_in_base_currency"]?.number ?? 0) }
        var stressed = 0.0
        var holdingContributions: [ScenarioJSONValue] = []
        var classTotals: [String: Double] = [:]

        for holding in holdings {
            let id = holding["id"]?.string ?? ""
            let value = holding["value_in_base_currency"]?.number ?? 0
            let assetClass = holding["asset_category"]?.string ?? "stock"
            let sector = holding["sector"]?.string
            let region = holding["region"]?.string
            let currency = holding["currency"]?.string ?? ""
            var multiplier = 1.0
            if let override = holdingShocks[id] {
                multiplier = 1 + override
            } else {
                multiplier *= 1 + (classShocks[assetClass] ?? 0)
                multiplier *= 1 + (sector.flatMap { sectorShocks[$0] } ?? 0)
                multiplier *= 1 + (region.flatMap { regionShocks[$0] } ?? 0)
                multiplier *= 1 + (currencyShocks[currency] ?? 0)
            }
            // A holding override replaces broader percentage shocks, but independent rate-factor
            // effects still apply to the holding.
            if assetClass == "bond", let duration = holding["duration"]?.number {
                let convexity = holding["convexity"]?.number ?? 0
                multiplier *= 1 - duration * rateShift + 0.5 * convexity * rateShift * rateShift
            } else if assetClass == "cash" {
                multiplier *= 1 + rateShift / 12
            } else if ["stock", "etf", "mutual_fund", "real_estate"].contains(assetClass) {
                let overrides = holding["factor_overrides"]?.object
                let sensitivity = overrides?["rate_sensitivity"]?.number ?? Self.defaultRateSensitivity[assetClass] ?? 0
                multiplier *= max(0, 1 - sensitivity * rateShift)
            }
            let result = max(0, value * multiplier); let contribution = result - value
            stressed += result; classTotals[assetClass, default: 0] += contribution
            holdingContributions.append(.object([
                "key": .string(id), "amount": .number(contribution),
                "percentage_points": .number(initial == 0 ? 0 : contribution / initial),
            ]))
        }
        let months = max(1, min(Int(configuration["horizon_months"]?.number ?? 1), 120))
        let recovery = configuration["recovery"]?.string ?? "none"
        let timeline = (0 ... months).map { month -> ScenarioJSONValue in
            let fraction = recoveryFraction(model: recovery, month: month, horizon: months)
            return .object(["elapsed_months": .number(Double(month)), "value": .number(stressed + (initial - stressed) * fraction)])
        }
        let timelineValues = timeline.compactMap { $0.object?["value"]?.number }
        let recoveryMonths = ScenarioEngine().recoveryMonths(timelineValues: timelineValues, initialValue: initial)
        var result: [String: ScenarioJSONValue] = [
            "timeline": .array(timeline), "maximum_drawdown": .number(initial > 0 ? max(0, (initial - stressed) / initial) : 0),
            "ending_value": .number((timeline.last?.object?["value"]?.number) ?? stressed),
            "holding_contributions": .array(holdingContributions),
            "class_contributions": .array(classTotals.sorted(by: { $0.key < $1.key }).map {
                .object(["key": .string($0.key), "amount": .number($0.value), "percentage_points": .number(initial == 0 ? 0 : $0.value / initial)])
            }),
            "assumptions": .object([
                "parallel_rate_shift_bps": configuration["parallel_rate_shift_bps"] ?? .number(0),
                "volatility_multiplier": .number(volatilityMultiplier),
                "rate_sensitivity_defaults_version": .string(ScenarioEngine.version),
                "recovery": .string(recovery),
                "financial_goal_id": configuration["financial_goal_id"] ?? .null,
            ]),
        ]
        mergeImpact(
            into: &result,
            initialValue: initial,
            stressedValue: stressed,
            configuration: configuration,
            recoveryMonths: recoveryMonths,
            timelineValues: timelineValues
        )
        return ScenarioJSON(result)
    }

    private func recoveryElapsed(
        timeline: [ScenarioJSONValue], initialValue: Double, elapsedKey: String
    ) -> Double? {
        guard initialValue > 0 else { return nil }
        for (index, point) in timeline.enumerated() where index > 0 {
            guard let object = point.object, let value = object["value"]?.number, value >= initialValue else { continue }
            return object[elapsedKey]?.number ?? Double(index)
        }
        return nil
    }

    private func mergeImpact(
        into result: inout [String: ScenarioJSONValue],
        initialValue: Double,
        stressedValue: Double,
        configuration: [String: ScenarioJSONValue],
        recoveryMonths: Double?,
        timelineValues: [Double]
    ) {
        let engine = ScenarioEngine()
        let recovery = recoveryMonths ?? engine.recoveryMonths(timelineValues: timelineValues, initialValue: initialValue)
        let rawHorizon = Int(
            configuration["goal_horizon_months"]?.number
                ?? configuration["horizon_months"]?.number
                ?? 0
        )
        let impact = engine.goalImpact(
            ScenarioGoalImpactInput(
                initialValue: initialValue,
                stressedValue: stressedValue,
                monthlyContribution: configuration["monthly_contribution"]?.number ?? 0,
                annualReturn: configuration["annual_return"]?.number ?? 0.07,
                annualInflation: configuration["inflation"]?.number ?? 0.02,
                annualContributionGrowth: configuration["annual_contribution_growth"]?.number ?? 0,
                targetAmount: configuration["target_amount"]?.number,
                horizonMonths: rawHorizon > 0 ? rawHorizon : nil,
                recoveryMonths: recovery,
                monthlySpending: configuration["monthly_spending"]?.number
            )
        )
        // Do not overwrite ending_value — custom recovery timelines keep the path end;
        // portfolio_change_percent reflects the immediate stressed trough.
        if result["ending_value"] == nil {
            result["ending_value"] = .number(impact.endingValue)
        }
        result["portfolio_change_percent"] = .number(impact.portfolioChangePercent)
        result["goal_delay_months"] = impact.goalDelayMonths.map(ScenarioJSONValue.number) ?? .null
        result["required_monthly_contribution"] = impact.requiredMonthlyContribution.map(ScenarioJSONValue.number) ?? .null
        result["contribution_delta"] = impact.contributionDelta.map(ScenarioJSONValue.number) ?? .null
        result["recovery_months"] = impact.recoveryMonths.map(ScenarioJSONValue.number) ?? .null
        result["expense_impact_monthly"] = impact.expenseImpactMonthly.map(ScenarioJSONValue.number) ?? .null
    }

    private static let defaultRateSensitivity = [
        "stock": 2.0, "etf": 2.0, "mutual_fund": 2.0, "real_estate": 4.0,
    ]

    private func shocks(_ value: ScenarioJSONValue?) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: (value?.array ?? []).compactMap { item in
            guard let object = item.object, let target = object["target"]?.string,
                  let percentage = object["percentage"]?.number else { return nil }
            return (target, percentage)
        })
    }

    private func recoveryFraction(model: String, month: Int, horizon: Int) -> Double {
        guard month > 0, horizon > 0 else { return 0 }
        let progress = Double(month) / Double(horizon)
        switch model {
        case "linear": return progress
        case "mean_reverting": return min(1, 1 - exp(-4 * progress))
        default: return 0
        }
    }

    private func monteCarlo(
        initialValue: Double, snapshot: [String: ScenarioJSONValue],
        configuration: [String: ScenarioJSONValue], seed: String,
        valuationDate: Date, on database: any Database
    ) async throws -> ScenarioJSON {
        let pathCount = max(1, min(Int(configuration["path_count"]?.number ?? 10000), 50000))
        let months = max(1, min(Int(configuration["horizon_months"]?.number ?? 360), 600))
        let distribution: ScenarioSimulationDistribution
        var warnings: [ScenarioJSONValue] = []
        switch configuration["distribution"]?.string {
        case "student_t": distribution = .studentT(degreesOfFreedom: Int(configuration["degrees_of_freedom"]?.number ?? 5))
        case "block_bootstrap":
            var returns = configuration["historical_monthly_returns"]?.array?.compactMap(\.number) ?? []
            if returns.isEmpty {
                let history = try await historicalPortfolioMonthlyReturns(
                    snapshot: snapshot, valuationDate: valuationDate, on: database
                )
                returns = history.returns; warnings = history.warnings
            }
            if returns.isEmpty {
                warnings.append(.object([
                    "code": .string("missing_bootstrap_history"),
                    "message": .string("Historical monthly returns were unavailable; expected return was used."),
                ]))
            }
            distribution = .blockBootstrap(monthlyReturns: returns, blockMonths: Int(configuration["bootstrap_block_months"]?.number ?? 6))
        default: distribution = .normal
        }
        let weights = configuration["asset_weights"]?.array?.compactMap(\.number) ?? []
        let returns = configuration["asset_annual_returns"]?.array?.compactMap(\.number) ?? []
        let covariance = configuration["annual_covariance"]?.array?.compactMap { row in row.array?.compactMap(\.number) } ?? []
        if !weights.isEmpty, weights.count == returns.count, covariance.count == weights.count {
            let studentDegrees = configuration["distribution"]?.string == "student_t"
                ? Int(configuration["degrees_of_freedom"]?.number ?? 5) : nil
            let correlated = ScenarioEngine().simulateCorrelated(.init(
                initialValue: initialValue, weights: weights, annualReturns: returns, annualCovariance: covariance,
                monthlyContribution: configuration["monthly_contribution"]?.number ?? 0,
                annualContributionGrowth: configuration["annual_contribution_growth"]?.number ?? 0,
                annualInflation: configuration["inflation"]?.number ?? 0.02,
                horizonMonths: months, pathCount: pathCount, seed: UInt64(seed) ?? 0,
                targetAmount: configuration["target_amount"]?.number, studentTDegreesOfFreedom: studentDegrees
            ))
            return simulationJSON(correlated, pathCount: pathCount, months: months, configuration: configuration, warnings: warnings)
        }
        let output = ScenarioEngine().simulate(.init(
            initialValue: initialValue, monthlyContribution: configuration["monthly_contribution"]?.number ?? 0,
            annualContributionGrowth: configuration["annual_contribution_growth"]?.number ?? 0,
            annualReturn: configuration["annual_return"]?.number ?? 0.07,
            annualVolatility: configuration["annual_volatility"]?.number ?? 0.15,
            annualInflation: configuration["inflation"]?.number ?? 0.02,
            horizonMonths: months, pathCount: pathCount, seed: UInt64(seed) ?? 0,
            targetAmount: configuration["target_amount"]?.number, distribution: distribution
        ))
        return simulationJSON(output, pathCount: pathCount, months: months, configuration: configuration, warnings: warnings)
    }

    private func simulationJSON(
        _ output: ScenarioSimulationOutput, pathCount: Int, months: Int,
        configuration: [String: ScenarioJSONValue], warnings: [ScenarioJSONValue]
    ) -> ScenarioJSON {
        let medianEnding = output.bands.last?.p50
        let initialFromBands = output.bands.first?.p50
        var payload: [String: ScenarioJSONValue] = [
            "path_count": .number(Double(pathCount)), "horizon_months": .number(Double(months)),
            "percentile_bands": .array(output.bands.map { .object([
                "elapsed_months": .number(Double($0.month)), "p10": .number($0.p10), "p25": .number($0.p25),
                "p50": .number($0.p50), "p75": .number($0.p75), "p90": .number($0.p90),
            ]) }),
            "goal_probability": output.goalProbability.map(ScenarioJSONValue.number) ?? .null,
            "expected_shortfall": output.expectedShortfall.map(ScenarioJSONValue.number) ?? .null,
            "maximum_drawdown": .number(output.medianMaximumDrawdown),
            "warnings": .array(warnings),
            "assumptions": .object([
                "distribution": configuration["distribution"] ?? .string("normal"),
                "annual_return": configuration["annual_return"] ?? .number(0.07),
                "annual_volatility": configuration["annual_volatility"] ?? .number(0.15),
                "inflation": configuration["inflation"] ?? .number(0.02),
                "monthly_contribution": configuration["monthly_contribution"] ?? .number(0),
                "annual_contribution_growth": configuration["annual_contribution_growth"] ?? .number(0),
                "financial_goal_id": configuration["financial_goal_id"] ?? .null,
            ]),
        ]
        if let medianEnding, let initialFromBands, initialFromBands > 0 {
            payload["ending_value"] = .number(medianEnding)
            payload["portfolio_change_percent"] = .number(medianEnding / initialFromBands - 1)
        }
        return ScenarioJSON(payload)
    }

    private func historicalPortfolioMonthlyReturns(
        snapshot: [String: ScenarioJSONValue], valuationDate: Date, on database: any Database
    ) async throws -> (returns: [Double], warnings: [ScenarioJSONValue]) {
        let holdings = snapshot["holdings"]?.array?.compactMap(\.object) ?? []
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(byAdding: .year, value: -10, to: valuationDate) ?? valuationDate
        let total = holdings.reduce(0.0) { $0 + max(0, $1["value_in_base_currency"]?.number ?? 0) }
        guard total > 0 else { return ([], []) }
        var returnsByHolding: [(weight: Double, values: [Int: Double])] = []
        var warnings: [ScenarioJSONValue] = []

        for holding in holdings {
            let id = holding["id"]?.string ?? "unknown"
            let value = max(0, holding["value_in_base_currency"]?.number ?? 0)
            guard value > 0 else { continue }
            let instrument = holding["instrument_key"]?.string ?? ""
            var series = try await MarketPriceBarRepository().adjustedCloses(
                instrumentKey: instrument, from: start, to: valuationDate, on: database
            )
            if series.count < 2, let proxy = holding["benchmark_proxy"]?.string {
                series = try await MarketPriceBarRepository().adjustedCloses(
                    instrumentKey: proxy, from: start, to: valuationDate, on: database
                )
                if series.count >= 2 {
                    warnings.append(.object([
                        "code": .string("proxy_used"), "holding_id": .string(id),
                        "message": .string("Used benchmark proxy \(proxy) for bootstrap history."),
                    ]))
                }
            }
            var monthEnds: [Int: Double] = [:]
            for point in series {
                let components = calendar.dateComponents([.year, .month], from: point.date)
                guard let year = components.year, let month = components.month else { continue }
                monthEnds[year * 12 + month] = point.close
            }
            let months = monthEnds.keys.sorted()
            var monthlyReturns: [Int: Double] = [:]
            for index in 1 ..< months.count where months[index] == months[index - 1] + 1 {
                let previous = monthEnds[months[index - 1]] ?? 0
                if previous > 0, let current = monthEnds[months[index]] {
                    monthlyReturns[months[index]] = current / previous - 1
                }
            }
            if monthlyReturns.isEmpty {
                warnings.append(.object([
                    "code": .string("missing_history"), "holding_id": .string(id),
                    "message": .string("No monthly history was available for bootstrap sampling."),
                ]))
            }
            returnsByHolding.append((value / total, monthlyReturns))
        }

        let alignedMonths = Set(returnsByHolding.flatMap(\.values.keys)).sorted()
        let portfolioReturns = alignedMonths.compactMap { month -> Double? in
            let available = returnsByHolding.filter { $0.values[month] != nil }
            let coveredWeight = available.reduce(0.0) { $0 + $1.weight }
            guard coveredWeight >= 0.5 else { return nil }
            return available.reduce(0.0) { $0 + $1.weight * ($1.values[month] ?? 0) } / coveredWeight
        }
        return (portfolioReturns, warnings)
    }
}
