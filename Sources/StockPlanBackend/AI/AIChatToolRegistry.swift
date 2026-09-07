import Foundation
import StockPlanShared
import Vapor

/// Tools the in-app assistant may call. Mirrors the norviq-mcp tool surface
/// (same names/semantics) but executes services in-process. The userId is bound
/// server-side and is never a model-visible
/// parameter, so cross-user access is not expressible. Write tools require an
/// explicit confirm step for destructive actions.
enum AIChatToolRegistry {
    static func toolDefinitions() -> [OpenAITool] {
        AIReadToolRegistry.toolDefinitions() + ActionCatalog.toolDefinitions()
    }

    /// Executes a tool, returning a JSON string result for the model.
    static func execute(name: String, arguments: String, context: AIToolContext, on req: Request) async throws -> String {
        if AIReadToolRegistry.contains(name) {
            return try await AIReadToolRegistry.execute(
                name: name, arguments: arguments, context: context, on: req
            )
        }
        return try await ActionCatalog.execute(
            name: name, arguments: ActionArguments(json: arguments), context: context, on: req
        )
    }

    // MARK: - Helpers

    private static func tool(_ name: String, _ description: String,
                             _ properties: [String: OpenAIParameter] = [:],
                             required: [String] = []) -> OpenAITool
    {
        OpenAITool(function: OpenAIFunctionDef(
            name: name, description: description,
            parameters: OpenAIJSONSchema(properties: properties, required: required)
        ))
    }

    private static func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return obj
    }

    private static func stringArg(_ args: [String: Any], _ key: String) -> String? {
        (args[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func doubleArg(_ args: [String: Any], _ key: String) -> Double? {
        if let d = args[key] as? Double {
            return d
        }
        if let i = args[key] as? Int {
            return Double(i)
        }
        if let s = args[key] as? String {
            return Double(s)
        }
        return nil
    }

    private static func intArg(_ args: [String: Any], _ key: String) -> Int? {
        if let i = args[key] as? Int {
            return i
        }
        if let d = args[key] as? Double {
            return Int(d)
        }
        if let s = args[key] as? String {
            return Int(s)
        }
        return nil
    }

    private static func boolArg(_ args: [String: Any], _ key: String) -> Bool? {
        if let b = args[key] as? Bool {
            return b
        }
        if let s = args[key] as? String {
            return s == "true"
        }
        return nil
    }

    private static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
