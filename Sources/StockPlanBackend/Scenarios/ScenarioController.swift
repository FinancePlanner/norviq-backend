import Crypto
import Fluent
import Foundation
import Redis
import Vapor

private struct FinancialGoalInput: Content {
    let portfolioListId: UUID
    let name: String
    let targetAmount: Double
    let targetDate: Date
    let baseCurrency: String
    let monthlyContribution: Double?
    let annualContributionGrowth: Double?
    let inflationAssumption: Double?
}

private struct ScenarioInput: Content {
    let portfolioListId: UUID
    let financialGoalId: UUID?
    let name: String
    let kind: String
    let configuration: ScenarioJSON
    let isSaved: Bool?
}

private struct SnapshotInput: Content {
    let portfolioListId: UUID
    let baseCurrency: String
    let valuationTimestamp: Date?
    let payload: ScenarioJSON?
    let warnings: ScenarioJSON?
    let cryptoHoldingIds: [UUID]?
}

private struct RunInput: Content {
    let snapshotId: UUID
    let seed: UInt64?
}

private struct CompareInput: Content { let runIds: [UUID] }
struct ComparisonResponse: Content { let runs: [ScenarioRunModel] }
private struct RiskProfileInput: Content {
    let holdingId: UUID
    let assetCategory: String
    let sector: String?
    let region: String?
    let benchmarkProxy: String?
    let manualValue: Double?
    let duration: Double?
    let convexity: Double?
    let factorOverrides: ScenarioJSON?
}

struct ScenarioController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        protected.group("financial-goals") { goals in
            goals.get(use: listGoals); goals.post(use: createGoal)
            goals.group(":id") { goal in goal.get(use: getGoal); goal.put(use: updateGoal); goal.delete(use: deleteGoal) }
        }
        protected.group("scenarios") { scenarios in
            scenarios.get("catalog", use: catalog)
            scenarios.get(use: listScenarios); scenarios.post(use: createScenario)
            scenarios.group(":id") { scenario in
                scenario.get(use: getScenario); scenario.put(use: updateScenario); scenario.delete(use: deleteScenario)
                scenario.post("runs", use: createRun)
            }
        }
        protected.group("portfolio", "scenario-snapshots") { snapshots in
            snapshots.get(use: listSnapshots); snapshots.post(use: createSnapshot)
            snapshots.get(":id", use: getSnapshot)
        }
        protected.group("scenario-runs") { runs in
            runs.get(use: listRuns); runs.post("compare", use: compareRuns)
            runs.get(":id", use: getRun); runs.delete(":id", use: cancelRun)
            runs.get(":id", "result", use: getResult)
        }
        protected.group("holding-risk-profiles") { profiles in
            profiles.get(use: listRiskProfiles); profiles.post(use: saveRiskProfile)
            profiles.delete(":id", use: deleteRiskProfile)
        }
    }

    @Sendable
    func catalog(req: Request) async throws -> ScenarioCatalogResponse {
        _ = try await authorize(req)
        return ScenarioCatalog.response
    }

    @Sendable func listGoals(req: Request) async throws -> [FinancialGoalModel] {
        let user = try await authorize(req); return try await FinancialGoalModel.owned(by: user, on: req.db).sort(\.$createdAt, .descending).all()
    }

    @Sendable func createGoal(req: Request) async throws -> FinancialGoalModel {
        let user = try await authorize(req); let input = try req.content.decode(FinancialGoalInput.self)
        guard !input.name.trimmingCharacters(in: .whitespaces).isEmpty, input.targetAmount > 0, input.baseCurrency.count == 3 else { throw Abort(.badRequest, reason: "Invalid financial goal") }
        try await requirePortfolio(input.portfolioListId, user: user, db: req.db)
        let goal = FinancialGoalModel(userId: user, portfolioListId: input.portfolioListId, name: input.name,
                                      targetAmount: input.targetAmount, targetDate: input.targetDate, baseCurrency: input.baseCurrency.uppercased(),
                                      monthlyContribution: input.monthlyContribution ?? 0, annualContributionGrowth: input.annualContributionGrowth ?? 0,
                                      inflationAssumption: input.inflationAssumption ?? 0.02)
        try await goal.save(on: req.db); return goal
    }

    @Sendable func getGoal(req: Request) async throws -> FinancialGoalModel {
        let user = try await authorize(req); return try await ownedGoal(req, user: user)
    }

    @Sendable func updateGoal(req: Request) async throws -> FinancialGoalModel {
        let user = try await authorize(req); let goal = try await ownedGoal(req, user: user); let input = try req.content.decode(FinancialGoalInput.self)
        try await requirePortfolio(input.portfolioListId, user: user, db: req.db)
        goal.portfolioListId = input.portfolioListId; goal.name = input.name; goal.targetAmount = input.targetAmount
        goal.targetDate = input.targetDate; goal.baseCurrency = input.baseCurrency.uppercased()
        goal.monthlyContribution = input.monthlyContribution ?? 0; goal.annualContributionGrowth = input.annualContributionGrowth ?? 0
        goal.inflationAssumption = input.inflationAssumption ?? 0.02; try await goal.save(on: req.db); return goal
    }

    @Sendable func deleteGoal(req: Request) async throws -> HTTPStatus {
        let user = try await authorize(req); try await ownedGoal(req, user: user).delete(on: req.db); return .noContent
    }

    @Sendable func listScenarios(req: Request) async throws -> [ScenarioDefinitionModel] {
        let user = try await authorize(req); return try await ScenarioDefinitionModel.owned(by: user, on: req.db).sort(\.$createdAt, .descending).all()
    }

    @Sendable func createScenario(req: Request) async throws -> ScenarioDefinitionModel {
        let user = try await authorize(req); return try await persistScenario(req, user: user, existing: nil)
    }

    @Sendable func getScenario(req: Request) async throws -> ScenarioDefinitionModel {
        let user = try await authorize(req); return try await ownedScenario(req, user: user)
    }

    @Sendable func updateScenario(req: Request) async throws -> ScenarioDefinitionModel {
        let user = try await authorize(req); return try await persistScenario(req, user: user, existing: ownedScenario(req, user: user))
    }

    @Sendable func deleteScenario(req: Request) async throws -> HTTPStatus {
        let user = try await authorize(req); try await ownedScenario(req, user: user).delete(on: req.db); return .noContent
    }

    @Sendable func listSnapshots(req: Request) async throws -> [ScenarioSnapshotModel] {
        let user = try await authorize(req); return try await ScenarioSnapshotModel.owned(by: user, on: req.db).sort(\.$createdAt, .descending).all()
    }

    @Sendable func createSnapshot(req: Request) async throws -> ScenarioSnapshotModel {
        let user = try await authorize(req); let input = try req.content.decode(SnapshotInput.self); try await requirePortfolio(input.portfolioListId, user: user, db: req.db)
        let baseCurrency = input.baseCurrency.uppercased()
        guard baseCurrency.count == 3 else { throw Abort(.badRequest, reason: "Invalid base currency") }
        let snapshot: ScenarioSnapshotModel = if let payload = input.payload {
            ScenarioSnapshotModel(userId: user, portfolioListId: input.portfolioListId, baseCurrency: baseCurrency, valuationTimestamp: input.valuationTimestamp ?? Date(), payload: payload, warnings: input.warnings ?? ScenarioJSON())
        } else {
            try await ScenarioSnapshotCaptureService().capture(
                portfolioListId: input.portfolioListId,
                userId: user,
                baseCurrency: baseCurrency,
                cryptoHoldingIds: input.cryptoHoldingIds ?? [],
                req: req
            )
        }
        try await snapshot.save(on: req.db); return snapshot
    }

    @Sendable func getSnapshot(req: Request) async throws -> ScenarioSnapshotModel {
        let user = try await authorize(req); return try await ownedSnapshot(req, user: user)
    }

    @Sendable func listRuns(req: Request) async throws -> [ScenarioRunModel] {
        let user = try await authorize(req); return try await ScenarioRunModel.owned(by: user, on: req.db).sort(\.$createdAt, .descending).all()
    }

    @Sendable func createRun(req: Request) async throws -> Response {
        let user = try await authorize(req); let scenario = try await ownedScenario(req, user: user); let input = try req.content.decode(RunInput.self)
        guard let scenarioId = scenario.id else { throw Abort(.internalServerError) }
        guard let snapshot = try await ScenarioSnapshotModel.owned(by: user, on: req.db).filter(\.$id == input.snapshotId).first() else { throw Abort(.notFound) }
        guard let snapshotId = snapshot.id else { throw Abort(.internalServerError) }
        let seed = input.seed ?? UInt64.random(in: .min ... .max)
        let hashSource = "\(scenarioId)|\(snapshotId)|\(seed)|\(scenario.configuration.values)|\(ScenarioCatalog.version)|\(ScenarioEngine.version)"
        let hash = SHA256.hash(data: Data(hashSource.utf8)).map { String(format: "%02x", $0) }.joined()
        if let existing = try await ScenarioRunModel.owned(by: user, on: req.db).filter(\.$deduplicationHash == hash).filter(\.$state == "completed").first() {
            return try existing.encodeResponse(status: HTTPResponseStatus.ok)
        }
        let expiry = scenario.isSaved ? nil : Date().addingTimeInterval(90 * 86400)
        let run = ScenarioRunModel(userId: user, scenarioId: scenarioId, snapshotId: snapshotId, seed: seed, deduplicationHash: hash, expiresAt: expiry)
        try await run.save(on: req.db); return try run.encodeResponse(status: HTTPResponseStatus.accepted)
    }

    @Sendable func getRun(req: Request) async throws -> ScenarioRunModel {
        let user = try await authorize(req); return try await ownedRun(req, user: user)
    }

    @Sendable func cancelRun(req: Request) async throws -> HTTPStatus {
        let user = try await authorize(req); let run = try await ownedRun(req, user: user); guard run.state == "queued" || run.state == "running" else { throw Abort(.conflict, reason: "Run is already terminal") }; run.state = "cancelled"; run.completedAt = Date(); try await run.save(on: req.db); return .noContent
    }

    @Sendable func getResult(req: Request) async throws -> ScenarioJSON {
        let user = try await authorize(req); let run = try await ownedRun(req, user: user)
        guard run.state == "completed", let runID = run.id else { throw Abort(.conflict, reason: "Result is not ready") }
        if req.application.redis.configuration != nil {
            let key = RedisKey("scenario:result:\(runID.uuidString.lowercased())")
            if let value = try? await req.redis.get(key, as: String.self).get(),
               let data = value.data(using: .utf8), let cached = try? JSONDecoder().decode(ScenarioJSON.self, from: data)
            {
                PrometheusMetrics.shared.recordScenarioCacheHit(); return cached
            }
        }
        guard let result = run.result else { throw Abort(.conflict, reason: "Result is not ready") }
        return result
    }

    @Sendable func compareRuns(req: Request) async throws -> ComparisonResponse {
        let user = try await authorize(req); let input = try req.content.decode(CompareInput.self); guard (1 ... 4).contains(input.runIds.count) else { throw Abort(.badRequest, reason: "Compare between one and four runs") }; let runs = try await ScenarioRunModel.owned(by: user, on: req.db).filter(\.$id ~~ input.runIds).all(); guard runs.count == Set(input.runIds).count else { throw Abort(.notFound) }; return ComparisonResponse(runs: runs)
    }

    @Sendable func listRiskProfiles(req: Request) async throws -> [HoldingRiskProfileModel] {
        let user = try await authorize(req)
        return try await HoldingRiskProfileModel.owned(by: user, on: req.db).sort(\.$updatedAt, .descending).all()
    }

    @Sendable func saveRiskProfile(req: Request) async throws -> HoldingRiskProfileModel {
        let user = try await authorize(req); let input = try req.content.decode(RiskProfileInput.self)
        guard let holding = try await Stock.query(on: req.db).filter(\.$id == input.holdingId).filter(\.$userId == user).first() else { throw Abort(.notFound) }
        let supported = Set(["stock", "etf", "mutual_fund", "crypto", "cash", "bond", "real_estate", "commodity"])
        guard supported.contains(input.assetCategory), input.manualValue.map({ $0 > 0 }) ?? true,
              input.duration.map({ $0 >= 0 }) ?? true, input.convexity.map({ $0 >= 0 }) ?? true
        else { throw Abort(.badRequest, reason: "Invalid risk profile") }
        let profile = try await HoldingRiskProfileModel.owned(by: user, on: req.db)
            .filter(\.$holdingId == input.holdingId).first()
            ?? HoldingRiskProfileModel(userId: user, holdingId: input.holdingId, assetCategory: holding.category.rawValue)
        profile.assetCategory = input.assetCategory; profile.sector = input.sector?.nilIfBlank
        profile.region = input.region?.nilIfBlank; profile.benchmarkProxy = input.benchmarkProxy?.nilIfBlank?.uppercased()
        profile.manualValue = input.manualValue; profile.duration = input.duration; profile.convexity = input.convexity
        profile.factorOverrides = input.factorOverrides ?? ScenarioJSON(); try await profile.save(on: req.db); return profile
    }

    @Sendable func deleteRiskProfile(req: Request) async throws -> HTTPStatus {
        let user = try await authorize(req); let id = try requireID(req)
        guard let profile = try await HoldingRiskProfileModel.owned(by: user, on: req.db).filter(\.$id == id).first() else { throw Abort(.notFound) }
        try await profile.delete(on: req.db); return .noContent
    }

    private func authorize(_ req: Request) async throws -> UUID {
        guard envBool("SCENARIO_PLANNING_ENABLED", default: false) else { throw Abort(.notFound) }; let session = try req.auth.require(SessionToken.self); try await req.usageCounterService.requirePremium(.scenarioPlanning, userId: session.userId, on: req.db); return session.userId
    }

    private func requireID(_ req: Request) throws -> UUID {
        guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw) else { throw Abort(.badRequest, reason: "Invalid id") }; return id
    }

    private func requirePortfolio(_ id: UUID, user: UUID, db: any Database) async throws {
        guard try await PortfolioList.query(on: db).filter(\.$id == id).filter(\.$userId == user).first() != nil else { throw Abort(.notFound) }
    }

    private func ownedGoal(_ req: Request, user: UUID) async throws -> FinancialGoalModel {
        guard let value = try await FinancialGoalModel.owned(by: user, on: req.db).filter(\.$id == requireID(req)).first() else { throw Abort(.notFound) }; return value
    }

    private func ownedScenario(_ req: Request, user: UUID) async throws -> ScenarioDefinitionModel {
        guard let value = try await ScenarioDefinitionModel.owned(by: user, on: req.db).filter(\.$id == requireID(req)).first() else { throw Abort(.notFound) }; return value
    }

    private func ownedSnapshot(_ req: Request, user: UUID) async throws -> ScenarioSnapshotModel {
        guard let value = try await ScenarioSnapshotModel.owned(by: user, on: req.db).filter(\.$id == requireID(req)).first() else { throw Abort(.notFound) }; return value
    }

    private func ownedRun(_ req: Request, user: UUID) async throws -> ScenarioRunModel {
        guard let value = try await ScenarioRunModel.owned(by: user, on: req.db).filter(\.$id == requireID(req)).first() else { throw Abort(.notFound) }; return value
    }

    private func persistScenario(_ req: Request, user: UUID, existing: ScenarioDefinitionModel?) async throws -> ScenarioDefinitionModel {
        let input = try req.content.decode(ScenarioInput.self); guard ["historical", "custom", "monte_carlo"].contains(input.kind) else { throw Abort(.badRequest, reason: "Invalid scenario kind") }; try await requirePortfolio(input.portfolioListId, user: user, db: req.db); if let goalId = input.financialGoalId, try await FinancialGoalModel.owned(by: user, on: req.db).filter(\.$id == goalId).first() == nil {
            throw Abort(.notFound, reason: "Financial goal not found")
        }; let scenario = existing ?? ScenarioDefinitionModel(userId: user, portfolioListId: input.portfolioListId, financialGoalId: input.financialGoalId, name: input.name, kind: input.kind, configuration: input.configuration, isSaved: input.isSaved ?? true); scenario.portfolioListId = input.portfolioListId; scenario.financialGoalId = input.financialGoalId; scenario.name = input.name; scenario.kind = input.kind; scenario.configuration = input.configuration; scenario.isSaved = input.isSaved ?? true; try await scenario.save(on: req.db); return scenario
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value
    }
}

private extension Model where Self: Content {
    func encodeResponse(status: HTTPResponseStatus) throws -> Response {
        let response = Response(status: status); try response.content.encode(self); return response
    }
}
