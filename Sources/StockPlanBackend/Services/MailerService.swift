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
