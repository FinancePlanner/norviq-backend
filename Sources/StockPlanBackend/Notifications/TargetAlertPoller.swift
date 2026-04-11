import Foundation
import NIOCore
import Vapor

final class TargetAlertPoller: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let initialDelaySeconds: Int64
    private var scheduled: RepeatedTask?

    init(intervalSeconds: Int64, initialDelaySeconds: Int64 = 30) {
        self.intervalSeconds = max(intervalSeconds, 30)
        self.initialDelaySeconds = max(initialDelaySeconds, 0)
    }

    func didBoot(_ app: Application) throws {
        let eventLoop = app.eventLoopGroup.next()
        scheduled = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(initialDelaySeconds),
            delay: .seconds(intervalSeconds)
        ) { _ in
            Task {
                await self.tick(app)
            }
        }
    }

    func shutdown(_ app: Application) {
        scheduled?.cancel()
    }

    func runOnce(_ app: Application) async {
        await tick(app)
    }

    private func tick(_ app: Application) async {
        let req = Request(application: app, on: app.eventLoopGroup.next())
        await app.targetAlertEvaluator.evaluateUnresolvedTargets(req: req)
    }
}
