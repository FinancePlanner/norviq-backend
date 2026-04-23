import Foundation
import Vapor

struct TrialExpirationJob: LifecycleHandler {
    private let state = TrialExpirationJobState()

    func willBoot(_ app: Application) async throws {
        // Job scheduled to run
    }

    func didBoot(_ app: Application) async throws {
        // Start the background processing task
        app.logger.info("trial_expiration_job starting")
        scheduleJob(app: app)
    }

    private func scheduleJob(app: Application) {
        let task = Task {
            let trialService = app.trialService
            let db = app.db
            let intervalMinutes = max(
                1,
                Int(Environment.get("TRIAL_EXPIRATION_CHECK_INTERVAL_MINUTES") ?? "60") ?? 60
            )
            let intervalNanoseconds = UInt64(intervalMinutes * 60 * 1_000_000_000)

            while !Task.isCancelled {
                do {
                    let expiredUserIDs = try await trialService.processExpiredTrials(db: db)
                    if !expiredUserIDs.isEmpty {
                        app.logger.info(
                            "trial_expiration_job processed_users=\(expiredUserIDs.count) user_ids=\(expiredUserIDs.map { $0.uuidString }.joined(separator: ","))"
                        )
                    }
                } catch is CancellationError {
                    break
                } catch {
                    app.logger.error("trial_expiration_job error=\(error)")
                }

                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch is CancellationError {
                    break
                } catch {
                    app.logger.error("trial_expiration_job sleep_error=\(error)")
                }
            }
        }
        state.setTask(task)
    }

    func shutdown(_ app: Application) async {
        state.cancelTask()
        app.logger.info("trial_expiration_job shutdown")
    }
}

private final class TrialExpirationJobState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func setTask(_ task: Task<Void, Never>) {
        lock.lock()
        self.task?.cancel()
        self.task = task
        lock.unlock()
    }

    func cancelTask() {
        lock.lock()
        task?.cancel()
        task = nil
        lock.unlock()
    }
}
