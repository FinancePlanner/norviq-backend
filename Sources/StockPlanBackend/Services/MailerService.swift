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
        req.logger.info("[mailer] recipient=\(redactedEmail(message.to)) subject=\(message.subject)")
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
            req.logger.error(
                "resend.mail failed status=\(response.status.code) recipient=\(redactedEmail(message.to))"
            )
            throw Abort(.serviceUnavailable, reason: "Unable to send email right now.")
        }
    }
}

private func redactedEmail(_ email: String) -> String {
    let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return "<redacted>" }
    let domain = parts[1].split(separator: ".").last.map(String.init) ?? "domain"
    return "<redacted>@<redacted>.\(domain)"
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
