import Foundation
import NIOCore
import Vapor

final class TargetAlertPoller: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private var scheduled: RepeatedTask?

    init(intervalSeconds: Int64) {
        self.intervalSeconds = max(intervalSeconds, 30)
    }

    func didBoot(_ app: Application) throws {
        let eventLoop = app.eventLoopGroup.next()
        scheduled = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(30),
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

    private func tick(_ app: Application) async {
        let req = Request(application: app, on: app.eventLoopGroup.next())
        await app.targetAlertEvaluator.evaluateUnresolvedTargets(req: req)
    }
}
