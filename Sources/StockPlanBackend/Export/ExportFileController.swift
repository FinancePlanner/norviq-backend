import Vapor
import HTTPTypes

struct ExportFileController: RouteCollection {
    let exportService: any DataExportService

    init(exportService: any DataExportService) {
        self.exportService = exportService
    }

    func boot(routes: any RoutesBuilder) throws {
        let exports = routes.grouped("api", "v3", "export")
        exports.get("file", ":userId", ":filename", use: serveExportFile)
    }

    @Sendable
    func serveExportFile(req: Request) async throws -> Response {
        guard let userId = req.parameters.get("userId", as: UUID.self),
              let filename = req.parameters.get("filename") else {
            throw Abort(.badRequest, reason: "Missing parameters")
        }

        let exportIdString = filename.split(separator: ".").first.map(String.init)
        guard let exportIdString = exportIdString, let exportId = UUID(uuidString: exportIdString) else {
            throw Abort(.badRequest, reason: "Invalid filename format")
        }

        guard let export = try await exportService.getExportStatus(id: exportId, userId: userId, on: req.db) else {
            throw Abort(.notFound, reason: "Export not found")
        }

        guard export.status == ExportStatus.ready.rawValue else {
            throw Abort(.badRequest, reason: "Export is not ready for download")
        }

        let filePath = export.filePath ?? ""
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw Abort(.notFound, reason: "File not found")
        }

        let file = try req.fileio.streamFile(at: filePath)

        // Set download headers
        let isCSV = export.format == ExportFormat.csv.rawValue
        file.headers.contentType = isCSV
            ? HTTPMediaType(type: "text", subType: "csv")
            : .json
        file.headers.add(name: "Content-Disposition", value: "attachment; filename=\"\(filename)\"")
        
        return file
    }
}
