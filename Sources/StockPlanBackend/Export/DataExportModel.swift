import Fluent
import Foundation
import Vapor

enum ExportType: String, Codable {
    case portfolio
    case transactions
    case watchlist
    case insights
    case all
}

enum ExportFormat: String, Codable {
    case csv
    case json
}

enum ExportStatus: String, Codable {
    case pending
    case ready
    case failed
}

struct ExportFilters: Content {
    var portfolioListId: String? // UUID string
    var dateFrom: String? // ISO8601
    var dateTo: String? // ISO8601
}

final class DataExport: Model, Content, @unchecked Sendable {
    static let schema = "data_exports"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "type")
    var type: String

    @Field(key: "format")
    var format: String

    @Field(key: "filters")
    var filters: [String: String]?

    @Field(key: "status")
    var status: String

    @OptionalField(key: "file_path")
    var filePath: String?

    @OptionalField(key: "file_size_bytes")
    var fileSizeBytes: Int64?

    @OptionalField(key: "expires_at")
    var expiresAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        type: ExportType,
        format: ExportFormat,
        filters: ExportFilters? = nil,
        status: ExportStatus = .pending,
        filePath: String? = nil,
        fileSizeBytes: Int64? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.type = type.rawValue
        self.format = format.rawValue
        self.filters = filters?.toDictionary()
        self.status = status.rawValue
        self.filePath = filePath
        self.fileSizeBytes = fileSizeBytes
        self.expiresAt = expiresAt
    }
}

extension ExportFilters {
    func toDictionary() -> [String: String]? {
        var dict: [String: String] = [:]
        if let portfolioListId {
            dict["portfolioListId"] = portfolioListId
        }
        if let dateFrom {
            dict["dateFrom"] = dateFrom
        }
        if let dateTo {
            dict["dateTo"] = dateTo
        }
        return dict.isEmpty ? nil : dict
    }
}
