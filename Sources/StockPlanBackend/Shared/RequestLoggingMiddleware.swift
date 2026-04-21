import Foundation
import Vapor

struct RequestLoggingMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let requestID = request.headers.first(name: "X-Request-ID") ?? UUID().uuidString
        request.logger[metadataKey: "request_id"] = .string(requestID)
        let start = DispatchTime.now()

        do {
            let response = try await next.respond(to: request)
            response.headers.replaceOrAdd(name: "X-Request-ID", value: requestID)
            log(request: request, response: response, start: start)
            return response
        } catch {
            let status = (error as? any AbortError)?.status ?? .internalServerError
            log(request: request, status: status, start: start, error: error)
            throw error
        }
    }

    private func log(request: Request, response: Response, start: DispatchTime) {
        log(request: request, status: response.status, start: start, error: nil)
    }

    private func log(request: Request, status: HTTPResponseStatus, start: DispatchTime, error: (any Error)?) {
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let latencyMS = Double(elapsed) / 1_000_000
        let userID = request.auth.get(SessionToken.self)?.userId.uuidString
        var logger = request.logger
        logger[metadataKey: "http_method"] = .string(request.method.rawValue)
        logger[metadataKey: "http_path"] = .string(request.url.path)
        logger[metadataKey: "http_status"] = .stringConvertible(status.code)
        let latency = String(format: "%.2f", latencyMS)
        logger[metadataKey: "latency_ms"] = .string(latency)
        if let userID {
            logger[metadataKey: "user_id"] = .string(userID)
        }
        if let traceparent = request.headers.first(name: "traceparent") {
            logger[metadataKey: "traceparent"] = .string(traceparent)
        }

        let message = "http_request"
        if let error {
            logger[metadataKey: "error_type"] = .string(String(reflecting: type(of: error)))
            if let abort = error as? any AbortError {
                logger[metadataKey: "error_status"] = .stringConvertible(abort.status.code)
            }
            logger.error("\(message)")
        } else if status.code >= 500 {
            logger.error("\(message)")
        } else if status.code >= 400 {
            logger.warning("\(message)")
        } else {
            logger.info("\(message)")
        }
    }
}
