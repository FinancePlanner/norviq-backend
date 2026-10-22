import Foundation
import NIOCore
import Vapor

/// Sends weekly digests as each user's local send time arrives.
///
/// Same lifecycle shape as `MarketBriefJob`: a repeated task, an overlap guard,
/// a shutdown drain and a leader lock. The 15-minute tick only decides who is
/// due; `DigestRunner`'s database claims are what keep a restart or a second
/// replica from sending twice.
final class WeeklyDigestJob: LifecycleHandler, @unchecked Sendable {
    private let tickIntervalSeconds: Int64
    private let initialDelaySeconds: Int64
    private let state = BackgroundJobState()

    init(tickIntervalSeconds: Int64 = 900, initialDelaySeconds: Int64 = 120) {
        self.tickIntervalSeconds = max(tickIntervalSeconds, 60)
        self.initialDelaySeconds = max(initialDelaySeconds, 0)
    }

    func didBoot(_ app: Application) throws {
        guard app.environment != .testing else { return }
        let eventLoop = app.eventLoopGroup.next()
        let scheduled = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(initialDelaySeconds),
            delay: .seconds(tickIntervalSeconds)
        ) { _ in
            guard self.state.begin() else { return }
            let task = Task {
                defer { self.state.finish() }
                await self.tick(app, now: Date())
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

    func tick(_ app: Application, now: Date) async {
        let runner = DigestRunner(config: app.digestConfig, sources: app.digestDataSources)
        await JobLock.runAsLeader(app, name: "weekly_digest_job") {
            let req = Request(application: app, on: app.eventLoopGroup.next())
            do {
                let summary = try await runner.runDue(now: now, on: req)
                if summary.claimed > 0 {
                    app.logger.info("digest.tick claimed=\(summary.claimed) sent=\(summary.sent) failed=\(summary.failed)")
                }
            } catch {
                app.logger.error("digest.tick_failed error=\(String(describing: error))")
            }
        }
    }
}
