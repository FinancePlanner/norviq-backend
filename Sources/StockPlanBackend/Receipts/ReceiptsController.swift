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
        // Batch scan spends one vision call per image, so it is first-party
        // only — same reasoning as the spreadsheet and screenshot imports.
        writeScoped.grouped(FirstPartyOnlyMiddleware()).post("scan", use: scanBatch)
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

    /// Scans several receipt photos in one request.
    ///
    /// Returns one result per image, in the order they were sent, so a client
    /// can pair a failure with the photo that caused it. Images that yield
    /// nothing come back as `recognized: false` rather than failing the batch:
    /// one unreadable photo out of five should not discard the other four.
    @Sendable
    func scanBatch(req: Request) async throws -> ReceiptBatchScanResponse {
        let session = try req.auth.require(SessionToken.self)

        let provider = req.receiptOCRProvider
        guard provider.isEnabled else {
            throw Abort(.serviceUnavailable, reason: "Receipt scanning is not available. Scan a QR code or enter the expense manually.")
        }

        let images = try await readImageUploads(req)

        // Charged per image, because that is what is actually spent. Checked
        // once up front so a user without the entitlement never reaches the
        // model, then counted per image below.
        try await req.usageCounterService.requirePremium(
            .receiptScan,
            userId: session.userId,
            on: req.db
        )

        var results = [ReceiptDraftResponse?](repeating: nil, count: images.count)
        try await withThrowingTaskGroup(of: (Int, ReceiptDraftResponse).self) { group in
            var next = 0
            func addTask(_ index: Int) {
                let image = images[index]
                group.addTask {
                    do {
                        let draft = try await provider.extract(
                            imageData: image.data,
                            contentType: image.contentType,
                            on: req
                        )
                        return (index, ReceiptDraftResponse(recognized: draft != nil, draft: draft))
                    } catch {
                        // One bad image must not sink the batch.
                        req.logger.warning("receipt_scan_image_failed index=\(index) error=\(error)")
                        return (index, ReceiptDraftResponse(recognized: false, draft: nil))
                    }
                }
            }

            while next < min(maxConcurrentScans, images.count) {
                addTask(next)
                next += 1
            }
            while let (index, result) = try await group.next() {
                results[index] = result
                if next < images.count {
                    addTask(next)
                    next += 1
                }
            }
        }

        let resolved = results.compactMap(\.self)
        let recognized = resolved.filter(\.recognized).count
        req.logger.info("receipt_scan_batch images=\(images.count) recognized=\(recognized)")
        return ReceiptBatchScanResponse(results: resolved)
    }

    /// Most people photograph a handful of receipts at once; five bounds the
    /// vision spend of a single request.
    private var maxImagesPerBatch: Int {
        5
    }

    /// Every scan is a paid upstream call, so fan out but not without limit.
    private var maxConcurrentScans: Int {
        3
    }

    private struct BatchImageUpload: Content {
        var file: [File]?
        var image: [File]?
    }

    private func readImageUploads(_ req: Request) async throws -> [(data: Data, contentType: String)] {
        guard req.headers.contentType?.type.lowercased() == "multipart" else {
            throw Abort(.unsupportedMediaType, reason: "Upload receipt photos as multipart/form-data.")
        }

        let upload = try req.content.decode(BatchImageUpload.self)
        let parts = (upload.file ?? []) + (upload.image ?? [])
        guard !parts.isEmpty else {
            throw Abort(.badRequest, reason: "Missing image field in multipart body.")
        }
        guard parts.count <= maxImagesPerBatch else {
            throw Abort(.badRequest, reason: "Scan at most \(maxImagesPerBatch) receipts at a time.")
        }

        var images: [(data: Data, contentType: String)] = []
        images.reserveCapacity(parts.count)
        for part in parts {
            var buffer = part.data
            guard buffer.readableBytes <= maxImageBytes else {
                throw Abort(.payloadTooLarge, reason: "Each receipt image must be 8 MB or smaller.")
            }
            let contentType = part.contentType?.serialize() ?? "application/octet-stream"
            let data = buffer.readData(length: buffer.readableBytes) ?? Data()
            images.append((data, contentType))
        }
        return images
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
