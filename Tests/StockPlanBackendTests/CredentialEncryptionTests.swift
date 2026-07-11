import Crypto
import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Credential Encryption Tests")
struct CredentialEncryptionTests {
    private func makeVault(seed: UInt8 = 0x11) -> AESGCMTokenEncryptionService {
        AESGCMTokenEncryptionService(
            engine: AESGCMUserPIIEncryptionService(
                activeKeyID: "k1",
                activeKey: SymmetricKey(data: Data(repeating: seed, count: 32)),
                previousKeys: [:]
            )
        )
    }

    @Test("Encrypt then decrypt returns original token")
    func roundtrip() throws {
        let vault = makeVault()
        let stored = try vault.encrypt("nvq-secret-token", context: .broker)

        #expect(vault.isEncrypted(stored))
        #expect(stored.hasPrefix(AESGCMTokenEncryptionService.storagePrefix))
        #expect(try vault.decrypt(stored, context: .broker) == "nvq-secret-token")
    }

    @Test("Decrypting a token under the wrong context fails")
    func contextBinding() throws {
        let vault = makeVault()
        let stored = try vault.encrypt("bank-access-token", context: .bankPlaid)

        do {
            _ = try vault.decrypt(stored, context: .broker)
            #expect(Bool(false))
        } catch {
            #expect(Bool(true))
        }
    }

    @Test("Legacy plaintext values pass through decrypt unchanged")
    func legacyPlaintextPassthrough() throws {
        let vault = makeVault()
        let legacy = "legacy-plaintext-token"

        #expect(!vault.isEncrypted(legacy))
        #expect(try vault.decrypt(legacy, context: .broker) == legacy)
    }
}
