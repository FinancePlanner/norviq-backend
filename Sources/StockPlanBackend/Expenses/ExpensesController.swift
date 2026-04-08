import Vapor
import Foundation
import StockPlanShared

struct ExpensesController: RouteCollection {
    private struct ExpensePayload: Content {
        let title: String
        let amount: Double
        let pillar: BudgetPillar
        let occurredOn: String
        let linkedPlanItemId: String?
        let splitMode: ExpenseSplitMode?
        let userSharePercent: Double?

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
        
        var fromDate: Date? = nil
        var toDate: Date? = nil
        
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
