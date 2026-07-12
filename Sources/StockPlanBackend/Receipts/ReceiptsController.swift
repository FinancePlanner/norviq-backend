import Foundation
import StockPlanShared
import Vapor

/// Turns scanned receipts into pre-filled expense drafts.
///
/// - `POST /v1/receipts/parse-qr` parses a decoded fiscal QR string (free;
///   structured, no image leaves the client). Used by web, and by iOS as a
///   canonical cross-check of its on-device parse.
/// - `POST /v1/receipts/ocr` extracts a draft from a receipt photo when no QR is
///   present (Pro-gated; costs a vision/OCR call).
///
/// Both return a `ReceiptDraft` carrying no budget pillar or category — the user
/// assigns those when confirming the expense.
struct ReceiptsController: RouteCollection {
    /// 8 MB cap on uploaded receipt images.
    private let maxImageBytes = 8 * 1024 * 1024

    private let parser = FiscalReceiptQRParser()

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let receipts = protected.grouped("receipts")
        let writeScoped = receipts.grouped(ScopeRequirementMiddleware(.expensesWrite))
        writeScoped.post("parse-qr", use: parseQR)
        writeScoped.post("ocr", use: ocr)
    }

    @Sendable
    func parseQR(req: Request) async throws -> ReceiptDraftResponse {
        _ = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(ReceiptParseQRRequest.self)
        guard let draft = parser.parse(payload.payload) else {
            return ReceiptDraftResponse(recognized: false, draft: nil)
        }
        return ReceiptDraftResponse(recognized: true, draft: draft)
    }

    @Sendable
    func ocr(req: Request) async throws -> ReceiptDraftResponse {
        let session = try req.auth.require(SessionToken.self)

        let provider = req.receiptOCRProvider
        guard provider.isEnabled else {
            throw Abort(.serviceUnavailable, reason: "Receipt OCR is not available. Scan a QR code or enter the expense manually.")
        }

        // OCR runs a paid vision/OCR call; gate it to Pro/trial.
        try await req.usageCounterService.requirePremium(
            .receiptScan,
            userId: session.userId,
            on: req.db
        )

        let (imageData, contentType) = try await readImageUpload(req)
        guard let draft = try await provider.extract(imageData: imageData, contentType: contentType, on: req) else {
            return ReceiptDraftResponse(recognized: false, draft: nil)
        }
        return ReceiptDraftResponse(recognized: true, draft: draft)
    }

    private struct ImageUpload: Content {
        var file: File?
        var image: File?
    }

    private func readImageUpload(_ req: Request) async throws -> (data: Data, contentType: String) {
        if req.headers.contentType?.type.lowercased() == "multipart" {
            let upload = try req.content.decode(ImageUpload.self)
            guard var buffer = (upload.file ?? upload.image)?.data else {
                throw Abort(.badRequest, reason: "Missing image field in multipart body.")
            }
            guard buffer.readableBytes <= maxImageBytes else {
                throw Abort(.payloadTooLarge, reason: "Receipt image must be 8 MB or smaller.")
            }
            let contentType = (upload.file ?? upload.image)?.contentType?.serialize() ?? "application/octet-stream"
            let data = buffer.readData(length: buffer.readableBytes) ?? Data()
            return (data, contentType)
        }

        guard var buffer = try await req.body.collect(max: maxImageBytes).get() else {
            throw Abort(.badRequest, reason: "Missing image body.")
        }
        let contentType = req.headers.contentType?.serialize() ?? "application/octet-stream"
        let data = buffer.readData(length: buffer.readableBytes) ?? Data()
        return (data, contentType)
    }
}
