import Fluent
import Foundation
import StockPlanShared
import Vapor

/// The planning surface: what money becomes, what life costs, and what to do about the gap.
///
/// User-scoped throughout. `RetirementController` remains portfolio-scoped and untouched; a
/// plan about when someone can stop working belongs to the person, not to one of their
/// portfolios.
struct PlanningController: RouteCollection {
    private let service = PlanningService(rules: RetirementRuleRegistry())
    private let prefillService = PlanningPrefillService()

    func boot(routes: any RoutesBuilder) throws {
        let planning = routes
            .grouped("planning")
            .grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())

        let read = planning.grouped(ScopeRequirementMiddleware(.planningRead))
        read.get("prefill", use: prefill)
        read.post("projection", use: projection)
        read.post("retirement", use: retirement)
        read.get("scenarios", use: listScenarios)
        read.get("scenarios", ":scenarioId", use: getScenario)

        let write = planning.grouped(ScopeRequirementMiddleware(.planningWrite))
        write.post("scenarios", use: createScenario)
        write.put("scenarios", ":scenarioId", use: updateScenario)
        write.delete("scenarios", ":scenarioId", use: deleteScenario)
    }

    // MARK: Calculators

    @Sendable
    func prefill(req: Request) async throws -> PlanningPrefill {
        try await prefillService.prefill(userId: user(req), req: req)
    }

    /// Stateless: the Grow screen posts assumptions and gets a projection back. Nothing is
    /// stored unless the user saves a scenario.
    @Sendable
    func projection(req: Request) async throws -> GrowthProjectionResponse {
        _ = try user(req)
        let request = try req.content.decode(GrowthProjectionRequest.self)
        do {
            return try service.projection(request)
        } catch let error as PlanningValidationError {
            throw Self.abort(for: error)
        }
    }

    @Sendable
    func retirement(req: Request) async throws -> RetirementPlanningResponse {
        _ = try user(req)
        let request = try req.content.decode(RetirementPlanningRequest.self)
        do {
            return try await service.retirement(request, req: req)
        } catch let error as PlanningValidationError {
            throw Self.abort(for: error)
        }
    }

    // MARK: Saved scenarios

    @Sendable
    func listScenarios(req: Request) async throws -> [PlanningScenario] {
        let userId = try user(req)
        let records = try await PlanningScenarioRecord.owned(by: userId, on: req.db)
            .sort(\.$createdAt)
            .all()
        return try records.map(scenario(from:))
    }

    @Sendable
    func getScenario(req: Request) async throws -> PlanningScenario {
        try await scenario(from: requireScenario(req))
    }

    @Sendable
    func createScenario(req: Request) async throws -> Response {
        let userId = try user(req)
        let request = try req.content.decode(PlanningScenarioUpsertRequest.self)
        try validate(request)

        let record = try PlanningScenarioRecord(
            userId: userId,
            name: request.name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: request.kind.rawValue,
            isDefault: request.isDefault ?? false,
            inputJson: encode(request.input)
        )

        do {
            try await req.db.transaction { db in
                if record.isDefault {
                    try await Self.clearDefault(userId: userId, kind: request.kind, except: nil, on: db)
                }
                try await record.save(on: db)
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "A scenario with that name already exists.")
        }

        return try await scenario(from: record).encodeResponse(status: .created, for: req)
    }

    @Sendable
    func updateScenario(req: Request) async throws -> PlanningScenario {
        let userId = try user(req)
        let record = try await requireScenario(req)
        let request = try req.content.decode(PlanningScenarioUpsertRequest.self)
        try validate(request)

        record.name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        record.kind = request.kind.rawValue
        record.isDefault = request.isDefault ?? record.isDefault
        record.inputJson = try encode(request.input)

        do {
            try await req.db.transaction { db in
                if record.isDefault {
                    try await Self.clearDefault(userId: userId, kind: request.kind, except: record.id, on: db)
                }
                try await record.save(on: db)
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "A scenario with that name already exists.")
        }

        return try scenario(from: record)
    }

    @Sendable
    func deleteScenario(req: Request) async throws -> HTTPStatus {
        let record = try await requireScenario(req)
        try await record.delete(on: req.db)
        return .noContent
    }

    // MARK: Helpers

    private func user(_ req: Request) throws -> UUID {
        try req.auth.require(SessionToken.self).userId
    }

    private func requireScenario(_ req: Request) async throws -> PlanningScenarioRecord {
        let userId = try user(req)
        guard let raw = req.parameters.get("scenarioId"), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid scenarioId.")
        }
        guard let record = try await PlanningScenarioRecord.owned(by: userId, on: req.db)
            .filter(\.$id == id)
            .first()
        else {
            throw Abort(.notFound, reason: "Scenario not found.")
        }
        return record
    }

    /// Only one scenario per kind can be the default, so promoting one demotes the rest in the
    /// same transaction.
    private static func clearDefault(
        userId: UUID,
        kind: PlanningScenarioKind,
        except id: UUID?,
        on db: any Database
    ) async throws {
        let query = PlanningScenarioRecord.owned(by: userId, on: db)
            .filter(\.$kind == kind.rawValue)
            .filter(\.$isDefault == true)
        if let id {
            query.filter(\.$id != id)
        }
        for other in try await query.all() {
            other.isDefault = false
            try await other.save(on: db)
        }
    }

    private func validate(_ request: PlanningScenarioUpsertRequest) throws {
        do {
            try request.validate()
        } catch let error as PlanningValidationError {
            throw Self.abort(for: error)
        }
    }

    private func scenario(from record: PlanningScenarioRecord) throws -> PlanningScenario {
        guard let kind = PlanningScenarioKind(rawValue: record.kind) else {
            throw Abort(.internalServerError, reason: "Unknown scenario kind.")
        }
        return try PlanningScenario(
            id: record.requireID().uuidString,
            name: record.name,
            kind: kind,
            isDefault: record.isDefault,
            input: decode(record.inputJson),
            createdAt: formatISODateTime(record.createdAt) ?? "",
            updatedAt: formatISODateTime(record.updatedAt)
        )
    }

    private func encode(_ input: PlanningScenarioInput) throws -> String {
        let data = try JSONEncoder.backendAPI.encode(input)
        guard let string = String(data: data, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Failed to encode scenario.")
        }
        return string
    }

    private func decode(_ json: String) throws -> PlanningScenarioInput {
        try JSONDecoder.backendAPI.decode(PlanningScenarioInput.self, from: Data(json.utf8))
    }

    private static func abort(for error: PlanningValidationError) -> Abort {
        switch error {
        case .invalidHorizon:
            Abort(.badRequest, reason: "The number of years must be between 0 and 100.")
        case .invalidReturnRate:
            Abort(.badRequest, reason: "The expected return must be greater than -100%.")
        case .invalidInflationRate:
            Abort(.badRequest, reason: "The inflation rate must be greater than -100%.")
        case .invalidWithdrawalRate:
            Abort(.badRequest, reason: "The withdrawal rate must be between 0% and 20%.")
        case .invalidAges:
            Abort(.badRequest, reason: "Current age, retirement age and longevity must form a valid timeline.")
        case .invalidScenarioName:
            Abort(.badRequest, reason: "A scenario needs a name of 60 characters or fewer.")
        case .missingScenarioInput:
            Abort(.badRequest, reason: "The scenario is missing the inputs for its kind.")
        }
    }
}
