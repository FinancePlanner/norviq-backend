import Vapor
import Foundation
import StockPlanShared

struct ExpensesController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let expenses = protected.grouped("expenses")
        
        expenses.get(use: getExpenses)
        expenses.post(use: createExpense)
        
        expenses.group(":expenseId") { expense in
            expense.patch(use: updateExpense)
            expense.delete(use: deleteExpense)
        }
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
        
        return try await req.application.expensesService.getExpenses(
            userId: session.userId,
            from: fromDate,
            to: toDate,
            on: req.db
        )
    }

    @Sendable
    func createExpense(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(ExpenseRequest.self)
        
        let created = try await req.application.expensesService.createExpense(
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
        let payload = try req.content.decode(ExpenseRequest.self)
        
        return try await req.application.expensesService.updateExpense(
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
        
        try await req.application.expensesService.deleteExpense(
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
