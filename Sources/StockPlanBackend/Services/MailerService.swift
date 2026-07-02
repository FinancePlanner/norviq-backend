import Foundation
import Vapor

struct MailMessage {
    let to: String
    let subject: String
    let body: String
    let purpose: String?
    let challengeId: UUID?

    init(
        to: String,
        subject: String,
        body: String,
        purpose: String? = nil,
        challengeId: UUID? = nil
    ) {
        self.to = to
        self.subject = subject
        self.body = body
        self.purpose = purpose
        self.challengeId = challengeId
    }
}

protocol MailerService: Sendable {
    func send(_ message: MailMessage, on req: Request) async throws
}

struct ConsoleMailerService: MailerService {
    func send(_ message: MailMessage, on req: Request) async throws {
        req.logger.info(
            "[mailer] recipient=\(redactedEmail(message.to)) purpose=\(message.purpose ?? "general") challenge_id=\(message.challengeId?.uuidString ?? "none")"
        )
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

        guard (200 ..< 300).contains(response.status.code) else {
            req.logger.error(
                "resend.mail failed status=\(response.status.code) recipient=\(redactedEmail(message.to)) purpose=\(message.purpose ?? "general") challenge_id=\(message.challengeId?.uuidString ?? "none")"
            )
            throw Abort(.serviceUnavailable, reason: "Unable to send email right now.")
        }

        let responseID = (try? response.content.decode(ResendEmailResponse.self).id) ?? "unknown"
        req.logger.info(
            "resend.mail sent id=\(responseID) recipient=\(redactedEmail(message.to)) purpose=\(message.purpose ?? "general") challenge_id=\(message.challengeId?.uuidString ?? "none")"
        )
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

private struct ResendEmailResponse: Decodable {
    let id: String?
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
