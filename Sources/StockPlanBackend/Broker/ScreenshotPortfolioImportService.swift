import Foundation
import StockPlanShared
import Vapor

/// Turns broker screenshots into portfolio import rows.
///
/// Deliberately thin: it extracts rows from each image and then hands them to
/// `CsvPortfolioImportService`'s row-based entry points, so screenshots get the
/// same validation, existing-position classification, instrument resolution,
/// lot creation and dedupe as a CSV import. Nothing about the import path is
/// duplicated here.
struct ScreenshotPortfolioImportService {
    /// Most people screenshot one or two screens; three is a generous ceiling
    /// that keeps a single request's vision spend bounded.
    static let maxImages = 3

    /// Vision calls are the slow part, so run them together — but not unbounded,
    /// since every one is a paid upstream request.
    private let maxConcurrentExtractions = 3

    struct Image: Sendable {
        let data: Data
        let contentType: String
    }

    func preview(
        images: [Image],
        provider: String,
        portfolioListId: String?,
        userId: UUID,
        on req: Request
    ) async throws -> ScreenshotImportPreviewResponse {
        let (items, errors, kind) = try await extractRows(from: images, on: req)

        let enriched = try await CsvPortfolioImportService().preview(
            items: items,
            errors: errors,
            provider: provider,
            portfolioListId: portfolioListId,
            userId: userId,
            on: req
        )

        return ScreenshotImportPreviewResponse(
            provider: enriched.provider,
            kind: kind,
            items: enriched.items,
            errors: enriched.errors,
            imageCount: images.count
        )
    }

    /// Runs every image through the extractor and flattens the results into one
    /// row list, re-indexing `line` across the whole batch so the per-line error
    /// plumbing stays unambiguous when three images are uploaded at once.
    private func extractRows(
        from images: [Image],
        on req: Request
    ) async throws -> (items: [CsvImportPreviewItem], errors: [CsvImportPreviewError], kind: ScreenshotImportKind) {
        let extractor = req.screenshotPortfolioExtractor
        guard extractor.isEnabled else {
            throw Abort(
                .serviceUnavailable,
                reason: "Screenshot import is not available. Import a CSV or add positions manually."
            )
        }

        var extractions = [ScreenshotExtraction?](repeating: nil, count: images.count)
        try await withThrowingTaskGroup(of: (Int, ScreenshotExtraction).self) { group in
            var next = 0
            func addTask(_ index: Int) {
                let image = images[index]
                group.addTask {
                    try await (index, extractor.extract(imageData: image.data, contentType: image.contentType, on: req))
                }
            }

            while next < min(maxConcurrentExtractions, images.count) {
                addTask(next)
                next += 1
            }
            while let (index, extraction) = try await group.next() {
                extractions[index] = extraction
                if next < images.count {
                    addTask(next)
                    next += 1
                }
            }
        }

        var items: [CsvImportPreviewItem] = []
        var errors: [CsvImportPreviewError] = []
        var kinds: Set<ScreenshotImportKind> = []

        for (index, extraction) in extractions.enumerated() {
            guard let extraction else { continue }
            if let rejection = extraction.rejection {
                // `line` addresses the image, not a row, when a whole image failed.
                // Images are 1-indexed in the message because it is user-facing.
                errors.append(.init(
                    line: index,
                    message: images.count > 1 ? "Image \(index + 1): \(rejection)" : rejection
                ))
                continue
            }
            kinds.insert(extraction.kind)
            for row in extraction.rows {
                items.append(CsvImportPreviewItem(
                    line: items.count,
                    symbol: row.symbol,
                    shares: row.shares,
                    buyPrice: row.buyPrice,
                    buyDate: row.buyDate,
                    notes: nil,
                    confidence: row.confidence
                ))
            }
        }

        // Mixing a holdings list and a trade list in one batch means the rows mean
        // different things — some carry a real cost basis and some do not. Report
        // the batch as `unknown` so the review UI can say so, rather than
        // implying a uniform provenance the rows do not have.
        let kind: ScreenshotImportKind = kinds.count == 1 ? (kinds.first ?? .unknown) : .unknown
        return (items, errors, kind)
    }
}
