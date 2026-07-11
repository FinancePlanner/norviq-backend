import Crypto
import Foundation

/// Opaque (non-JWT) token minting and hashing for third-party credentials.
/// MCP-facing tokens are deliberately never JWTs: a JWT signed with JWT_SECRET
/// would decode as a valid first-party SessionToken and bypass scope checks.
enum OpaqueToken {
    static let patPrefix = "nvq_pat_"
    static let oauthAccessPrefix = "nvq_at_"
    static let oauthRefreshPrefix = "nvq_rt_"

    static func generate(prefix: String, byteCount: Int = 32) -> String {
        let bytes = (0 ..< byteCount).map { _ in UInt8.random(in: 0 ... 255) }
        let body = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return prefix + body
    }

    static func sha256Hex(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
