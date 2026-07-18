@preconcurrency import Crypto
import Foundation
import Vapor

enum PlaidWebhookVerificationError: Error, AbortError {
    case notConfigured
    case missingHeader
    case malformedToken
    case unsupportedAlgorithm
    case invalidSignature
    case bodyHashMismatch
    case expired

    var status: HTTPResponseStatus {
        switch self {
        case .notConfigured: .serviceUnavailable
        default: .unauthorized
        }
    }

    var reason: String {
        switch self {
        case .notConfigured: "Plaid webhook verification is not configured."
        case .missingHeader: "Missing Plaid-Verification header."
        case .malformedToken: "Malformed Plaid verification token."
        case .unsupportedAlgorithm: "Unsupported Plaid verification algorithm."
        case .invalidSignature: "Invalid Plaid webhook signature."
        case .bodyHashMismatch: "Plaid webhook body hash mismatch."
        case .expired: "Plaid webhook verification token expired."
        }
    }
}

/// Verifies Plaid webhooks per Plaid's spec: the `Plaid-Verification` header is a
/// JWS (ES256) whose key is fetched from `/webhook_verification_key/get` by `kid`
/// and cached. The token's `request_body_sha256` claim must match the raw body,
/// and `iat` must be recent (replay protection).
struct PlaidWebhookVerifier: Sendable {
    /// Reject tokens older than this (Plaid recommends 5 minutes).
    private let maxAge: TimeInterval = 5 * 60

    private struct JWTHeader: Decodable {
        let alg: String
        let kid: String
    }

    private struct JWTClaims: Decodable {
        let iat: Int
        let requestBodySHA256: String

        enum CodingKeys: String, CodingKey {
            case iat
            case requestBodySHA256 = "request_body_sha256"
        }
    }

    func verify(header token: String, rawBody: Data, client: PlaidClient, cache: PlaidWebhookKeyCache, on req: Request) async throws {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw PlaidWebhookVerificationError.malformedToken }
        let headerB64 = String(parts[0])
        let payloadB64 = String(parts[1])
        let signatureB64 = String(parts[2])

        guard let headerData = Self.base64URLDecode(headerB64),
              let header = try? JSONDecoder().decode(JWTHeader.self, from: headerData)
        else { throw PlaidWebhookVerificationError.malformedToken }
        guard header.alg == "ES256" else { throw PlaidWebhookVerificationError.unsupportedAlgorithm }

        // Resolve the signing key by kid (cached; fetched from Plaid on miss).
        let jwk = try await cache.key(for: header.kid) {
            try await client.getWebhookVerificationKey(keyId: header.kid, on: req)
        }
        let publicKey = try Self.publicKey(from: jwk)

        guard let signature = Self.base64URLDecode(signatureB64),
              let ecdsaSignature = try? P256.Signing.ECDSASignature(rawRepresentation: signature)
        else { throw PlaidWebhookVerificationError.malformedToken }

        let signingInput = Data("\(headerB64).\(payloadB64)".utf8)
        guard publicKey.isValidSignature(ecdsaSignature, for: signingInput) else {
            throw PlaidWebhookVerificationError.invalidSignature
        }

        guard let payloadData = Self.base64URLDecode(payloadB64),
              let claims = try? JSONDecoder().decode(JWTClaims.self, from: payloadData)
        else { throw PlaidWebhookVerificationError.malformedToken }

        // Replay protection.
        let age = Date().timeIntervalSince1970 - Double(claims.iat)
        guard age <= maxAge, age >= -maxAge else { throw PlaidWebhookVerificationError.expired }

        // Bind the token to this exact request body.
        let bodyHash = SHA256.hash(data: rawBody).map { String(format: "%02x", $0) }.joined()
        guard ConstantTime.equals(bodyHash, claims.requestBodySHA256.lowercased()) else {
            throw PlaidWebhookVerificationError.bodyHashMismatch
        }
    }

    private static func publicKey(from jwk: PlaidJWK) throws -> P256.Signing.PublicKey {
        guard jwk.kty == "EC", jwk.crv == "P-256",
              let x = base64URLDecode(jwk.x), let y = base64URLDecode(jwk.y),
              x.count == 32, y.count == 32
        else { throw PlaidWebhookVerificationError.malformedToken }
        // P-256 signing public key raw representation is the 64-byte x||y.
        return try P256.Signing.PublicKey(rawRepresentation: x + y)
    }

    static func base64URLDecode(_ value: String) -> Data? {
        var s = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = (4 - s.count % 4) % 4
        s += String(repeating: "=", count: padding)
        return Data(base64Encoded: s)
    }
}

/// Caches Plaid webhook signing keys by `kid`. A key's material is stable for its
/// `kid`, so entries never need invalidation.
actor PlaidWebhookKeyCache {
    private var keys: [String: PlaidJWK] = [:]

    func key(for kid: String, fetch: () async throws -> PlaidJWK) async throws -> PlaidJWK {
        if let cached = keys[kid] {
            return cached
        }
        let fetched = try await fetch()
        keys[kid] = fetched
        return fetched
    }
}

extension Application {
    private struct PlaidWebhookKeyCacheKey: StorageKey {
        typealias Value = PlaidWebhookKeyCache
    }

    private struct PlaidConfigurationKey: StorageKey {
        typealias Value = PlaidConfiguration
    }

    var plaidWebhookKeyCache: PlaidWebhookKeyCache {
        if let existing = storage[PlaidWebhookKeyCacheKey.self] {
            return existing
        }
        let created = PlaidWebhookKeyCache()
        storage[PlaidWebhookKeyCacheKey.self] = created
        return created
    }

    var plaidConfiguration: PlaidConfiguration? {
        get { storage[PlaidConfigurationKey.self] }
        set { storage[PlaidConfigurationKey.self] = newValue }
    }
}
