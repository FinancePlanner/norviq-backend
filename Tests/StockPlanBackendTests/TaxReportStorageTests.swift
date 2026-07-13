import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Tax report storage")
struct TaxReportStorageTests {
    @Test
    func `stores reports atomically under the user namespace`() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalTaxReportStorage(rootDirectory: root.path)
        let userID = UUID()
        let reportID = UUID()
        let content = Data("tax-workpaper".utf8)

        let path = try storage.store(
            data: content,
            userID: userID,
            reportID: reportID,
            format: .pdf
        )

        #expect(path.hasPrefix(root.path))
        #expect(path.contains(userID.uuidString))
        #expect(path.hasSuffix("\(reportID.uuidString).pdf"))
        #expect(storage.exists(at: path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == content)
    }

    @Test
    func `separates users with the same report identifier`() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalTaxReportStorage(rootDirectory: root.path)
        let reportID = UUID()

        let first = try storage.store(
            data: Data("first".utf8),
            userID: UUID(),
            reportID: reportID,
            format: .csv
        )
        let second = try storage.store(
            data: Data("second".utf8),
            userID: UUID(),
            reportID: reportID,
            format: .csv
        )

        #expect(first != second)
        #expect(try Data(contentsOf: URL(fileURLWithPath: first)) == Data("first".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: second)) == Data("second".utf8))
    }

    @Test
    func `deletion is idempotent`() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalTaxReportStorage(rootDirectory: root.path)
        let path = try storage.store(
            data: Data(),
            userID: UUID(),
            reportID: UUID(),
            format: .pdf
        )

        try storage.delete(at: path)
        try storage.delete(at: path)

        #expect(!storage.exists(at: path))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("norviq-tax-report-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
