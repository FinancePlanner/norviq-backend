import Fluent
import Foundation
import StockPlanShared
import Vapor
import WebAuthn

struct WebAuthnConfig {
    let relyingPartyID: String
    let relyingPartyName: String
    let allowedOrigins: [String]

    var defaultOrigin: String {
        allowedOrigins.first ?? "http://localhost:6969"
    }

    static func fromEnvironment(logger: Logger) -> WebAuthnConfig? {
        guard let rpID = Environment.get("WEBAUTHN_RP_ID")?.trimmedNonEmpty else {
            return nil
        }
        let rpName = Environment.get("WEBAUTHN_RP_NAME")?.trimmedNonEmpty ?? "Norviq"
        let originsRaw = Environment.get("WEBAUTHN_ORIGINS")?.trimmedNonEmpty
            ?? "http://localhost:6969,http://localhost:7000"
        let origins = originsRaw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !origins.isEmpty else {
            logger.warning("WebAuthn disabled: WEBAUTHN_ORIGINS is empty.")
            return nil
        }
        return WebAuthnConfig(
            relyingPartyID: rpID,
            relyingPartyName: rpName,
            allowedOrigins: origins
        )
    }

    func manager(for origin: String) throws -> WebAuthnManager {
        guard allowedOrigins.contains(origin) else {
            throw Abort(.badRequest, reason: "WebAuthn origin is not allowed.")
        }
        return WebAuthnManager(
            configuration: .init(
                relyingPartyID: relyingPartyID,
                relyingPartyName: relyingPartyName,
                relyingPartyOrigin: origin
            )
        )
    }
}

struct WebAuthnPublicKeyOptionsResponse: Content {
    let publicKey: PublicKeyCredentialRequestOptions
}

protocol WebAuthnServicing: Sendable {
    var config: WebAuthnConfig? { get }

    func beginLogin(on req: Request) async throws -> WebAuthnPublicKeyOptionsResponse
    func finishLogin(on req: Request) async throws -> AuthResponse
}

struct DefaultWebAuthnService: WebAuthnServicing {
    let config: WebAuthnConfig?
    private let authService: any AuthService

    init(config: WebAuthnConfig?, authService: any AuthService) {
        self.config = config
        self.authService = authService
    }

    func beginLogin(on req: Request) async throws -> WebAuthnPublicKeyOptionsResponse {
        guard let config else {
            throw Abort(.serviceUnavailable, reason: "Passkey sign-in is not enabled on the server.")
        }

        let origin = try resolveOrigin(on: req, config: config)
        let manager = try config.manager(for: origin)
        let options = manager.beginAuthentication()

        let expiresAt = Date().addingTimeInterval(5 * 60)
        let challenge = WebAuthnLoginChallenge(
            challenge: Data(options.challenge),
            expiresAt: expiresAt
        )
        try await challenge.save(on: req.db)

        return WebAuthnPublicKeyOptionsResponse(publicKey: options)
    }

    func finishLogin(on req: Request) async throws -> AuthResponse {
        guard let config else {
            throw Abort(.serviceUnavailable, reason: "Passkey sign-in is not enabled on the server.")
        }

        let origin = try resolveOrigin(on: req, config: config)
        let manager = try config.manager(for: origin)
        let credential = try req.content.decode(AuthenticationCredential.self)

        guard let storedCredential = try await WebAuthnCredential.query(on: req.db)
            .filter(\.$credentialID == credential.id.asString())
            .first()
        else {
            throw Abort(.unauthorized, reason: "Unknown passkey.")
        }

        let challengeBytes = try challengeBytes(from: credential.response)
        guard let storedChallenge = try await findValidChallenge(challengeBytes, on: req.db) else {
            throw Abort(.unauthorized, reason: "Passkey challenge expired or invalid.")
        }

        let verified = try manager.finishAuthentication(
            credential: credential,
            expectedChallenge: challengeBytes,
            credentialPublicKey: [UInt8](storedCredential.publicKey),
            credentialCurrentSignCount: storedCredential.signCount,
            requireUserVerification: false
        )

        storedCredential.signCount = verified.newSignCount
        try await storedCredential.save(on: req.db)
        try await storedChallenge.delete(on: req.db)

        guard let user = try await User.find(storedCredential.$user.id, on: req.db) else {
            throw Abort(.unauthorized, reason: "Passkey user not found.")
        }

        return try await authService.authResponse(for: user, on: req)
    }

    private func resolveOrigin(on req: Request, config: WebAuthnConfig) throws -> String {
        if let origin = req.headers.first(name: .origin)?.trimmedNonEmpty, config.allowedOrigins.contains(origin) {
            return origin
        }
        if config.allowedOrigins.count == 1, let only = config.allowedOrigins.first {
            return only
        }
        throw Abort(.badRequest, reason: "Missing or disallowed Origin header for WebAuthn.")
    }

    private func findValidChallenge(_ challenge: [UInt8], on db: any Database) async throws -> WebAuthnLoginChallenge? {
        let data = Data(challenge)
        guard let row = try await WebAuthnLoginChallenge.query(on: db)
            .filter(\.$challenge == data)
            .first()
        else {
            return nil
        }
        guard row.expiresAt > Date() else {
            try await row.delete(on: db)
            return nil
        }
        return row
    }

    private func challengeBytes(from response: AuthenticatorAssertionResponse) throws -> [UInt8] {
        let clientData = try JSONDecoder().decode(WebAuthnClientData.self, from: Data(response.clientDataJSON))
        guard let decoded = URLEncodedBase64(clientData.challenge).urlDecoded.decoded else {
            throw Abort(.badRequest, reason: "Invalid WebAuthn challenge encoding.")
        }
        return [UInt8](decoded)
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct WebAuthnClientData: Decodable {
    let type: String
    let challenge: String
    let origin: String
}

extension Application {
    private struct WebAuthnServiceKey: StorageKey {
        typealias Value = any WebAuthnServicing
    }

    var webAuthnService: any WebAuthnServicing {
        get {
            guard let service = storage[WebAuthnServiceKey.self] else {
                fatalError("WebAuthnService not configured")
            }
            return service
        }
        set {
            storage[WebAuthnServiceKey.self] = newValue
        }
    }
}
