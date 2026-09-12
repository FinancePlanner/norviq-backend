import Foundation
import NIOCore
import Vapor

final class EarningsNotificationPoller: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let initialDelaySeconds: Int64
    private let state = BackgroundJobState()

    init(intervalSeconds: Int64 = 86400, initialDelaySeconds: Int64 = 60) {
        self.intervalSeconds = max(intervalSeconds, 3600)
        self.initialDelaySeconds = max(initialDelaySeconds, 0)
    }

    func didBoot(_ app: Application) throws {
        let eventLoop = app.eventLoopGroup.next()
        let scheduled = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(initialDelaySeconds),
            delay: .seconds(intervalSeconds)
        ) { _ in
            guard self.state.begin() else {
                app.logger.debug("earnings_notification_poller skipped overlapping tick")
                return
            }
            let task = Task {
                defer { self.state.finish() }
                await self.tick(app)
            }
            self.state.track(task: task)
        }
        state.set(scheduled: scheduled)
    }

    func shutdown(_: Application) {
        state.stopAcceptingRuns()
    }

    func shutdownAsync(_: Application) async {
        await state.stopAndDrain()
    }

    func runOnce(_ app: Application) async {
        await tick(app)
    }

    private func tick(_ app: Application) async {
        await JobLock.runAsLeader(app, name: "earnings_notification_poller") { await self.tickAsLeader(app) }
    }

    private func tickAsLeader(_ app: Application) async {
        let req = Request(application: app, on: app.eventLoopGroup.next())
        await app.earningsNotificationEvaluator.evaluateUpcomingEarnings(req: req)
    }
}
