import Foundation
import StockPlanShared
import Vapor

/// The tool surface every in-process assistant shares: trusted reads plus the
/// action catalog. Mirrors the norviq-mcp tool surface (same names/semantics)
/// but executes services in-process.
///
/// The userId is bound server-side through `AIToolContext` and is never a
/// model-visible parameter, so cross-user access is not expressible.
///
/// `mode` decides how consent to a destructive action is proven — in-call for
/// `/v1/ai/chat`, out of band for the persistent assistant and Telegram. See
/// ``ActionConfirmationMode``. It defaults to `.inline`, which is the
/// pre-existing behaviour, so callers that do not care are unaffected.
enum AIChatToolRegistry {
    static func toolDefinitions(mode: ActionConfirmationMode = .inline) -> [OpenAITool] {
        AIReadToolRegistry.toolDefinitions() + ActionCatalog.toolDefinitions(mode: mode)
    }

    /// Executes a tool, returning a JSON string result for the model.
    static func execute(
        name: String,
        arguments: String,
        context: AIToolContext,
        mode: ActionConfirmationMode = .inline,
        on req: Request
    ) async throws -> String {
        if AIReadToolRegistry.contains(name) {
            return try await AIReadToolRegistry.execute(
                name: name, arguments: arguments, context: context, on: req
            )
        }
        return try await ActionCatalog.execute(
            name: name,
            arguments: ActionArguments(json: arguments),
            context: context,
            mode: mode,
            on: req
        )
    }
}
