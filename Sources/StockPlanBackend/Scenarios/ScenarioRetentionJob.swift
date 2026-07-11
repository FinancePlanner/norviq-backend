import Fluent
import Foundation
import NIOCore
import Vapor

final class ScenarioRetentionJob: LifecycleHandler, @unchecked Sendable {
    private var scheduled: RepeatedTask?

    func didBoot(_ app: Application) throws {
        guard envBool("SCENARIO_PLANNING_ENABLED", default: false) else { return }
        scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: .minutes(5), delay: .hours(24)) { _ in
            Task { await self.runOnce(app) }
        }
    }

    func shutdown(_: Application) {
        scheduled?.cancel(); scheduled = nil
    }

    func runOnce(_ app: Application) async {
        do {
            try await ScenarioRunModel.query(on: app.db)
                .filter(\.$expiresAt < Date()).filter(\.$state ~~ ["completed", "failed", "cancelled"]).delete()
        } catch { app.logger.warning("scenario_retention failed error=\(error)") }
    }
}
