import Foundation
import StockPlanShared
import Vapor

extension AIAssistantController {
    /// Streams lifecycle events while the existing turn implementation performs
    /// generation, persistence, and pending-action creation. The JSON chat route
    /// remains available for generated clients and backwards compatibility.
    ///
    /// Frame order: `started`, zero or more `tool`, then `turn` or `error`, then
    /// `done`. A `tool` frame is byte-identical to the one `POST /v1/ai/chat`
    /// sends (`AIChatController.write`): `event: tool` / `data: {"label":"…"}`.
    @Sendable
    func streamChat(req: Request) async throws -> Response {
        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: .contentType, value: "text/event-stream; charset=utf-8")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        response.headers.replaceOrAdd(name: "X-Accel-Buffering", value: "no")
        response.body = .init(managedAsyncStream: { writer in
            try await AIChatController.writeFrame(event: "started", encodedData: "{}", to: writer)
            do {
                let turn = try await turnResponse(req: req, onEvent: { event in
                    // Progress is best effort: a dropped frame must not fail
                    // a turn that is already being persisted.
                    try? await AIChatController.write(event, to: writer)
                })
                let payload = try JSONEncoder().encode(turn)
                let encoded = String(decoding: payload, as: UTF8.self)
                try await AIChatController.writeFrame(event: "turn", encodedData: encoded, to: writer)
            } catch let abort as any AbortError where abort.status == .failedDependency {
                // The user's own provider key failed. The turn always fails
                // before any content is written (this route emits one `turn`
                // frame at the end, not a token stream), so the client can show
                // this cleanly instead of a half-finished answer.
                req.logger.warning("ai_assistant.stream_user_credential_failed")
                try await AIChatController.writeFrame(
                    event: "error",
                    data: ["message": abort.reason, "code": "user_credential_rejected"],
                    to: writer
                )
            } catch let upgrade as BillingUpgradeRequiredError {
                // A /dd memo on a free plan. Say why, instead of the generic
                // failure, so the client can point at the upgrade.
                try await AIChatController.writeFrame(
                    event: "error",
                    data: ["message": upgrade.reason, "code": "upgrade_required"],
                    to: writer
                )
            } catch {
                req.logger.error("ai_assistant.stream_failed error=\(String(reflecting: error).prefix(300))")
                try await AIChatController.writeFrame(
                    event: "error",
                    data: ["message": "The assistant could not complete this turn."],
                    to: writer
                )
            }
            try await AIChatController.writeFrame(event: "done", encodedData: "{}", to: writer)
        })
        return response
    }
}
