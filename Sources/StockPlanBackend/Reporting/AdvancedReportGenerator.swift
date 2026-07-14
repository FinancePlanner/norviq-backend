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

    private func pdf(document: ReportDocument, client: any Client) async throws -> Data {
        let html = ReportHTMLRenderer().render(document)
        let boundary = "norviq-\(UUID().uuidString)"
        var body = ByteBufferAllocator().buffer(capacity: html.utf8.count + 512)
        body.writeString("--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"files\"; filename=\"index.html\"\r\n")
        body.writeString("Content-Type: text/html; charset=utf-8\r\n\r\n")
        body.writeString(html)
        body.writeString("\r\n--\(boundary)\r\n")
        body.writeString("Content-Disposition: form-data; name=\"printBackground\"\r\n\r\ntrue\r\n")
        body.writeString("--\(boundary)--\r\n")

        let endpoint = gotenbergBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/forms/chromium/convert/html"
        let response = try await client.post(URI(string: endpoint)) { request in
            request.headers.replaceOrAdd(
                name: .contentType,
                value: "multipart/form-data; boundary=\(boundary)"
            )
            request.body = body
        }
        guard response.status == .ok, var responseBody = response.body else {
            throw Abort(.serviceUnavailable, reason: "PDF renderer is unavailable.")
        }
        return responseBody.readData(length: responseBody.readableBytes) ?? Data()
    }
}
