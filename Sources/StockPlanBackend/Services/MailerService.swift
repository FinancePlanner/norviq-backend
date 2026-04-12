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
    let session: URLSession

    init(
        apiKey: String,
        fromEmail: String,
        baseURL: URL = URL(string: "https://api.resend.com")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.fromEmail = fromEmail
        self.baseURL = baseURL
        self.session = session
    }

    func send(_ message: MailMessage, on req: Request) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("emails"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let payload = ResendEmailPayload(
            from: fromEmail,
            to: [message.to],
            subject: message.subject,
            text: message.body
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Abort(.serviceUnavailable, reason: "Mailer provider returned an invalid response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<empty>"
            req.logger.error(
                "resend.mail failed status=\(http.statusCode) body=\(body)"
            )
            throw Abort(.serviceUnavailable, reason: "Unable to send email right now.")
        }
    }
}

private struct ResendEmailPayload: Codable {
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
