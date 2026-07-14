import Foundation
import StockPlanShared
import Vapor

extension AIAssistantController {
    /// Streams lifecycle events while the existing turn implementation performs
    /// generation, persistence, and pending-action creation. The JSON chat route
    /// remains available for generated clients and backwards compatibility.
    @Sendable
    func streamChat(req: Request) async throws -> Response {
        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: .contentType, value: "text/event-stream; charset=utf-8")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        response.headers.replaceOrAdd(name: "X-Accel-Buffering", value: "no")
        response.body = .init(managedAsyncStream: { writer in
            try await AIChatController.writeFrame(event: "started", encodedData: "{}", to: writer)
            do {
                let generated = try await chat(req: req)
                let turn = try generated.content.decode(AIAssistantTurnResponse.self)
                let payload = try JSONEncoder().encode(turn)
                let encoded = String(decoding: payload, as: UTF8.self)
                try await AIChatController.writeFrame(event: "turn", encodedData: encoded, to: writer)
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
