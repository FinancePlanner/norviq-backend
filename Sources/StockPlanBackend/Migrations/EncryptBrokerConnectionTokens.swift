import Fluent
import Vapor

/// Backfills encryption for broker connection tokens that were stored in
/// plaintext before `TokenEncryptionService` existed. Already-encrypted values
/// (identified by the storage prefix) are left untouched, so the migration is
/// safe to re-run. Fails loudly when the encryption key is missing in
/// production rather than silently keeping plaintext rows.
struct EncryptBrokerConnectionTokens: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let logger = Logger(label: "migration.encrypt-broker-tokens")
        let rawEnvironment = (
            ProcessInfo.processInfo.environment["VAPOR_ENV"]
                ?? ProcessInfo.processInfo.environment["ENV"]
                ?? ""
        ).lowercased()
        let vault = try TokenEncryptionBootstrap.fromProcessEnvironment(
            logger: logger,
            isProduction: rawEnvironment == "production"
        )

        let connections = try await BrokerConnection.query(on: database).all()
        var migrated = 0
        for connection in connections {
            var changed = false
            if let accessToken = connection.accessToken,
               !accessToken.isEmpty,
               !vault.isEncrypted(accessToken)
            {
                connection.accessToken = try vault.encrypt(accessToken, context: .broker)
                changed = true
            }
            if let refreshToken = connection.refreshToken,
               !refreshToken.isEmpty,
               !vault.isEncrypted(refreshToken)
            {
                connection.refreshToken = try vault.encrypt(refreshToken, context: .broker)
                changed = true
            }
            if changed {
                try await connection.save(on: database)
                migrated += 1
            }
        }
        if migrated > 0 {
            logger.info("Encrypted tokens on \(migrated) broker connection(s).")
        }
    }

    func revert(on database: any Database) async throws {
        _ = database
    }
}
