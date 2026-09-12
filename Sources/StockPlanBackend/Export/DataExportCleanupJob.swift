import Fluent
import NIO
import Vapor

final class DataExportCleanupJob: LifecycleHandler, @unchecked Sendable {
    let repository: any DataExportRepository
    let interval: TimeInterval
    private let state = BackgroundJobState()

    init(repository: any DataExportRepository, interval: TimeInterval = 86400) {
        self.repository = repository
        self.interval = interval
    }

    func didBoot(_ app: Application) throws {
        let eventLoop = app.eventLoopGroup.next()
        let scheduled = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(5),
            delay: .seconds(Int64(interval))
        ) { [weak self] _ in
            guard let self, state.begin() else { return }
            let task = Task {
                defer { self.state.finish() }
                do {
                    let db = app.db(.psql)
                    let cutoffDate = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
                    let deletedCount = try await self.repository.deleteExpired(before: cutoffDate, on: db)
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
        state.stopAcceptingRuns()
    }

    func shutdownAsync(_: Application) async {
        await state.stopAndDrain()
    }
}
