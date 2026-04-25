import Fluent
import Foundation

protocol DataExportService: Sendable {
    func createExportJob(userId: UUID, type: ExportType, format: ExportFormat, filters: ExportFilters?, on db: any Database) async throws -> DataExport
    func getExportStatus(id: UUID, userId: UUID, on db: any Database) async throws -> DataExport?
    func listExports(userId: UUID, limit: Int, offset: Int, on db: any Database) async throws -> [DataExport]
}

struct DefaultDataExportService: DataExportService {
    let repository: any DataExportRepository
    let exporter: ExportService

    func createExportJob(userId: UUID, type: ExportType, format: ExportFormat, filters: ExportFilters?, on db: any Database) async throws -> DataExport {
        return try await exporter.createExportJob(userId: userId, type: type, format: format, filters: filters, on: db)
    }

    func getExportStatus(id: UUID, userId: UUID, on db: any Database) async throws -> DataExport? {
        return try await exporter.getExportStatus(id: id, userId: userId, on: db)
    }

    func listExports(userId: UUID, limit: Int, offset: Int, on db: any Database) async throws -> [DataExport] {
        return try await repository.list(userId: userId, limit: limit, offset: offset, on: db)
    }
}
