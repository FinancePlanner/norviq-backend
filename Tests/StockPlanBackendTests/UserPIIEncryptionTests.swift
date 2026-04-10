@testable import StockPlanBackend
import Crypto
import Foundation
import Testing

@Suite("User PII Encryption Tests")
struct UserPIIEncryptionTests {
    @Test("AES-GCM envelope roundtrip decrypts original value")
    func roundtrip() throws {
        let service = AESGCMUserPIIEncryptionService(
            activeKeyID: "k1",
            activeKey: SymmetricKey(data: Data(repeating: 0x11, count: 32)),
            previousKeys: [:]
        )

        let payload = try service.encryptString("sensitive-value")
        let decrypted = try service.decryptString(payload)

        #expect(decrypted == "sensitive-value")
    }

    @Test("Encrypting same value twice produces different ciphertext payloads")
    func nonceUniqueness() throws {
        let service = AESGCMUserPIIEncryptionService(
            activeKeyID: "k1",
            activeKey: SymmetricKey(data: Data(repeating: 0x22, count: 32)),
            previousKeys: [:]
        )

        let payloadA = try service.encryptString("repeat-value")
        let payloadB = try service.encryptString("repeat-value")

        #expect(payloadA != payloadB)
    }

    @Test("Decrypting with the wrong key fails")
    func wrongKeyFails() throws {
        let writer = AESGCMUserPIIEncryptionService(
            activeKeyID: "k1",
            activeKey: SymmetricKey(data: Data(repeating: 0x33, count: 32)),
            previousKeys: [:]
        )
        let reader = AESGCMUserPIIEncryptionService(
            activeKeyID: "k2",
            activeKey: SymmetricKey(data: Data(repeating: 0x44, count: 32)),
            previousKeys: [:]
        )

        let payload = try writer.encryptString("cannot-decrypt")

        do {
            _ = try reader.decryptString(payload)
            #expect(Bool(false))
        } catch {
            #expect(Bool(true))
        }
    }

    @Test("Key rotation decrypts payloads written by previous key IDs")
    func keyRotationPath() throws {
        let oldKey = SymmetricKey(data: Data(repeating: 0x55, count: 32))
        let oldService = AESGCMUserPIIEncryptionService(
            activeKeyID: "old",
            activeKey: oldKey,
            previousKeys: [:]
        )
        let rotatedService = AESGCMUserPIIEncryptionService(
            activeKeyID: "new",
            activeKey: SymmetricKey(data: Data(repeating: 0x66, count: 32)),
            previousKeys: ["old": oldKey]
        )

        let payload = try oldService.encryptString("rotated-value")
        let decrypted = try rotatedService.decryptString(payload)

        #expect(decrypted == "rotated-value")
    }
}
