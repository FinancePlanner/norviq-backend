import Foundation
import StockPlanShared
import Vapor

protocol TaxReportStorage: Sendable {
    func store(data: Data, userID: UUID, reportID: UUID, format: TaxReportFormat) throws -> String
    func delete(at path: String) throws
    func exists(at path: String) -> Bool
}

struct LocalTaxReportStorage: TaxReportStorage {
    let rootDirectory: String

    func store(data: Data, userID: UUID, reportID: UUID, format: TaxReportFormat) throws -> String {
        let directory = URL(fileURLWithPath: rootDirectory, isDirectory: true)
            .appendingPathComponent(userID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let path = directory
            .appendingPathComponent("\(reportID.uuidString).\(format.rawValue)")
            .path
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return path
    }

    func delete(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
    }

    func exists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

private struct TaxReportStorageKey: StorageKey {
    typealias Value = any TaxReportStorage
}

extension Application {
    var taxReportStorage: any TaxReportStorage {
        get {
            guard let value = storage[TaxReportStorageKey.self] else {
                fatalError("Tax report storage has not been configured")
            }
            return value
        }
        set { storage[TaxReportStorageKey.self] = newValue }
    }
}
