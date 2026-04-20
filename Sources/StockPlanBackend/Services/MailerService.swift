import Vapor
import Foundation

struct MailMessage: Sendable {
    let to: String
    let subject: String
    let body: String
}

protocol MailerService: Sendable {
    func send(_ message: MailMessage, on req: Request) async throws
}

struct ConsoleMailerService: MailerService {
    func send(_ message: MailMessage, on req: Request) async throws {
        req.logger.info("[mailer] to=\(message.to) subject=\(message.subject) body=\(message.body)")
    }
}

struct ResendMailerService: MailerService {
    let apiKey: String
    let fromEmail: String
    let baseURL: URL

    init(
        apiKey: String,
        fromEmail: String,
        baseURL: URL = URL(string: "https://api.resend.com")!
    ) {
        self.apiKey = apiKey
        self.fromEmail = fromEmail
        self.baseURL = baseURL
    }

    func send(_ message: MailMessage, on req: Request) async throws {
        let uri = URI(string: baseURL.appendingPathComponent("emails").absoluteString)
        let payload = ResendEmailPayload(
            from: fromEmail,
            to: [message.to],
            subject: message.subject,
            text: message.body
        )

        let response = try await req.client.post(uri) { clientReq in
            clientReq.headers.contentType = .json
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            try clientReq.content.encode(payload)
        }

        guard (200..<300).contains(response.status.code) else {
            let body = response.body.map { String(buffer: $0) } ?? "<empty>"
            req.logger.error(
                "resend.mail failed status=\(response.status.code) body=\(body)"
            )
            throw Abort(.serviceUnavailable, reason: "Unable to send email right now.")
        }
    }
}

private struct ResendEmailPayload: Content {
    let from: String
    let to: [String]
    let subject: String
    let text: String
}

extension Application {
    private struct MailerServiceKey: StorageKey {
        typealias Value = any MailerService
    }

    var mailer: any MailerService {
        get {
            guard let service = storage[MailerServiceKey.self] else {
                fatalError("MailerService not configured")
            }
            return service
        }
        set {
            storage[MailerServiceKey.self] = newValue
        }
    }
}
