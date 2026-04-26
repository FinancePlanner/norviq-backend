import Fluent
import NIO
import Vapor

final class DataExportCleanupJob: LifecycleHandler, @unchecked Sendable {
    let repository: any DataExportRepository
    let interval: TimeInterval
    private var scheduledTask: RepeatedTask?

    init(repository: any DataExportRepository, interval: TimeInterval = 86400) {
        self.repository = repository
        self.interval = interval
    }

    func didBoot(_ app: Application) throws {
        let eventLoop = app.eventLoopGroup.next()
        scheduledTask = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(5),
            delay: .seconds(Int64(interval))
        ) { [weak self] _ in
            Task {
                do {
                    let db = app.db(.psql)
                    let cutoffDate = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
                    let deletedCount = try await self?.repository.deleteExpired(before: cutoffDate, on: db) ?? 0
                    if deletedCount > 0 {
                        app.logger.info("data_export.cleanup deleted=\(deletedCount)")
                    }
                } catch {
                    app.logger.error("data_export.cleanup.failed error=\(String(describing: error))")
                }
            }
        }
    }

    func shutdown(_: Application) {
        scheduledTask?.cancel()
        scheduledTask = nil
    }
}
