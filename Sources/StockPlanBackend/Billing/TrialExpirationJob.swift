import Vapor

struct TrialExpirationJob: LifecycleHandler {
    func willBoot(_ app: Application) async throws {
        // Job scheduled to run
    }

    func didBoot(_ app: Application) async throws {
        // Start the background processing task
        app.logger.info("trial_expiration_job starting")
        scheduleJob(app: app)
    }

    private func scheduleJob(app: Application) {
        Task {
            let trialService = app.trialService
            let db = app.db
            let intervalMinutes = Int(Environment.get("TRIAL_EXPIRATION_CHECK_INTERVAL_MINUTES") ?? "60") ?? 60

            while !Task.isCancelled {
                do {
                    let expiredUserIDs = try await trialService.processExpiredTrials(db: db)
                    if !expiredUserIDs.isEmpty {
                        app.logger.info(
                            "trial_expiration_job processed_users=\(expiredUserIDs.count) user_ids=\(expiredUserIDs.map { $0.uuidString }.joined(separator: ","))"
                        )
                    }
                } catch {
                    app.logger.error("trial_expiration_job error=\(error)")
                }

                // Sleep for the interval
                try await Task.sleep(nanoseconds: UInt64(intervalMinutes * 60 * 1_000_000_000))
            }
        }
    }

    func shutdown(_ app: Application) async {
        // Cleanup if needed
        app.logger.info("trial_expiration_job shutdown")
    }
}

