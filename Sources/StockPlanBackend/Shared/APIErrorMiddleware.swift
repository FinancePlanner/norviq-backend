import Vapor

struct APIErrorEnvelope: Content, Equatable {
    let error: Bool
    let code: String
    let reason: String
    let details: [String: String]?
    let requestId: String?

    init(
        code: String,
        reason: String,
        details: [String: String]? = nil,
        requestId: String? = nil
    ) {
        error = true
        self.code = code
        self.reason = reason
        self.details = details
        self.requestId = requestId
    }
}

struct APIErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            let response = makeErrorResponse(for: error, request: request)
            SentryReporter.capture(error: error, request: request, status: response.status)
            return response
        }
    }

    private func makeErrorResponse(for error: any Error, request: Request) -> Response {
        let status = (error as? any AbortError)?.status ?? .internalServerError
        let reason = makeReason(for: error, status: status, environment: request.application.environment)
        let requestId = request.headers.first(name: "X-Request-ID")
            ?? request.logger[metadataKey: "request_id"]?.description

        let envelope = APIErrorEnvelope(
            code: code(for: error, status: status),
            reason: reason,
            requestId: requestId
        )
        let response = Response(status: status)
        response.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        if let requestId, !requestId.isEmpty {
            response.headers.replaceOrAdd(name: "X-Request-ID", value: requestId)
        }

        do {
            try response.content.encode(envelope)
        } catch {
            response.body = .init(string: #"{"error":true,"code":"internal_server_error","reason":"Internal Server Error"}"#)
        }
        return response
    }

    private func makeReason(
        for error: any Error,
        status: HTTPResponseStatus,
        environment: Environment
    ) -> String {
        if let abort = error as? any AbortError {
            return abort.reason
        }

        if status.code >= 500, environment == .production {
            return "Internal Server Error"
        }

        let message = String(describing: error)
        return message.isEmpty ? status.reasonPhrase : message
    }

    private func code(for _: any Error, status: HTTPResponseStatus) -> String {
        switch status.code {
        case 400: "bad_request"
        case 401: "unauthorized"
        case 402: "payment_required"
        case 403: "forbidden"
        case 404: "not_found"
        case 409: "conflict"
        case 422: "unprocessable_entity"
        default:
            status.code >= 500 ? "internal_server_error" : "request_failed"
        }
    }
}
