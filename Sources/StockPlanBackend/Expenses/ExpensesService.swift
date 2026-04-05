import Vapor
import Fluent
import StockPlanShared
import Foundation

protocol ExpensesService: Sendable {
    // Snapshots
    func getSnapshots(userId: UUID, year: Int?, month: Int?, on db: any Database) async throws -> [BudgetSnapshotResponse]
    func createSnapshot(userId: UUID, request: BudgetSnapshotRequest, on db: any Database) async throws -> BudgetSnapshotResponse
    func updateSnapshot(userId: UUID, snapshotId: UUID, request: BudgetSnapshotRequest, on db: any Database) async throws -> BudgetSnapshotResponse
    func deleteSnapshot(userId: UUID, snapshotId: UUID, on db: any Database) async throws
    
    // Plan Items
    func getAllPlanItems(userId: UUID, on db: any Database) async throws -> [BudgetPlanItemResponse]
    func getPlanItems(userId: UUID, snapshotId: UUID, on db: any Database) async throws -> [BudgetPlanItemResponse]
    func createPlanItem(userId: UUID, request: BudgetPlanItemRequest, on db: any Database) async throws -> BudgetPlanItemResponse
    func updatePlanItem(userId: UUID, itemId: UUID, request: BudgetPlanItemRequest, on db: any Database) async throws -> BudgetPlanItemResponse
    func deletePlanItem(userId: UUID, itemId: UUID, on db: any Database) async throws
    
    // Expenses
    func getExpenses(userId: UUID, from: Date?, to: Date?, on db: any Database) async throws -> [ExpenseResponse]
    func createExpense(userId: UUID, request: ExpenseRequest, on db: any Database) async throws -> ExpenseResponse
    func updateExpense(userId: UUID, expenseId: UUID, request: ExpenseRequest, on db: any Database) async throws -> ExpenseResponse
    func deleteExpense(userId: UUID, expenseId: UUID, on db: any Database) async throws
    
    // Reports
    func getMonthlyReports(userId: UUID, from: Date?, to: Date?, on db: any Database) async throws -> [BudgetMonthSummaryResponse]
    func getYearlyReports(userId: UUID, from: Date?, to: Date?, on db: any Database) async throws -> [BudgetYearSummaryResponse]
}

final class DefaultExpensesService: ExpensesService {
    
    // MARK: - Formatters
    
    private func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: string)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
    
    private func formatISODate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    
    // MARK: - Snapshots
    
    func getSnapshots(userId: UUID, year: Int?, month: Int?, on db: any Database) async throws -> [BudgetSnapshotResponse] {
        let query = BudgetSnapshot.query(on: db).filter(\.$user.$id == userId)
        
        // Load items along with snapshot if needed, but the endpoint might just be snapshots.
        // Let's just return snapshots for now. We can load them if requested, but DTO doesn't include items.
        let snapshots = try await query.all()
        
        // Client filtering by year/month if provided (since monthStart is a Date, easier to filter in Swift or via Postgres extract)
        // Filtering in Swift for simplicity unless data is huge
        var filtered = snapshots
        if let year = year {
            filtered = filtered.filter { Calendar.current.component(.year, from: $0.monthStart) == year }
        }
        if let month = month {
            filtered = filtered.filter { Calendar.current.component(.month, from: $0.monthStart) == month }
        }
        
        return filtered.map { mapSnapshot($0) }.sorted { $0.monthStart < $1.monthStart }
    }
    
    func createSnapshot(userId: UUID, request: BudgetSnapshotRequest, on db: any Database) async throws -> BudgetSnapshotResponse {
        guard let monthStart = parseDate(request.monthStart) else {
            throw Abort(.badRequest, reason: "Invalid monthStart format. Expected YYYY-MM-DD.")
        }
        
        let snapshot = BudgetSnapshot(
            userID: userId,
            monthStart: monthStart,
            netSalary: request.netSalary,
            targetShares: request.targetShares
        )
        try await snapshot.create(on: db)
        return mapSnapshot(snapshot)
    }
    
    func updateSnapshot(userId: UUID, snapshotId: UUID, request: BudgetSnapshotRequest, on db: any Database) async throws -> BudgetSnapshotResponse {
        guard let snapshot = try await BudgetSnapshot.find(snapshotId, on: db) else {
            throw Abort(.notFound)
        }
        guard snapshot.$user.id == userId else {
            throw Abort(.forbidden)
        }
        guard let monthStart = parseDate(request.monthStart) else {
            throw Abort(.badRequest, reason: "Invalid monthStart format. Expected YYYY-MM-DD.")
        }
        
        snapshot.monthStart = monthStart
        snapshot.netSalary = request.netSalary
        snapshot.targetShares = request.targetShares
        try await snapshot.update(on: db)
        return mapSnapshot(snapshot)
    }

    func deleteSnapshot(userId: UUID, snapshotId: UUID, on db: any Database) async throws {
        guard let snapshot = try await BudgetSnapshot.find(snapshotId, on: db) else {
            throw Abort(.notFound)
        }
        guard snapshot.$user.id == userId else {
            throw Abort(.forbidden)
        }
        try await snapshot.delete(on: db)
    }
    
    // MARK: - Plan Items
    
    func getAllPlanItems(userId: UUID, on db: any Database) async throws -> [BudgetPlanItemResponse] {
        let items = try await BudgetPlanItem.query(on: db)
            .filter(\.$user.$id == userId)
            .all()
        
        return items.map { mapPlanItem($0) }
    }
    
    func getPlanItems(userId: UUID, snapshotId: UUID, on db: any Database) async throws -> [BudgetPlanItemResponse] {
        let items = try await BudgetPlanItem.query(on: db)
            .filter(\.$user.$id == userId)
            .filter(\.$snapshot.$id == snapshotId)
            .all()
        
        return items.map { mapPlanItem($0) }
    }
    
    func createPlanItem(userId: UUID, request: BudgetPlanItemRequest, on db: any Database) async throws -> BudgetPlanItemResponse {
        guard let snapshotId = UUID(uuidString: request.snapshotId) else {
            throw Abort(.badRequest, reason: "Invalid snapshotId.")
        }
        // Verify snapshot belongs to user
        guard let snapshot = try await BudgetSnapshot.find(snapshotId, on: db), snapshot.$user.id == userId else {
            throw Abort(.notFound, reason: "Snapshot not found.")
        }
        
        let item = BudgetPlanItem(
            snapshotID: snapshotId,
            userID: userId,
            title: request.title,
            plannedAmount: request.plannedAmount,
            pillar: request.pillar
        )
        try await item.create(on: db)
        return mapPlanItem(item)
    }
    
    func updatePlanItem(userId: UUID, itemId: UUID, request: BudgetPlanItemRequest, on db: any Database) async throws -> BudgetPlanItemResponse {
        guard let item = try await BudgetPlanItem.find(itemId, on: db) else {
            throw Abort(.notFound)
        }
        guard item.$user.id == userId else {
            throw Abort(.forbidden)
        }
        
        item.title = request.title
        item.plannedAmount = request.plannedAmount
        item.pillar = request.pillar
        try await item.update(on: db)
        return mapPlanItem(item)
    }
    
    func deletePlanItem(userId: UUID, itemId: UUID, on db: any Database) async throws {
        guard let item = try await BudgetPlanItem.find(itemId, on: db) else {
            throw Abort(.notFound)
        }
        guard item.$user.id == userId else {
            throw Abort(.forbidden)
        }
        try await item.delete(on: db)
    }
    
    // MARK: - Expenses
    
    func getExpenses(userId: UUID, from: Date?, to: Date?, on db: any Database) async throws -> [ExpenseResponse] {
        var query = Expense.query(on: db).filter(\.$user.$id == userId)
        
        if let from = from {
            query = query.filter(\.$occurredOn >= from)
        }
        if let to = to {
            query = query.filter(\.$occurredOn <= to)
        }
        
        let expenses = try await query.sort(\.$occurredOn, .descending).all()
        return expenses.map { mapExpense($0) }
    }
    
    func createExpense(userId: UUID, request: ExpenseRequest, on db: any Database) async throws -> ExpenseResponse {
        guard let occurredOn = parseDate(request.occurredOn) else {
            throw Abort(.badRequest, reason: "Invalid occurredOn format. Expected YYYY-MM-DD.")
        }
        
        var linkedId: UUID? = nil
        if let reqLinkedId = request.linkedPlanItemId, let parsed = UUID(uuidString: reqLinkedId) {
            // Verify plan item belongs to user
            guard let planItem = try await BudgetPlanItem.find(parsed, on: db), planItem.$user.id == userId else {
                throw Abort(.badRequest, reason: "Invalid linkedPlanItemId.")
            }
            linkedId = parsed
        }
        
        let expense = Expense(
            userID: userId,
            title: request.title,
            amount: request.amount,
            pillar: request.pillar,
            occurredOn: occurredOn,
            linkedPlanItemID: linkedId
        )
        try await expense.create(on: db)
        return mapExpense(expense)
    }
    
    func updateExpense(userId: UUID, expenseId: UUID, request: ExpenseRequest, on db: any Database) async throws -> ExpenseResponse {
        guard let expense = try await Expense.find(expenseId, on: db) else {
            throw Abort(.notFound)
        }
        guard expense.$user.id == userId else {
            throw Abort(.forbidden)
        }
        guard let occurredOn = parseDate(request.occurredOn) else {
            throw Abort(.badRequest, reason: "Invalid occurredOn format. Expected YYYY-MM-DD.")
        }
        
        var linkedId: UUID? = nil
        if let reqLinkedId = request.linkedPlanItemId, let parsed = UUID(uuidString: reqLinkedId) {
            guard let planItem = try await BudgetPlanItem.find(parsed, on: db), planItem.$user.id == userId else {
                throw Abort(.badRequest, reason: "Invalid linkedPlanItemId.")
            }
            linkedId = parsed
        }
        
        expense.title = request.title
        expense.amount = request.amount
        expense.pillar = request.pillar
        expense.occurredOn = occurredOn
        expense.$linkedPlanItem.id = linkedId
        try await expense.update(on: db)
        return mapExpense(expense)
    }
    
    func deleteExpense(userId: UUID, expenseId: UUID, on db: any Database) async throws {
        guard let expense = try await Expense.find(expenseId, on: db) else {
            throw Abort(.notFound)
        }
        guard expense.$user.id == userId else {
            throw Abort(.forbidden)
        }
        try await expense.delete(on: db)
    }
    
    // MARK: - Reports
    
    func getMonthlyReports(userId: UUID, from: Date?, to: Date?, on db: any Database) async throws -> [BudgetMonthSummaryResponse] {
        var snapshotsQuery = BudgetSnapshot.query(on: db).filter(\.$user.$id == userId)
        let itemsQuery = BudgetPlanItem.query(on: db).filter(\.$user.$id == userId)
        var expensesQuery = Expense.query(on: db).filter(\.$user.$id == userId)
        
        if let from = from {
            snapshotsQuery = snapshotsQuery.filter(\.$monthStart >= from)
            expensesQuery = expensesQuery.filter(\.$occurredOn >= from)
        }
        if let to = to {
            snapshotsQuery = snapshotsQuery.filter(\.$monthStart <= to)
            expensesQuery = expensesQuery.filter(\.$occurredOn <= to)
        }
        
        let snapshots = try await snapshotsQuery.all()
        let items = try await itemsQuery.all()
        let expenses = try await expensesQuery.all()
        
        let calendar = Calendar(identifier: .gregorian)
        
        // Group items by snapshot
        var itemsBySnapshot: [UUID: [BudgetPlanItem]] = [:]
        for item in items {
            let snapshotId = item.$snapshot.id
            itemsBySnapshot[snapshotId, default: []].append(item)
        }
        
        // Group expenses by month start date
        var expensesByMonth: [Date: [Expense]] = [:]
        for expense in expenses {
            let date = calendar.date(from: calendar.dateComponents([.year, .month], from: expense.occurredOn)) ?? expense.occurredOn
            expensesByMonth[date, default: []].append(expense)
        }
        
        var summaries: [BudgetMonthSummaryResponse] = []
        
        for snapshot in snapshots.sorted(by: { $0.monthStart < $1.monthStart }) {
            let monthStart = snapshot.monthStart
            
            var snapshotItems: [BudgetPlanItem] = []
            if let id = snapshot.id {
                snapshotItems = itemsBySnapshot[id] ?? []
            }
            
            let monthExpenses = expensesByMonth[monthStart] ?? []
            
            var plannedTotal: Double = 0
            for item in snapshotItems { plannedTotal += item.plannedAmount }
            
            var actualTotal: Double = 0
            for expense in monthExpenses { actualTotal += expense.amount }
            
            var pillarPlans: [String: Double] = [:]
            var pillarActuals: [String: Double] = [:]
            
            for pillar in BudgetPillar.allCases {
                let itemsForPillar = snapshotItems.filter { $0.pillar == pillar }
                var plannedAmount: Double = 0
                for item in itemsForPillar { plannedAmount += item.plannedAmount }
                pillarPlans[pillar.rawValue] = plannedAmount
                
                let expensesForPillar = monthExpenses.filter { $0.pillar == pillar }
                var actualAmount: Double = 0
                for expense in expensesForPillar { actualAmount += expense.amount }
                pillarActuals[pillar.rawValue] = actualAmount
            }
            
            let summary = BudgetMonthSummaryResponse(
                monthStart: formatDate(monthStart),
                planned: plannedTotal,
                actual: actualTotal,
                salary: snapshot.netSalary,
                pillarActuals: pillarActuals,
                pillarPlans: pillarPlans
            )
            summaries.append(summary)
        }
        
        return summaries
    }

    func getYearlyReports(userId: UUID, from: Date?, to: Date?, on db: any Database) async throws -> [BudgetYearSummaryResponse] {
        let monthlyReports = try await getMonthlyReports(userId: userId, from: from, to: to, on: db)
        
        let groupedByYear = Dictionary(grouping: monthlyReports) { report in
            guard let date = parseDate(report.monthStart) else { return 0 }
            return Calendar(identifier: .gregorian).component(.year, from: date)
        }
        
        var yearlySummaries: [BudgetYearSummaryResponse] = []
        for (year, reports) in groupedByYear where year != 0 {
            let planned = reports.reduce(0) { $0 + $1.planned }
            let actual = reports.reduce(0) { $0 + $1.actual }
            let salary = reports.reduce(0) { $0 + $1.salary }
            
            yearlySummaries.append(BudgetYearSummaryResponse(
                year: year,
                planned: planned,
                actual: actual,
                salary: salary
            ))
        }
        
        return yearlySummaries.sorted { $0.year < $1.year }
    }

    // MARK: - Mappers
    
    private func mapSnapshot(_ model: BudgetSnapshot) -> BudgetSnapshotResponse {
        BudgetSnapshotResponse(
            id: model.id?.uuidString ?? "",
            monthStart: formatDate(model.monthStart),
            netSalary: model.netSalary,
            targetShares: model.targetShares,
            createdAt: model.createdAt.map { formatISODate($0) },
            updatedAt: model.updatedAt.map { formatISODate($0) }
        )
    }
    
    private func mapPlanItem(_ model: BudgetPlanItem) -> BudgetPlanItemResponse {
        BudgetPlanItemResponse(
            id: model.id?.uuidString ?? "",
            snapshotId: model.$snapshot.id.uuidString,
            title: model.title,
            plannedAmount: model.plannedAmount,
            pillar: model.pillar,
            createdAt: model.createdAt.map { formatISODate($0) },
            updatedAt: model.updatedAt.map { formatISODate($0) }
        )
    }
    
    private func mapExpense(_ model: Expense) -> ExpenseResponse {
        ExpenseResponse(
            id: model.id?.uuidString ?? "",
            title: model.title,
            amount: model.amount,
            pillar: model.pillar,
            occurredOn: formatDate(model.occurredOn),
            linkedPlanItemId: model.$linkedPlanItem.id?.uuidString,
            createdAt: model.createdAt.map { formatISODate($0) },
            updatedAt: model.updatedAt.map { formatISODate($0) }
        )
    }
}
