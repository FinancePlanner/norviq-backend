import Fluent
import Foundation

protocol BrokersRepository: Sendable {
    func list(userId: UUID, on db: any Database) async throws -> [BrokerConnection]
    func find(provider: String, userId: UUID, on db: any Database) async throws -> BrokerConnection?
    func upsertCsvImport(provider: String, userId: UUID, on db: any Database) async throws -> BrokerConnection
}

struct DatabaseBrokersRepository: BrokersRepository {
    func list(userId: UUID, on db: any Database) async throws -> [BrokerConnection] {
        try await BrokerConnection.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$updatedAt, .descending)
            .sort(\.$createdAt, .descending)
            .all()
    }

    func find(provider: String, userId: UUID, on db: any Database) async throws -> BrokerConnection? {
        try await BrokerConnection.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$provider == provider)
            .first()
    }

    func upsertCsvImport(provider: String, userId: UUID, on db: any Database) async throws -> BrokerConnection {
        let now = Date()

        if let existing = try await find(provider: provider, userId: userId, on: db) {
            if existing.accessToken == nil, existing.refreshToken == nil, existing.externalId == nil {
                existing.status = "csv"
            }
            existing.updatedAt = now
            try await existing.save(on: db)
            return existing
        }

        let connection = BrokerConnection(userId: userId, provider: provider, status: "csv")
        connection.updatedAt = now
        try await connection.save(on: db)
        return connection
    }
}
