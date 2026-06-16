import Foundation
import NIOCore
import Vapor

/// Reports server-side errors to Sentry via the legacy store endpoint.
/// No Linux Swift SDK is available; this avoids adding SPM dependencies.
enum SentryReporter {
    private struct ParsedDSN {
        let ingestURL: URL
        let publicKey: String
    }

    static func capture(
        error: any Error,
        request: Request,
        status: HTTPResponseStatus
    ) {
        guard status.code >= 500 else { return }
        guard let dsn = ProcessInfo.processInfo.environment["SENTRY_DSN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !dsn.isEmpty,
            let parsed = parseDSN(dsn)
        else { return }

        let environment = ProcessInfo.processInfo.environment["SENTRY_ENVIRONMENT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? request.application.environment.name

        let requestID = request.headers.first(name: "X-Request-ID")
            ?? request.logger[metadataKey: "request_id"]?.description
        let userID = request.auth.get(SessionToken.self)?.userId.uuidString

        let payload = buildEventPayload(
            error: error,
            request: request,
            status: status,
            environment: environment,
            requestID: requestID,
            userID: userID
        )

        Task.detached(priority: .utility) {
            await send(payload: payload, parsed: parsed, client: request.client, logger: request.logger)
        }
    }

    private static func parseDSN(_ dsn: String) -> ParsedDSN? {
        guard let url = URL(string: dsn),
              let host = url.host,
              url.scheme != nil,
              let user = url.user, !user.isEmpty
        else { return nil }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = url.scheme
        components.host = host
        components.port = url.port
        components.path = "/api/\(path)/store/"
        guard let ingestURL = components.url else { return nil }

        return ParsedDSN(ingestURL: ingestURL, publicKey: user)
    }

    private static func buildEventPayload(
        error: any Error,
        request: Request,
        status: HTTPResponseStatus,
        environment: String,
        requestID: String?,
        userID: String?
    ) -> [String: Any] {
        let eventID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let message = String(describing: error)
        var payload: [String: Any] = [
            "event_id": eventID,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "platform": "other",
            "level": "error",
            "logger": "StockPlanBackend",
            "message": message.isEmpty ? status.reasonPhrase : message,
            "tags": [
                "platform": "backend",
                "environment": environment,
                "http.status_code": String(status.code),
                "http.method": request.method.rawValue,
                "http.route": request.url.path,
            ],
            "extra": [
                "path": request.url.path,
                "query": request.url.query ?? "",
            ],
        ]

        if let requestID, !requestID.isEmpty {
            var tags = payload["tags"] as? [String: String] ?? [:]
            tags["request_id"] = requestID
            payload["tags"] = tags
        }

        if let userID, !userID.isEmpty {
            payload["user"] = ["id": userID]
        }

        payload["exception"] = [
            "values": [[
                "type": String(describing: type(of: error)),
                "value": message,
            ]],
        ]

        if let abort = error as? any AbortError {
            var extra = payload["extra"] as? [String: String] ?? [:]
            extra["abort_reason"] = abort.reason
            payload["extra"] = extra
        }

        return payload
    }

    private static func send(
        payload: [String: Any],
        parsed: ParsedDSN,
        client: any Client,
        logger: Logger
    ) async {
        do {
            let bodyData = try JSONSerialization.data(withJSONObject: payload)
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            headers.add(
                name: "X-Sentry-Auth",
                value: "Sentry sentry_version=7, sentry_client=stockplan-backend/1.0, sentry_key=\(parsed.publicKey)"
            )

            let response = try await client.post(URI(string: parsed.ingestURL.absoluteString)) { req in
                req.headers = headers
                req.body = .init(data: bodyData)
            }

            if response.status.code >= 400 {
                logger.warning("sentry.report_failed", metadata: [
                    "status": .stringConvertible(response.status.code),
                ])
            }
        } catch {
            logger.debug("sentry.report_error", metadata: [
                "error": .string(String(describing: error)),
            ])
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
