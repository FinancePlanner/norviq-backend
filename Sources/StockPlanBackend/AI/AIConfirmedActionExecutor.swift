import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Runs an action the user has already confirmed out of band.
///
/// This used to re-implement five actions by hand, which meant the persistent
/// assistant and Telegram could write expenses and goals and nothing else while
/// MCP grew a full portfolio surface. It is now an adapter: the persisted,
/// status-checked `AIPendingAction` is the proof of consent, so it calls the
/// catalog with ``ActionConfirmationMode/confirmed`` and translates the result.
///
/// It takes a `Request` rather than a `Database` because catalog handlers reach
/// services through `req` and Fluent's `any Database` is not `Sendable`, so a
/// transaction handle cannot be threaded into a `@Sendable` handler under Swift
/// 6. That is why the caller claims, executes, then settles in three steps
/// instead of wrapping the write and its audit row in one transaction — see
/// `AIAssistantTurnCoordinator.confirm`.
struct AIConfirmedActionExecutor {
    struct Result: Sendable {
        let id: UUID?
        let message: String
    }

    func execute(toolName: String, arguments: Data, userId: UUID, on req: Request) async throws -> Result {
        let name = ActionCatalog.canonicalName(for: toolName)
        guard ActionCatalog.contains(name) else {
            throw Abort(.badRequest, reason: "Unsupported assistant action.")
        }

        let json = String(data: arguments, encoding: .utf8) ?? "{}"
        let payload = try await ActionCatalog.execute(
            name: name,
            arguments: ActionArguments(json: json),
            context: AIToolContext(userId: userId),
            mode: .confirmed,
            on: req
        )

        // Catalog handlers swallow AbortError and return {"error": "..."} so a
        // model can read the reason. This path is not a model — it is an HTTP
        // route and a Telegram reply — so turn it back into a thrown Abort,
        // which is what both callers already render as a sentence.
        let object = decodeObject(payload)
        if let message = object["error"] as? String {
            throw Abort(.unprocessableEntity, reason: message)
        }
        if (object["status"] as? String) == "needs_confirmation" {
            // Unreachable under .confirmed; if it ever fires, the mode plumbing
            // regressed and silently dropping the write would be worse.
            throw Abort(.internalServerError, reason: "That action could not be confirmed.")
        }

        return Result(
            id: (object["id"] as? String).flatMap(UUID.init(uuidString:)),
            message: ActionCatalog.completionMessage(name: name)
        )
    }

    private func decodeObject(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}
