import Foundation
import NIOCore
import Vapor

final class TargetAlertPoller: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let initialDelaySeconds: Int64
    private let state = BackgroundJobState()

    init(intervalSeconds: Int64, initialDelaySeconds: Int64 = 30) {
        self.intervalSeconds = max(intervalSeconds, 30)
        self.initialDelaySeconds = max(initialDelaySeconds, 0)
    }

    func didBoot(_ app: Application) throws {
        let eventLoop = app.eventLoopGroup.next()
        let scheduled = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(initialDelaySeconds),
            delay: .seconds(intervalSeconds)
        ) { _ in
            guard self.state.begin() else {
                app.logger.debug("target_alert_poller skipped overlapping tick")
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
        await JobLock.runAsLeader(app, name: "target_alert_poller") { await self.tickAsLeader(app) }
    }

    private func tickAsLeader(_ app: Application) async {
        let req = Request(application: app, on: app.eventLoopGroup.next())
        await app.targetAlertEvaluator.evaluateUnresolvedTargets(req: req)
    }
}
