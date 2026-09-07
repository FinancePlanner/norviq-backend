import Fluent
import Foundation
import StockPlanShared
import Vapor

extension ActionCatalog {
    /// Manual financial goals.
    ///
    /// These predate the catalog: MCP hand-wrote them and the persistent
    /// assistant hand-wrote its own near-identical copies. Both are now this.
    ///
    /// `list_goals` returns *manual* goals only. `GET /v1/goals` also synthesises
    /// three onboarding goals with hardcoded ids (`00000000-…-0001` through
    /// `-0003`, see `GoalsController.evaluateSystemGoals`). Those are computed
    /// from other data and have no row, so handing them to a model invites it to
    /// try renaming or deleting one — which would 404 at best. Reading the table
    /// directly is what keeps them out.
    static var goalActions: [ActionDefinition] {
        [
            ActionDefinition(
                "list_goals",
                "List the user's manual financial goals and their current status.",
                readOnly: true
            ) { context, _, req in
                let goals = try await Goal.owned(by: context.userId, on: req.db)
                    .sort(\.$createdAt, .descending)
                    .all()
                return try encode(goals.map { $0.toDTO() })
            },

            ActionDefinition(
                "add_goal",
                "Add a financial goal.",
                properties: [
                    "title": OpenAIParameter(type: "string", description: "Short title for the financial goal."),
                ],
                required: ["title"]
            ) { context, args, req in
                guard let title = normalisedGoalTitle(args.string("title")) else {
                    return errorPayload("title is required, and must be 200 characters or fewer")
                }
                let goal = try await Goal.create(title: title, userId: context.userId, on: req.db)
                return try encode(goal.toDTO())
            },

            ActionDefinition(
                "update_goal",
                "Rename an existing financial goal.",
                properties: [
                    "id": OpenAIParameter(type: "string", description: "Id of the goal to update."),
                    "title": OpenAIParameter(type: "string", description: "New goal title."),
                ],
                required: ["id", "title"]
            ) { context, args, req in
                guard let id = args.uuid("id") else { return errorPayload("invalid id") }
                guard let title = normalisedGoalTitle(args.string("title")) else {
                    return errorPayload("title is required, and must be 200 characters or fewer")
                }
                guard let goal = try await Goal.find(id, userId: context.userId, on: req.db) else {
                    return errorPayload("goal not found")
                }
                goal.title = title
                try await goal.save(on: req.db)
                return try encode(goal.toDTO())
            },

            ActionDefinition(
                "delete_goal",
                "Permanently delete a financial goal.",
                properties: ["id": OpenAIParameter(type: "string", description: "Id of the goal to delete.")],
                required: ["id"],
                destructive: true
            ) { context, args, req in
                guard let id = args.uuid("id") else { return errorPayload("invalid id") }
                guard let goal = try await Goal.find(id, userId: context.userId, on: req.db) else {
                    return errorPayload("goal not found")
                }
                try await goal.delete(on: req.db)
                return statusPayload("deleted")
            },
        ]
    }

    /// Trim, then reject empty or overlong. Ported from the hand-written
    /// assistant executor, which was the only place it lived.
    private static func normalisedGoalTitle(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.count <= 200
        else { return nil }
        return trimmed
    }
}
