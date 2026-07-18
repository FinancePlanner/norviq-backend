import Crypto
import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Plaid Webhook Verifier")
struct PlaidWebhookVerifierTests {
    @Test("base64URL decodes unpadded JWT segments")
    func base64URLDecoding() throws {
        // "{\"alg\":\"ES256\"}" base64url without padding.
        let decoded = try #require(PlaidWebhookVerifier.base64URLDecode("eyJhbGciOiJFUzI1NiJ9"))
        #expect(String(data: decoded, encoding: .utf8) == "{\"alg\":\"ES256\"}")
    }

    @Test("base64URL handles - and _ substitutions")
    func base64URLSubstitution() throws {
        // Bytes 0xFB 0xEF 0xBE encode to "++++"-style chars in std base64 ("++-_").
        let raw = Data([0xFB, 0xEF, 0xBE, 0xFF])
        let std = raw.base64EncodedString()
        let urlSafe = std.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let decoded = try #require(PlaidWebhookVerifier.base64URLDecode(urlSafe))
        #expect(decoded == raw)
    }

    @Test("Rejects an obviously malformed token")
    func rejectsMalformed() {
        #expect(PlaidWebhookVerifier.base64URLDecode("!!!not base64!!!") == nil)
    }
}
