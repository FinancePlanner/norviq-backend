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
        let categoryId: String?
        let splitMode: ExpenseSplitMode?
        let userSharePercent: Double?
        let foreignAmount: Double?
        let foreignCurrency: String?
        let exchangeRate: Double?

        private enum CodingKeys: String, CodingKey {
            case title
            case amount
            case pillar
            case occurredOnSnake = "occurred_on"
            case occurredOnCamel = "occurredOn"
            case linkedPlanItemIdSnake = "linked_plan_item_id"
            case linkedPlanItemIdCamel = "linkedPlanItemId"
            case categoryIdSnake = "category_id"
            case categoryIdCamel = "categoryId"
            case splitModeSnake = "split_mode"
            case splitModeCamel = "splitMode"
            case userSharePercentSnake = "user_share_percent"
            case userSharePercentCamel = "userSharePercent"
            case foreignAmountSnake = "foreign_amount"
            case foreignAmountCamel = "foreignAmount"
            case foreignCurrencySnake = "foreign_currency"
            case foreignCurrencyCamel = "foreignCurrency"
            case exchangeRateSnake = "exchange_rate"
            case exchangeRateCamel = "exchangeRate"
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
            self.categoryId =
                try container.decodeIfPresent(String.self, forKey: .categoryIdSnake)
                ?? container.decodeIfPresent(String.self, forKey: .categoryIdCamel)
            self.splitMode =
                try container.decodeIfPresent(ExpenseSplitMode.self, forKey: .splitModeSnake)
                ?? container.decodeIfPresent(ExpenseSplitMode.self, forKey: .splitModeCamel)
            self.userSharePercent =
                try container.decodeIfPresent(Double.self, forKey: .userSharePercentSnake)
                ?? container.decodeIfPresent(Double.self, forKey: .userSharePercentCamel)
            self.foreignAmount =
                try container.decodeIfPresent(Double.self, forKey: .foreignAmountSnake)
                ?? container.decodeIfPresent(Double.self, forKey: .foreignAmountCamel)
            self.foreignCurrency =
                try container.decodeIfPresent(String.self, forKey: .foreignCurrencySnake)
                ?? container.decodeIfPresent(String.self, forKey: .foreignCurrencyCamel)
            self.exchangeRate =
                try container.decodeIfPresent(Double.self, forKey: .exchangeRateSnake)
                ?? container.decodeIfPresent(Double.self, forKey: .exchangeRateCamel)
        }

        func asRequest() -> ExpenseRequest {
            ExpenseRequest(
                title: title,
                amount: amount,
                pillar: pillar,
                occurredOn: occurredOn,
                linkedPlanItemId: linkedPlanItemId,
                categoryId: categoryId,
                splitMode: splitMode ?? .personal,
                userSharePercent: userSharePercent ?? 100,
                foreignAmount: foreignAmount,
                foreignCurrency: foreignCurrency,
                exchangeRate: exchangeRate
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

        expenses.group("categories") { cat in
            cat.get(use: getCategories)
            cat.post(use: createCategory)
            cat.group(":categoryId") { c in
                c.delete(use: deleteCategory)
            }
        }

        expenses.group("recurring") { rec in
            rec.get(use: getRecurringTemplates)
            rec.post(use: createRecurringTemplate)
            rec.group(":templateId") { t in
                t.patch(use: updateRecurringTemplate)
                t.delete(use: deleteRecurringTemplate)
            }
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
        try await requireExpensePlannerAccess(session: session, req: req)
        return try await req.expensesService.getHouseholdPartner(
            userId: session.userId,
            on: req.db
        )
    }

    @Sendable
    func updateHouseholdPartner(req: Request) async throws -> HouseholdPartnerProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requireExpensePlannerAccess(session: session, req: req)
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
        try await requireExpensePlannerAccess(session: session, req: req)

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
            limit: clampedLimit(req.query[Int.self, at: "limit"]),
            on: req.db
        )
    }

    @Sendable
    func createExpense(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        try await requireExpensePlannerAccess(session: session, req: req)
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
        try await requireExpensePlannerAccess(session: session, req: req)
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
        try await requireExpensePlannerAccess(session: session, req: req)
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

    private func clampedLimit(_ rawLimit: Int?, default defaultValue: Int = 100, max maxValue: Int = 100) -> Int {
        max(1, min(rawLimit ?? defaultValue, maxValue))
    }

    // MARK: - Categories

    @Sendable
    func getCategories(req: Request) async throws -> [ExpenseCategoryResponse] {
        let session = try req.auth.require(SessionToken.self)
        try await requireExpensePlannerAccess(session: session, req: req)
        return try await req.expensesService.getCategories(userId: session.userId, on: req.db)
    }

    @Sendable
    func createCategory(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        try await requireExpensePlannerAccess(session: session, req: req)
        let payload = try req.content.decode(ExpenseCategoryRequest.self)
        let created = try await req.expensesService.createCategory(userId: session.userId, request: payload, on: req.db)
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func deleteCategory(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        try await requireExpensePlannerAccess(session: session, req: req)
        let categoryId = try requireUUIDParameter(req, name: "categoryId")
        try await req.expensesService.deleteCategory(userId: session.userId, categoryId: categoryId, on: req.db)
        return .noContent
    }

    // MARK: - Recurring Templates

    @Sendable
    func getRecurringTemplates(req: Request) async throws -> [RecurringTemplateResponse] {
        let session = try req.auth.require(SessionToken.self)
        try await requireExpensePlannerAccess(session: session, req: req)
        return try await req.expensesService.getRecurringTemplates(userId: session.userId, on: req.db)
    }

    @Sendable
    func createRecurringTemplate(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        try await requireExpensePlannerAccess(session: session, req: req)
        let payload = try req.content.decode(RecurringTemplateRequest.self)
        let created = try await req.expensesService.createRecurringTemplate(userId: session.userId, request: payload, on: req.db)
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func updateRecurringTemplate(req: Request) async throws -> RecurringTemplateResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requireExpensePlannerAccess(session: session, req: req)
        let templateId = try requireUUIDParameter(req, name: "templateId")
        let payload = try req.content.decode(RecurringTemplateRequest.self)
        return try await req.expensesService.updateRecurringTemplate(userId: session.userId, templateId: templateId, request: payload, on: req.db)
    }

    @Sendable
    func deleteRecurringTemplate(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        try await requireExpensePlannerAccess(session: session, req: req)
        let templateId = try requireUUIDParameter(req, name: "templateId")
        try await req.expensesService.deleteRecurringTemplate(userId: session.userId, templateId: templateId, on: req.db)
        return .noContent
    }

    private func requireExpensePlannerAccess(session: SessionToken, req: Request) async throws {
        try await req.usageCounterService.requirePremium(
            .expensePlanner,
            userId: session.userId,
            on: req.db
        )
    }
}
