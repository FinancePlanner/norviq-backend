import Foundation
import StockPlanShared
import Vapor

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
            title = try container.decode(String.self, forKey: .title)
            amount = try container.decode(Double.self, forKey: .amount)
            pillar = try container.decode(BudgetPillar.self, forKey: .pillar)
            occurredOn =
                try container.decodeIfPresent(String.self, forKey: .occurredOnSnake)
                    ?? container.decode(String.self, forKey: .occurredOnCamel)
            linkedPlanItemId =
                try container.decodeIfPresent(String.self, forKey: .linkedPlanItemIdSnake)
                    ?? container.decodeIfPresent(String.self, forKey: .linkedPlanItemIdCamel)
            categoryId =
                try container.decodeIfPresent(String.self, forKey: .categoryIdSnake)
                    ?? container.decodeIfPresent(String.self, forKey: .categoryIdCamel)
            splitMode =
                try container.decodeIfPresent(ExpenseSplitMode.self, forKey: .splitModeSnake)
                    ?? container.decodeIfPresent(ExpenseSplitMode.self, forKey: .splitModeCamel)
            userSharePercent =
                try container.decodeIfPresent(Double.self, forKey: .userSharePercentSnake)
                    ?? container.decodeIfPresent(Double.self, forKey: .userSharePercentCamel)
            foreignAmount =
                try container.decodeIfPresent(Double.self, forKey: .foreignAmountSnake)
                    ?? container.decodeIfPresent(Double.self, forKey: .foreignAmountCamel)
            foreignCurrency =
                try container.decodeIfPresent(String.self, forKey: .foreignCurrencySnake)
                    ?? container.decodeIfPresent(String.self, forKey: .foreignCurrencyCamel)
            exchangeRate =
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
        // ScopedBearerAuthenticator accepts both first-party JWTs and scoped
        // personal access tokens; scope middleware gates the third-party surface.
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let expenses = protected.grouped("expenses")
        let readScoped = expenses.grouped(ScopeRequirementMiddleware(.expensesRead))
        let writeScoped = expenses.grouped(ScopeRequirementMiddleware(.expensesWrite))
        let firstParty = expenses.grouped(FirstPartyOnlyMiddleware())

        firstParty.group("partner") { partner in
            partner.get(use: getHouseholdPartner)
            partner.put(use: updateHouseholdPartner)
        }

        readScoped.get("categories", use: getCategories)
        writeScoped.post("categories", use: createCategory)
        writeScoped.delete("categories", ":categoryId", use: deleteCategory)

        writeScoped.on(.POST, "import", body: .collect(maxSize: "1mb"), use: importCSV)
        readScoped.get("export.csv", use: exportCSV)

        firstParty.group("recurring") { rec in
            rec.get(use: getRecurringTemplates)
            rec.post(use: createRecurringTemplate)
            rec.group(":templateId") { t in
                t.patch(use: updateRecurringTemplate)
                t.delete(use: deleteRecurringTemplate)
            }
        }

        readScoped.get(use: getExpenses)
        writeScoped.post(use: createExpense)

        writeScoped.group(":expenseId") { expense in
            expense.patch(use: updateExpense)
            expense.delete(use: deleteExpense)
        }
    }

    @Sendable
    func getHouseholdPartner(req: Request) async throws -> HouseholdPartnerProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requireHouseholdPartnerAccess(session: session, req: req)
        return try await req.expensesService.getHouseholdPartner(
            userId: session.userId,
            on: req.db
        )
    }

    @Sendable
    func updateHouseholdPartner(req: Request) async throws -> HouseholdPartnerProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requireHouseholdPartnerAccess(session: session, req: req)
        let payload = try req.content.decode(HouseholdPartnerProfileRequest.self)
        return try await req.expensesService.updateHouseholdPartner(
            userId: session.userId,
            request: payload,
            on: req.db
        )
    }

    @Sendable
    func getExpenses(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        // Core expense read is free — no Pro gate required.
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

        let limit = clampedLimit(req.query[Int.self, at: "limit"])

        // Cursor: ISO8601 string -> Date
        let cursorDate: Date? = {
            guard let cursor = req.query[String.self, at: "cursor"] else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: cursor)
        }()

        let result = try await req.expensesService.getExpenses(
            userId: session.userId,
            from: fromDate,
            to: toDate,
            limit: limit,
            cursor: cursorDate,
            on: req.db
        )

        let response = Response(status: .ok)
        try response.content.encode(result.items)
        if let nextCursor = result.nextCursor {
            response.headers.add(name: "X-Next-Cursor", value: nextCursor)
        }
        return response
    }

    @Sendable
    func createExpense(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        // Core expense creation is free — no Pro gate required.
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
    func importCSV(req: Request) async throws -> ExpenseCsvService.ImportResult {
        let session = try req.auth.require(SessionToken.self)
        guard let buffer = req.body.data else {
            throw Abort(.badRequest, reason: "Missing CSV body.")
        }
        let csv = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        let dryRun = req.query[Bool.self, at: "dry_run"] ?? true

        let categories = try await req.expensesService.getCategories(userId: session.userId, on: req.db)
        let byName = Dictionary(categories.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { first, _ in first })

        let service = ExpenseCsvService(expensesService: req.expensesService)
        return try await service.importCSV(
            csv, userId: session.userId, dryRun: dryRun, categoriesByName: byName, on: req.db
        )
    }

    @Sendable
    func exportCSV(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let fromDate = req.query[String.self, at: "from"].flatMap { formatter.date(from: $0) }
        let toDate = req.query[String.self, at: "to"].flatMap { formatter.date(from: $0) }

        let service = ExpenseCsvService(expensesService: req.expensesService)
        let csv = try await service.exportCSV(userId: session.userId, from: fromDate, to: toDate, on: req.db)

        let res = Response(status: .ok)
        res.headers.replaceOrAdd(name: .contentType, value: "text/csv; charset=utf-8")
        res.headers.replaceOrAdd(name: .contentDisposition, value: "attachment; filename=\"expenses.csv\"")
        res.body = .init(string: csv)
        return res
    }

    @Sendable
    func updateExpense(req: Request) async throws -> ExpenseResponse {
        let session = try req.auth.require(SessionToken.self)
        // Core expense update is free — no Pro gate required.
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
        // Core expense deletion is free — no Pro gate required.
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

    private func clampedLimit(_ rawLimit: Int?, default defaultValue: Int = 50, max maxValue: Int = 200) -> Int {
        max(1, min(rawLimit ?? defaultValue, maxValue))
    }

    // MARK: - Categories

    @Sendable
    func getCategories(req: Request) async throws -> [ExpenseCategoryResponse] {
        let session = try req.auth.require(SessionToken.self)
        // Categories are free — no Pro gate required.
        return try await req.expensesService.getCategories(userId: session.userId, on: req.db)
    }

    @Sendable
    func createCategory(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        // Category creation is free — no Pro gate required.
        let payload = try req.content.decode(ExpenseCategoryRequest.self)
        let created = try await req.expensesService.createCategory(userId: session.userId, request: payload, on: req.db)
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func deleteCategory(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        // Category deletion is free — no Pro gate required.
        let categoryId = try requireUUIDParameter(req, name: "categoryId")
        try await req.expensesService.deleteCategory(userId: session.userId, categoryId: categoryId, on: req.db)
        return .noContent
    }

    // MARK: - Recurring Templates

    @Sendable
    func getRecurringTemplates(req: Request) async throws -> [RecurringTemplateResponse] {
        let session = try req.auth.require(SessionToken.self)
        try await requireRecurringTemplatesAccess(session: session, req: req)
        return try await req.expensesService.getRecurringTemplates(userId: session.userId, on: req.db)
    }

    @Sendable
    func createRecurringTemplate(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        try await requireRecurringTemplatesAccess(session: session, req: req)
        let payload = try req.content.decode(RecurringTemplateRequest.self)
        let created = try await req.expensesService.createRecurringTemplate(userId: session.userId, request: payload, on: req.db)
        let res = Response(status: .created)
        try res.content.encode(created)
        return res
    }

    @Sendable
    func updateRecurringTemplate(req: Request) async throws -> RecurringTemplateResponse {
        let session = try req.auth.require(SessionToken.self)
        try await requireRecurringTemplatesAccess(session: session, req: req)
        let templateId = try requireUUIDParameter(req, name: "templateId")
        let payload = try req.content.decode(RecurringTemplateRequest.self)
        return try await req.expensesService.updateRecurringTemplate(userId: session.userId, templateId: templateId, request: payload, on: req.db)
    }

    @Sendable
    func deleteRecurringTemplate(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        try await requireRecurringTemplatesAccess(session: session, req: req)
        let templateId = try requireUUIDParameter(req, name: "templateId")
        try await req.expensesService.deleteRecurringTemplate(userId: session.userId, templateId: templateId, on: req.db)
        return .noContent
    }

    // MARK: - Access Helpers

    /// Core expense planner (record spend, budget setup, categories, plan items) is free for all users.
    /// No Pro gate is applied here.
    ///
    /// - TODO (Future free-user limits): If you decide to restrict free users later, add quota enforcement here.
    ///   For example:
    ///   - Limit to 3 months of snapshot history (`enforceResourceLimit(.expensePlanner, ...)`).
    ///   - Cap expenses per month (e.g., 50 records).
    ///   - Require Pro for multi-device local storage (though sync is already gated via `ExpensesSyncManager.isPro`).
    ///   File to change: `ExpensesController.swift`, `BudgetController.swift`.
    ///   Backend feature key: `.expensePlanner` (currently `proOnly: false`).
    private func requireHouseholdPartnerAccess(session: SessionToken, req: Request) async throws {
        try await req.usageCounterService.requirePremium(
            .householdPartner,
            userId: session.userId,
            on: req.db
        )
    }

    private func requireRecurringTemplatesAccess(session: SessionToken, req: Request) async throws {
        try await req.usageCounterService.requirePremium(
            .recurringTemplates,
            userId: session.userId,
            on: req.db
        )
    }
}
