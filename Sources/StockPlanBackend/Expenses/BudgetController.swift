import Vapor
import Foundation
import StockPlanShared

struct BudgetController: RouteCollection {
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
            self.snapshotId =
                try container.decodeIfPresent(String.self, forKey: .snapshotIdSnake)
                ?? container.decode(String.self, forKey: .snapshotIdCamel)
            self.title = try container.decode(String.self, forKey: .title)
            self.plannedAmount =
                try container.decodeIfPresent(Double.self, forKey: .plannedAmountSnake)
                ?? container.decode(Double.self, forKey: .plannedAmountCamel)
            self.pillar = try container.decode(BudgetPillar.self, forKey: .pillar)
            self.splitMode =
                try container.decodeIfPresent(ExpenseSplitMode.self, forKey: .splitModeSnake)
                ?? container.decodeIfPresent(ExpenseSplitMode.self, forKey: .splitModeCamel)
            self.userSharePercent =
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
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let budget = protected.grouped("budget")
        
        let snapshots = budget.grouped("snapshots")
        snapshots.get(use: getSnapshots)
        snapshots.post(use: createSnapshot)
        
        snapshots.group(":snapshotId") { snapshot in
            snapshot.patch(use: updateSnapshot)
            snapshot.delete(use: deleteSnapshot)
            snapshot.get("items", use: getSnapshotItems)
        }
        
        let items = budget.grouped("items")
        items.get(use: getAllPlanItems)
        items.post(use: createPlanItem)
        
        items.group(":itemId") { item in
            item.patch(use: updatePlanItem)
            item.delete(use: deletePlanItem)
        }
    }

    // MARK: - Snapshots

    @Sendable
    func getSnapshots(req: Request) async throws -> [BudgetSnapshotResponse] {
        let session = try req.auth.require(SessionToken.self)
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
        let payload = try req.content.decode(BudgetSnapshotRequest.self)
        
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
        let snapshotId = try requireUUIDParameter(req, name: "snapshotId")
        let payload = try req.content.decode(BudgetSnapshotRequest.self)
        
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
        return try await req.expensesService.getAllPlanItems(
            userId: session.userId,
            on: req.db
        )
    }

    @Sendable
    func getSnapshotItems(req: Request) async throws -> [BudgetPlanItemResponse] {
        let session = try req.auth.require(SessionToken.self)
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
}
