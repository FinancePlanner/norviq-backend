import Foundation
import StockPlanShared
import Vapor

struct BudgetController: RouteCollection {
    private struct BudgetSnapshotPayload: Decodable {
        let monthStart: String
        let netSalary: Double
        let targetShares: [String: Double]

        private enum CodingKeys: String, CodingKey {
            case monthStartSnake = "month_start"
            case monthStartCamel = "monthStart"
            case netSalarySnake = "net_salary"
            case netSalaryCamel = "netSalary"
            case targetSharesSnake = "target_shares"
            case targetSharesCamel = "targetShares"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            monthStart =
                try container.decodeIfPresent(String.self, forKey: .monthStartSnake)
                    ?? container.decode(String.self, forKey: .monthStartCamel)
            netSalary =
                try container.decodeIfPresent(Double.self, forKey: .netSalarySnake)
                    ?? container.decode(Double.self, forKey: .netSalaryCamel)
            targetShares =
                try container.decodeIfPresent([String: Double].self, forKey: .targetSharesSnake)
                    ?? container.decodeIfPresent([String: Double].self, forKey: .targetSharesCamel)
                    ?? [:]
        }

        func asRequest() -> BudgetSnapshotRequest {
            BudgetSnapshotRequest(
                monthStart: monthStart,
                netSalary: netSalary,
                targetShares: targetShares
            )
        }
    }

    private struct BudgetPlanItemPayload: Decodable {
        let snapshotId: String
        let title: String
        let plannedAmount: Double
        let pillar: BudgetPillar
        let splitMode: ExpenseSplitMode?
        let userSharePercent: Double?

        private enum CodingKeys: String, CodingKey {
            case snapshotIdSnake = "snapshot_id"
            case snapshotIdCamel = "snapshotId"
            case title
            case plannedAmountSnake = "planned_amount"
            case plannedAmountCamel = "plannedAmount"
            case pillar
            case splitModeSnake = "split_mode"
            case splitModeCamel = "splitMode"
            case userSharePercentSnake = "user_share_percent"
            case userSharePercentCamel = "userSharePercent"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            snapshotId =
                try container.decodeIfPresent(String.self, forKey: .snapshotIdSnake)
                    ?? container.decode(String.self, forKey: .snapshotIdCamel)
            title = try container.decode(String.self, forKey: .title)
            plannedAmount =
                try container.decodeIfPresent(Double.self, forKey: .plannedAmountSnake)
                    ?? container.decode(Double.self, forKey: .plannedAmountCamel)
            pillar = try container.decode(BudgetPillar.self, forKey: .pillar)
            splitMode =
                try container.decodeIfPresent(ExpenseSplitMode.self, forKey: .splitModeSnake)
                    ?? container.decodeIfPresent(ExpenseSplitMode.self, forKey: .splitModeCamel)
            userSharePercent =
                try container.decodeIfPresent(Double.self, forKey: .userSharePercentSnake)
                    ?? container.decodeIfPresent(Double.self, forKey: .userSharePercentCamel)
        }

        func asRequest() -> BudgetPlanItemRequest {
            BudgetPlanItemRequest(
                snapshotId: snapshotId,
                title: title,
                plannedAmount: plannedAmount,
                pillar: pillar,
                splitMode: splitMode ?? .personal,
                userSharePercent: userSharePercent ?? 100
            )
        }
    }

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let budget = protected.grouped("budget")
        let readable = budget.grouped(ScopeRequirementMiddleware(.expensesRead))
        let writable = budget.grouped(ScopeRequirementMiddleware(.expensesWrite))

        readable.get("snapshots", use: getSnapshots)
        writable.post("snapshots", use: createSnapshot)
        writable.patch("snapshots", ":snapshotId", use: updateSnapshot)
        writable.delete("snapshots", ":snapshotId", use: deleteSnapshot)
        readable.get("snapshots", ":snapshotId", "items", use: getSnapshotItems)
        readable.get("items", use: getAllPlanItems)
        writable.post("items", use: createPlanItem)
        writable.patch("items", ":itemId", use: updatePlanItem)
        writable.delete("items", ":itemId", use: deletePlanItem)
    }

    // MARK: - Snapshots

    @Sendable
    func getSnapshots(req: Request) async throws -> [BudgetSnapshotResponse] {
        let session = try req.auth.require(SessionToken.self)
        // Monthly budget snapshots (salary, pillar targets) are free — no Pro gate required.
        let year = req.query[Int.self, at: "year"]
        let month = req.query[Int.self, at: "month"]

        return try await req.expensesService.getSnapshots(
            userId: session.userId,
            year: year,
            month: month,
            on: req.db
        )
    }

    @Sendable
    func createSnapshot(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        // Monthly budget snapshot creation is free — no Pro gate required.
        let payload = try req.content.decode(BudgetSnapshotPayload.self).asRequest()

        let created = try await req.expensesService.createBudgetSnapshot(
            userId: session.userId,
            request: payload,
            on: req.db
        )
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func updateSnapshot(req: Request) async throws -> BudgetSnapshotResponse {
        let session = try req.auth.require(SessionToken.self)
        // Snapshot update is free — no Pro gate required.
        let snapshotId = try requireUUIDParameter(req, name: "snapshotId")
        let payload = try req.content.decode(BudgetSnapshotPayload.self).asRequest()

        return try await req.expensesService.updateSnapshot(
            userId: session.userId,
            snapshotId: snapshotId,
            request: payload,
            on: req.db
        )
    }

    @Sendable
    func deleteSnapshot(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        // Snapshot deletion is free — no Pro gate required.
        let snapshotId = try requireUUIDParameter(req, name: "snapshotId")

        try await req.expensesService.deleteSnapshot(
            userId: session.userId,
            snapshotId: snapshotId,
            on: req.db
        )
        return .noContent
    }

    // MARK: - Items

    @Sendable
    func getAllPlanItems(req: Request) async throws -> [BudgetPlanItemResponse] {
        let session = try req.auth.require(SessionToken.self)
        // Plan items are free — no Pro gate required.
        return try await req.expensesService.getAllPlanItems(
            userId: session.userId,
            on: req.db
        )
    }

    @Sendable
    func getSnapshotItems(req: Request) async throws -> [BudgetPlanItemResponse] {
        let session = try req.auth.require(SessionToken.self)
        // Plan items are free — no Pro gate required.
        let snapshotId = try requireUUIDParameter(req, name: "snapshotId")

        return try await req.expensesService.getPlanItems(
            userId: session.userId,
            snapshotId: snapshotId,
            on: req.db
        )
    }

    @Sendable
    func createPlanItem(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        // Plan item creation is free — no Pro gate required.
        let payload = try req.content.decode(BudgetPlanItemPayload.self).asRequest()

        let created = try await req.expensesService.createPlanItem(
            userId: session.userId,
            request: payload,
            on: req.db
        )
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func updatePlanItem(req: Request) async throws -> BudgetPlanItemResponse {
        let session = try req.auth.require(SessionToken.self)
        // Plan item update is free — no Pro gate required.
        let itemId = try requireUUIDParameter(req, name: "itemId")
        let payload = try req.content.decode(BudgetPlanItemPayload.self).asRequest()

        return try await req.expensesService.updatePlanItem(
            userId: session.userId,
            itemId: itemId,
            request: payload,
            on: req.db
        )
    }

    @Sendable
    func deletePlanItem(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        // Plan item deletion is free — no Pro gate required.
        let itemId = try requireUUIDParameter(req, name: "itemId")

        try await req.expensesService.deletePlanItem(
            userId: session.userId,
            itemId: itemId,
            on: req.db
        )
        return .noContent
    }

    // MARK: - Helpers

    private func requireUUIDParameter(_ req: Request, name: String) throws -> UUID {
        guard let raw = req.parameters.get(name), let value = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid \(name).")
        }
        return value
    }

    // MARK: - Future Free-User Limits

    //
    // Core budget features (snapshots, plan items) are currently ungated for all authenticated users.
    // If you later decide to restrict free users, add quota enforcement in each endpoint above.
    // For example:
    //   - Limit free users to 1 active snapshot (current month only).
    //   - Cap plan items to a fixed number per snapshot.
    //   - Use `req.usageCounterService.enforceResourceLimit(.expensePlanner, ...)` for count-based limits.
    //   - Or use `req.usageCounterService.requirePremium(.expensePlanner, ...)` to block completely.
    // Backend feature key: `.expensePlanner` (currently `proOnly: false` in BillingContextService).
}
