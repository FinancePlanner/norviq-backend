import Fluent
import Foundation
import NIOCore
import Vapor

final class TaxReportCleanupJob: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private var task: RepeatedTask?

    init(intervalSeconds: Int64 = 3600) {
        self.intervalSeconds = intervalSeconds
    }

    func didBoot(_ application: Application) throws {
        task = application.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .seconds(60),
            delay: .seconds(intervalSeconds)
        ) { _ in
            application.eventLoopGroup.any().makeFutureWithTask {
                try await self.removeExpiredReports(application)
            }.whenFailure { error in
                application.logger.error("tax_report.cleanup failed error=\(error)")
            }
        }
    }

    func shutdown(_: Application) {
        task?.cancel()
    }

    private func removeExpiredReports(_ application: Application) async throws {
        let reports = try await TaxReport.query(on: application.db)
            .filter(\.$expiresAt != nil)
            .filter(\.$expiresAt < Date())
            .all()

        var deletedFiles = 0
        for report in reports {
            if let path = report.filePath {
                do {
                    try application.taxReportStorage.delete(at: path)
                    deletedFiles += 1
                } catch {
                    application.logger.warning(
                        "tax_report.cleanup_file_failed report_id=\(report.id?.uuidString ?? "unknown") error=\(error)"
                    )
                    continue
                }
            }

            report.filePath = nil
            report.status = "expired"
            try await report.save(on: application.db)
        }

        if !reports.isEmpty {
            application.logger.info(
                "tax_report.cleanup completed expired=\(reports.count) deleted=\(deletedFiles)"
            )
        }
    }
}
