import Vapor
import Fluent
import Foundation

enum BrokersServiceError: Error {
    case invalidProvider
    case notFound
}

extension BrokersServiceError: AbortError {
    var status: HTTPResponseStatus {
        switch self {
        case .invalidProvider:
            return .badRequest
        case .notFound:
            return .notFound
        }
    }

    var reason: String {
        switch self {
        case .invalidProvider:
            return "Invalid broker provider."
        case .notFound:
            return "Broker not found."
        }
    }
}

protocol BrokersService: Sendable {
    func list(userId: UUID, on db: any Database) async throws -> [BrokerConnectionResponse]
    func get(provider: String, userId: UUID, on db: any Database) async throws -> BrokerConnectionResponse
    func recordCsvImport(provider: String, userId: UUID, on db: any Database) async throws -> BrokerConnectionResponse
}

struct DefaultBrokersService: BrokersService {
    let repo: any BrokersRepository

    func list(userId: UUID, on db: any Database) async throws -> [BrokerConnectionResponse] {
        let connections = try await repo.list(userId: userId, on: db)
        return try connections.map { try BrokerConnectionResponse(from: $0) }
    }

    func get(provider: String, userId: UUID, on db: any Database) async throws -> BrokerConnectionResponse {
        let normalized = try BrokerProvider.normalize(provider)
        guard let connection = try await repo.find(provider: normalized, userId: userId, on: db) else {
            throw BrokersServiceError.notFound
        }
        return try BrokerConnectionResponse(from: connection)
    }

    func recordCsvImport(provider: String, userId: UUID, on db: any Database) async throws -> BrokerConnectionResponse {
        let normalized = try BrokerProvider.normalize(provider)
        let connection = try await repo.upsertCsvImport(provider: normalized, userId: userId, on: db)
        return try BrokerConnectionResponse(from: connection)
    }
}

extension BrokerConnectionResponse {
    init(from model: BrokerConnection) throws {
        guard let id = model.id else {
            throw Abort(.internalServerError, reason: "BrokerConnection id missing")
        }

        self.id = id.uuidString
        self.provider = model.provider
        self.status = model.status
    }
}
