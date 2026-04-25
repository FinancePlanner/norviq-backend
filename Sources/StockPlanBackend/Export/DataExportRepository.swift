import Fluent
import Foundation

protocol DataExportRepository: Sendable {
    func create(_ export: DataExport, on db: any Database) async throws -> DataExport
    func update(_ export: DataExport, on db: any Database) async throws -> DataExport
    func find(id: UUID, userId: UUID, on db: any Database) async throws -> DataExport?
    func list(userId: UUID, limit: Int, offset: Int, on db: any Database) async throws -> [DataExport]
    func deleteExpired(before date: Date, on db: any Database) async throws -> Int
}

struct DatabaseDataExportRepository: DataExportRepository {
    func create(_ export: DataExport, on db: any Database) async throws -> DataExport {
        try await export.save(on: db)
        return export
    }

    func update(_ export: DataExport, on db: any Database) async throws -> DataExport {
        try await export.save(on: db)
        return export
    }

    func find(id: UUID, userId: UUID, on db: any Database) async throws -> DataExport? {
        try await DataExport.query(on: db)
            .filter(\.$id == id)
            .filter(\.$userId == userId)
            .first()
    }

    func list(userId: UUID, limit: Int, offset: Int, on db: any Database) async throws -> [DataExport] {
        try await DataExport.query(on: db)
            .filter(\.$userId == userId)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .offset(offset)
            .all()
    }

    func deleteExpired(before date: Date, on db: any Database) async throws -> Int {
        let exports = try await DataExport.query(on: db)
            .filter(\.$status == ExportStatus.ready.rawValue)
            .filter(\.$expiresAt != nil)
            .filter(\.$expiresAt < date)
            .all()
        for export in exports {
            try await export.delete(on: db)
        }
        return exports.count
    }
}
