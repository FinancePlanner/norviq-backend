import Fluent
import Vapor

struct BackfillEncryptedUserProfileFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let logger = Logger(label: "migration.backfill-user-profile-pii")
        let rawEnvironment = (
            ProcessInfo.processInfo.environment["VAPOR_ENV"]
            ?? ProcessInfo.processInfo.environment["ENV"]
            ?? ""
        ).lowercased()
        let encryptionService = try UserPIIEncryptionBootstrap.fromProcessEnvironment(
            logger: logger,
            isProduction: rawEnvironment == "production"
        )

        let users = try await User.query(on: database).all()
        for user in users {
            if user.dateOfBirthEncrypted != nil,
               user.bioEncrypted != nil,
               user.householdPartnerDisplayNameEncrypted != nil {
                continue
            }

            try user.hydrateProtectedFields(using: encryptionService)
            try user.encryptProtectedFields(using: encryptionService)
            try await user.save(on: database)
        }
    }

    func revert(on database: any Database) async throws {
        _ = database
    }
}
