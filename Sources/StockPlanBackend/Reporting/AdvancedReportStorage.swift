import Crypto
import Foundation
import Vapor

protocol AdvancedReportStorage: Sendable {
    func store(_ data: Data, artifactId: UUID, format: String) throws -> String
    func load(key: String) throws -> Data
    func delete(key: String) throws
}

struct LocalAdvancedReportStorage: AdvancedReportStorage {
    let rootDirectory: String

    func store(_ data: Data, artifactId: UUID, format: String) throws -> String {
        let directory = URL(fileURLWithPath: rootDirectory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let key = "\(artifactId.uuidString.lowercased()).\(format)"
        let url = directory.appendingPathComponent(key)
        try data.write(to: url, options: .atomic)
        return key
    }

    func load(key: String) throws -> Data {
        guard key.range(of: #"^[a-f0-9-]+\.(pdf|xlsx)$"#, options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "Invalid artifact key.")
        }
        return try Data(contentsOf: URL(fileURLWithPath: rootDirectory).appendingPathComponent(key))
    }

    func delete(key: String) throws {
        let url = URL(fileURLWithPath: rootDirectory).appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

struct ReportDownloadSigner {
    let secret: String

    func signature(artifactId: UUID, expiresAt: Date, recipientUserId: UUID?) -> String {
        let payload = payloadString(
            artifactId: artifactId,
            expiresAt: expiresAt,
            recipientUserId: recipientUserId
        )
        let authentication = HMAC<SHA256>.authenticationCode(
            for: Data(payload.utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )
        return Data(authentication).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func verify(
        signature: String,
        artifactId: UUID,
        expiresAt: Date,
        recipientUserId: UUID?
    ) -> Bool {
        guard expiresAt > Date() else { return false }
        return ConstantTime.equals(
            signature,
            self.signature(
                artifactId: artifactId,
                expiresAt: expiresAt,
                recipientUserId: recipientUserId
            )
        )
    }

    private func payloadString(artifactId: UUID, expiresAt: Date, recipientUserId: UUID?) -> String {
        "\(artifactId.uuidString.lowercased()):\(Int(expiresAt.timeIntervalSince1970)):\(recipientUserId?.uuidString.lowercased() ?? "owner")"
    }
}

extension Application {
    private struct AdvancedReportStorageKey: StorageKey {
        typealias Value = any AdvancedReportStorage
    }

    private struct ReportDownloadSignerKey: StorageKey {
        typealias Value = ReportDownloadSigner
    }

    var advancedReportStorage: any AdvancedReportStorage {
        get {
            guard let value = storage[AdvancedReportStorageKey.self] else {
                fatalError("AdvancedReportStorage not configured")
            }
            return value
        }
        set { storage[AdvancedReportStorageKey.self] = newValue }
    }

    var reportDownloadSigner: ReportDownloadSigner {
        get {
            guard let value = storage[ReportDownloadSignerKey.self] else {
                fatalError("ReportDownloadSigner not configured")
            }
            return value
        }
        set { storage[ReportDownloadSignerKey.self] = newValue }
    }
}
