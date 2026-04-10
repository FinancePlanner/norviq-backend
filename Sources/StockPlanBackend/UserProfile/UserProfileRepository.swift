import Fluent
import Foundation
import Crypto
import Vapor

protocol UserProfileRepository: Sendable {
    func find(id: UUID, on db: any Database) async throws -> User?
    func find(email: String, on db: any Database) async throws -> User?
    func find(username: String, on db: any Database) async throws -> User?
    func save(_ user: User, on db: any Database) async throws
    func delete(_ user: User, on db: any Database) async throws
}

struct DatabaseUserProfileRepository: UserProfileRepository {
    private let encryptionService: any UserPIIEncrypting

    init() {
        if let service = try? UserPIIEncryptionBootstrap.fromProcessEnvironment(
                logger: Logger(label: "user-profile.repository.default-encryption"),
                isProduction: false
            ) {
            self.encryptionService = service
        } else {
            self.encryptionService = AESGCMUserPIIEncryptionService(
                activeKeyID: "dev-default",
                activeKey: SymmetricKey(data: Data(repeating: 0x2A, count: 32)),
                previousKeys: [:]
            )
        }
    }

    init(encryptionService: any UserPIIEncrypting) {
        self.encryptionService = encryptionService
    }

    func find(id: UUID, on db: any Database) async throws -> User? {
        guard let user = try await User.find(id, on: db) else {
            return nil
        }
        try user.hydrateProtectedFields(using: encryptionService)
        return user
    }

    func find(email: String, on db: any Database) async throws -> User? {
        guard let user = try await User.query(on: db)
            .filter(\.$email == email)
            .first()
        else {
            return nil
        }
        try user.hydrateProtectedFields(using: encryptionService)
        return user
    }

    func find(username: String, on db: any Database) async throws -> User? {
        guard let user = try await User.query(on: db)
            .filter(\.$username == username)
            .first()
        else {
            return nil
        }
        try user.hydrateProtectedFields(using: encryptionService)
        return user
    }

    func save(_ user: User, on db: any Database) async throws {
        try user.encryptProtectedFields(using: encryptionService)
        try await user.save(on: db)
        try user.hydrateProtectedFields(using: encryptionService)
    }

    func delete(_ user: User, on db: any Database) async throws {
        try await user.delete(on: db)
    }
}
