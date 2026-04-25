import NIO
import Vapor
import Fluent

final class WebhookWorker: LifecycleHandler, @unchecked Sendable {
    private let repository: any WebhookRepository
    private let service: any WebhookDeliveryService
    private let batchSize: Int
    private let intervalSeconds: Int
    private var scheduledTask: RepeatedTask?
    
    init(
        repository: any WebhookRepository,
        service: WebhookDeliveryService,
        batchSize: Int = 100,
        intervalSeconds: Int = 30
    ) {
        self.repository = repository
        self.service = service
        self.batchSize = batchSize
        self.intervalSeconds = max(intervalSeconds, 10)
    }
    
    func didBoot(_ app: Application) throws {
        let eventLoop = app.eventLoopGroup.next()
        scheduledTask = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(5),
            delay: .seconds(Int64(intervalSeconds))
        ) { [weak self] _ in
            guard let self else { return }
            let req = Request(application: app, on: app.eventLoopGroup.next())
            Task {
                do {
                    try await self.service.processDueWebhooks(limit: self.batchSize, on: req.db)
                } catch {
                    app.logger.error("webhook_worker error: \\(error)")
                }
            }
        }
    }
    
    func shutdown(_ app: Application) {
        scheduledTask?.cancel()
        scheduledTask = nil
    }
}
