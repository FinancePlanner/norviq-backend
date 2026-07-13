import Fluent
import Foundation
import StockPlanShared
import Vapor

struct AIConfirmedActionExecutor {
    private struct CreateExpenseArguments: Decodable {
        let title: String
        let amount: Double
        let pillar: String
        let occurredOn: String

        enum CodingKeys: String, CodingKey {
            case title, amount, pillar
            case occurredOn = "occurred_on"
        }
    }

    private struct IdentifiedArguments: Decodable { let id: UUID }
    private struct CreateGoalArguments: Decodable { let title: String }
    private struct UpdateGoalArguments: Decodable { let id: UUID; let title: String }

    struct Result: Sendable {
        let id: UUID?
        let message: String
    }

    func execute(toolName: String, arguments: Data, userId: UUID, on db: any Database) async throws -> Result {
        let decoder = JSONDecoder()
        switch toolName {
        case "create_expense":
            let value = try decoder.decode(CreateExpenseArguments.self, from: arguments)
            guard value.amount > 0, value.amount.isFinite, value.title.count <= 200,
                  let pillar = BudgetPillar(rawValue: value.pillar),
                  let occurredOn = Self.dayFormatter.date(from: value.occurredOn)
            else { throw Abort(.badRequest, reason: "The proposed expense is invalid.") }
            let expense = Expense(userID: userId, title: value.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                  amount: value.amount, pillar: pillar, occurredOn: occurredOn)
            try await expense.create(on: db)
            return try Result(id: expense.requireID(), message: "Expense created.")

        case "delete_expense":
            let value = try decoder.decode(IdentifiedArguments.self, from: arguments)
            guard let expense = try await Expense.query(on: db).filter(\.$id == value.id)
                .filter(\.$user.$id == userId).first()
            else { throw Abort(.notFound, reason: "Expense not found.") }
            try await expense.delete(on: db)
            return Result(id: value.id, message: "Expense deleted.")

        case "create_goal":
            let value = try decoder.decode(CreateGoalArguments.self, from: arguments)
            let title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 200 else { throw Abort(.badRequest, reason: "The proposed goal is invalid.") }
            let goal = try await Goal.create(title: title, userId: userId, on: db)
            return try Result(id: goal.requireID(), message: "Goal created.")

        case "update_goal":
            let value = try decoder.decode(UpdateGoalArguments.self, from: arguments)
            let title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 200,
                  let goal = try await Goal.find(value.id, userId: userId, on: db)
            else { throw Abort(.notFound, reason: "Goal not found.") }
            goal.title = title
            try await goal.save(on: db)
            return Result(id: value.id, message: "Goal updated.")

        case "delete_goal":
            let value = try decoder.decode(IdentifiedArguments.self, from: arguments)
            guard let goal = try await Goal.find(value.id, userId: userId, on: db)
            else { throw Abort(.notFound, reason: "Goal not found.") }
            try await goal.delete(on: db)
            return Result(id: value.id, message: "Goal deleted.")

        default:
            throw Abort(.badRequest, reason: "Unsupported assistant action.")
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
