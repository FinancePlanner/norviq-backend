import Foundation
import NIOCore
import StockPlanShared
import Vapor

struct AdvancedReportGenerator {
    let gotenbergBaseURL: String

    func generate(
        document: ReportDocument,
        format: ReportOutputFormat,
        client: any Client
    ) async throws -> Data {
        switch format {
        case .pdf:
            try await pdf(document: document, client: client)
        case .xlsx:
            SimpleXLSXWriter().makeWorkbook(document)
        }
    }

    /// Exposed so the wire format can be asserted without standing up a fake
    /// HTTP client: Gotenberg rejects a malformed body with a 400 that reads
    /// like an outage.
    static func gotenbergBody(html: String, boundary: String = "norviq-\(UUID().uuidString)") -> MultipartBody {
        var body = MultipartBody(boundary: boundary, reservingCapacity: html.utf8.count + 512)
        body.addFile(
            name: "files",
            filename: "index.html",
            contentType: "text/html; charset=utf-8",
            bytes: Array(html.utf8)
        )
        body.addField(name: "printBackground", value: "true")
        return body
    }

    private func pdf(document: ReportDocument, client: any Client) async throws -> Data {
        let html = ReportHTMLRenderer().render(document)
        let body = Self.gotenbergBody(html: html)

        let endpoint = gotenbergBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/forms/chromium/convert/html"
        let response = try await client.post(URI(string: endpoint)) { request in
            request.headers.replaceOrAdd(name: .contentType, value: body.contentType)
            request.body = body.finalized()
        }
        guard response.status == .ok, var responseBody = response.body else {
            throw Abort(.serviceUnavailable, reason: "PDF renderer is unavailable.")
        }
        return responseBody.readData(length: responseBody.readableBytes) ?? Data()
    }
}
