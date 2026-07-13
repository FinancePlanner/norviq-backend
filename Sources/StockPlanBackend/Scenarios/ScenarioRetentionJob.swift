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
            let unsaved = try await ScenarioDefinitionModel.query(on: app.db)
                .filter(\.$isSaved == false).all()
            for scenario in unsaved {
                guard let id = scenario.id else { continue }
                let runCount = try await ScenarioRunModel.query(on: app.db)
                    .filter(\.$scenario.$id == id).count()
                if runCount == 0 {
                    try await scenario.delete(on: app.db)
                }
            }
        } catch { app.logger.warning("scenario_retention failed error=\(error)") }
    }
}
