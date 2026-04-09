import Vapor
import Foundation
import StockPlanShared

struct ExpensesController: RouteCollection {
    private struct ExpensePayload: Decodable {
        let title: String
        let amount: Double
        let pillar: BudgetPillar
        let occurredOn: String
        let linkedPlanItemId: String?
        let splitMode: ExpenseSplitMode?
        let userSharePercent: Double?

        private enum CodingKeys: String, CodingKey {
            case title
            case amount
            case pillar
            case occurredOnSnake = "occurred_on"
            case occurredOnCamel = "occurredOn"
            case linkedPlanItemIdSnake = "linked_plan_item_id"
            case linkedPlanItemIdCamel = "linkedPlanItemId"
            case splitModeSnake = "split_mode"
            case splitModeCamel = "splitMode"
            case userSharePercentSnake = "user_share_percent"
            case userSharePercentCamel = "userSharePercent"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.title = try container.decode(String.self, forKey: .title)
            self.amount = try container.decode(Double.self, forKey: .amount)
            self.pillar = try container.decode(BudgetPillar.self, forKey: .pillar)
            self.occurredOn =
                try container.decodeIfPresent(String.self, forKey: .occurredOnSnake)
                ?? container.decode(String.self, forKey: .occurredOnCamel)
            self.linkedPlanItemId =
                try container.decodeIfPresent(String.self, forKey: .linkedPlanItemIdSnake)
                ?? container.decodeIfPresent(String.self, forKey: .linkedPlanItemIdCamel)
            self.splitMode =
                try container.decodeIfPresent(ExpenseSplitMode.self, forKey: .splitModeSnake)
                ?? container.decodeIfPresent(ExpenseSplitMode.self, forKey: .splitModeCamel)
            self.userSharePercent =
                try container.decodeIfPresent(Double.self, forKey: .userSharePercentSnake)
                ?? container.decodeIfPresent(Double.self, forKey: .userSharePercentCamel)
        }

        func asRequest() -> ExpenseRequest {
            ExpenseRequest(
                title: title,
                amount: amount,
                pillar: pillar,
                occurredOn: occurredOn,
                linkedPlanItemId: linkedPlanItemId,
                splitMode: splitMode ?? .personal,
                userSharePercent: userSharePercent ?? 100
            )
        }
    }

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let expenses = protected.grouped("expenses")

        expenses.group("partner") { partner in
            partner.get(use: getHouseholdPartner)
            partner.put(use: updateHouseholdPartner)
        }

        expenses.get(use: getExpenses)
        expenses.post(use: createExpense)

        expenses.group(":expenseId") { expense in
            expense.patch(use: updateExpense)
            expense.delete(use: deleteExpense)
        }
    }

    @Sendable
    func getHouseholdPartner(req: Request) async throws -> HouseholdPartnerProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await req.expensesService.getHouseholdPartner(
            userId: session.userId,
            on: req.db
        )
    }

    @Sendable
    func updateHouseholdPartner(req: Request) async throws -> HouseholdPartnerProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(HouseholdPartnerProfileRequest.self)
        return try await req.expensesService.updateHouseholdPartner(
            userId: session.userId,
            request: payload,
            on: req.db
        )
    }

    @Sendable
    func getExpenses(req: Request) async throws -> [ExpenseResponse] {
        let session = try req.auth.require(SessionToken.self)

        // Optional date filters
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        var fromDate: Date?
        var toDate: Date?

        if let from = req.query[String.self, at: "from"] {
            fromDate = dateFormatter.date(from: from)
        }
        if let to = req.query[String.self, at: "to"] {
            toDate = dateFormatter.date(from: to)
        }

        return try await req.expensesService.getExpenses(
            userId: session.userId,
            from: fromDate,
            to: toDate,
            on: req.db
        )
    }

    @Sendable
    func createExpense(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(ExpensePayload.self).asRequest()

        let created = try await req.expensesService.createExpense(
            userId: session.userId,
            request: payload,
            on: req.db
        )

        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func updateExpense(req: Request) async throws -> ExpenseResponse {
        let session = try req.auth.require(SessionToken.self)
        let expenseId = try requireUUIDParameter(req, name: "expenseId")
        let payload = try req.content.decode(ExpensePayload.self).asRequest()

        return try await req.expensesService.updateExpense(
            userId: session.userId,
            expenseId: expenseId,
            request: payload,
            on: req.db
        )
    }

    @Sendable
    func deleteExpense(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let expenseId = try requireUUIDParameter(req, name: "expenseId")

        try await req.expensesService.deleteExpense(
            userId: session.userId,
            expenseId: expenseId,
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
