import Foundation
import StockPlanShared
import Vapor

/// One user-facing action, defined once.
///
/// Norviq exposes the same actions through two very different surfaces: the MCP
/// server (Go, over HTTP, authorised by scoped tokens) and the in-app/Telegram
/// assistant (Swift, in-process, authorised as the signed-in user). Those had
/// entirely separate tool lists, so an action added to one silently did not
/// exist on the other — which is why Telegram could write expenses and nothing
/// else while MCP grew a full portfolio surface.
///
/// A definition carries its schema *and* its handler so the two cannot drift.
/// `GET /v1/actions/catalog` publishes the schemas, so the MCP side can be
/// checked against this list rather than hand-maintained in parallel.
struct ActionDefinition: Sendable {
    let name: String
    let description: String
    let properties: [String: OpenAIParameter]
    let required: [String]
    /// Destructive actions must not fire on a single model turn. The assistant
    /// surfaces these as a confirm step; `confirm` is appended to their schema.
    let destructive: Bool
    let handler: @Sendable (AIToolContext, ActionArguments, Request) async throws -> String

    init(
        _ name: String,
        _ description: String,
        properties: [String: OpenAIParameter] = [:],
        required: [String] = [],
        destructive: Bool = false,
        handler: @escaping @Sendable (AIToolContext, ActionArguments, Request) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.properties = properties
        self.required = required
        self.destructive = destructive
        self.handler = handler
    }
}

enum ActionCatalog {
    /// Every write action, across every domain. Reads stay in AIReadToolRegistry.
    static var all: [ActionDefinition] {
        expenseActions + watchlistActions + transactionActions + positionActions
    }

    static func definition(named name: String) -> ActionDefinition? {
        all.first { $0.name == name }
    }

    static func contains(_ name: String) -> Bool {
        definition(named: name) != nil
    }

    /// Schemas in the shape the model APIs expect. A destructive action gains a
    /// `confirm` flag so refusing to act without it is expressible in the schema
    /// rather than only in prose.
    static func toolDefinitions() -> [OpenAITool] {
        all.map { action in
            var properties = action.properties
            var required = action.required
            if action.destructive {
                properties["confirm"] = OpenAIParameter(
                    type: "boolean",
                    description: "must be true to actually perform this; ask the user first"
                )
                required.append("confirm")
            }
            return OpenAITool(function: OpenAIFunctionDef(
                name: action.name,
                description: action.description,
                parameters: OpenAIJSONSchema(properties: properties, required: required)
            ))
        }
    }

    static func execute(
        name: String,
        arguments: ActionArguments,
        context: AIToolContext,
        on req: Request
    ) async throws -> String {
        guard let action = definition(named: name) else {
            return #"{"error":"unknown tool"}"#
        }
        if action.destructive, arguments.bool("confirm") != true {
            return #"{"status":"needs_confirmation","message":"Ask the user to confirm, then call again with confirm=true."}"#
        }
        do {
            return try await action.handler(context, arguments, req)
        } catch let abort as any AbortError {
            // The model reads this, so surface the reason rather than a stack.
            return errorPayload(abort.reason)
        } catch {
            req.logger.warning("action_failed name=\(name) error=\(error)")
            return errorPayload("That action could not be completed.")
        }
    }

    // MARK: - Shared helpers

    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func errorPayload(_ message: String) -> String {
        (try? encode(["error": message])) ?? #"{"error":"unknown"}"#
    }

    static func statusPayload(_ status: String) -> String {
        (try? encode(["status": status])) ?? #"{"status":"ok"}"#
    }
}
