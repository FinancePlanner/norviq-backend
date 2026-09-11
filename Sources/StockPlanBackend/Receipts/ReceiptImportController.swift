import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Commits expenses the user confirmed on a receipt review screen.
///
/// Separate from `ReceiptsController` because it writes: scanning reads images
/// and costs AI, this writes rows and costs nothing. Keeping them apart means a
/// retried commit never re-runs a vision call.
///
/// Every row goes through `ExpenseBulkImporter`, the same write path as the CSV
/// and spreadsheet importers, so receipts get identical dedupe, per-row failure
/// isolation, single-snapshot-per-month creation and budget drift re-evaluation.
struct ReceiptImportController: RouteCollection {
    /// Three receipts split into line items can legitimately be dozens of rows;
    /// beyond this it is a client bug, not a shopping trip.
    private let maxItems = 300

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        protected
            .grouped(ScopeRequirementMiddleware(.expensesWrite))
            .post("expenses", "import", "receipts", "commit", use: commit)
    }

    @Sendable
    func commit(req: Request) async throws -> ReceiptImportCommitResponse {
        let session = try req.auth.require(SessionToken.self)
        // Re-checked at commit so a downgrade between scanning and confirming
        // cannot slip a Pro-scanned batch through.
        try await req.usageCounterService.requirePremium(
            .receiptScan, userId: session.userId, on: req.db
        )

        let payload = try req.content.decode(ReceiptImportCommitRequest.self)
        guard !payload.items.isEmpty else {
            throw Abort(.badRequest, reason: "No expenses to import.")
        }
        guard payload.items.count <= maxItems else {
            throw Abort(.badRequest, reason: "Import at most \(maxItems) expenses at a time.")
        }

        let candidates = payload.items.enumerated().map { index, item in
            ExpenseBulkImporter.Candidate(
                reference: index,
                request: item.expense,
                externalID: item.externalId
            )
        }

        let importer = ExpenseBulkImporter(expensesService: req.expensesService, request: req)

        // Drop anything the user already has. A re-scanned receipt is the
        // expected case here — people photograph the same slip twice — so this
        // is the difference between forgiving and duplicating their records.
        let existingKeys = try await importer.existingDedupKeys(
            userId: session.userId,
            occurredOnRange: ExpenseBulkImporter.occurredOnRange(of: candidates),
            on: req.db
        )

        var seen = Set<String>()
        var accepted: [ExpenseBulkImporter.Candidate] = []
        var skipped = 0
        for candidate in candidates {
            let key = ExpenseBulkImporter.dedupKey(
                occurredOn: candidate.request.occurredOn,
                amount: candidate.request.amount,
                title: candidate.request.title,
                externalID: candidate.externalID
            )
            // `seen` also catches duplicates within this same batch, which two
            // photos of one receipt would otherwise produce.
            guard !existingKeys.contains(key), seen.insert(key).inserted else {
                skipped += 1
                continue
            }
            accepted.append(candidate)
        }

        let outcome = try await importer.insert(accepted, userId: session.userId, on: req.db)

        let errors = outcome.failures
            .sorted { $0.key < $1.key }
            .map { ReceiptImportRowError(index: $0.key, message: $0.value) }

        let response = ReceiptImportCommitResponse(
            imported: outcome.imported,
            skipped: skipped,
            failed: errors.count,
            monthsTouched: outcome.months.map(Self.monthLabel).sorted(),
            errors: errors
        )
        req.logger.info(
            "receipt_import_commit imported=\(response.imported) skipped=\(response.skipped) failed=\(response.failed)"
        )
        return response
    }

    private static func monthLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }
}
