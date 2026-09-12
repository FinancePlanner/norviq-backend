import Fluent
import Foundation
import NIOCore
import Vapor

/// Deletes import sessions once they're no longer usable.
///
/// Clients call DELETE on cancel, but that can't be relied on — a closed tab, a
/// killed app, a lost connection all leave a row holding an encrypted copy of
/// someone's finances. This is the backstop that makes the hour-long TTL a
/// guarantee rather than an intention.
///
/// Runs hourly rather than daily like the assistant's retention job, because
/// these rows live for an hour, not a fortnight.
final class ExpenseImportRetentionJob: LifecycleHandler, @unchecked Sendable {
    private let state = BackgroundJobState()

    func didBoot(_ app: Application) throws {
        let scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .minutes(5),
            delay: .hours(1)
        ) { _ in
            guard self.state.begin() else { return }
            let task = Task {
                defer { self.state.finish() }
                await self.runOnce(app)
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
        do {
            let now = Date()
            try await ExpenseImportSession.query(on: app.db)
                .filter(\.$expiresAt < now)
                .delete()

            // Committed and discarded sessions have served their purpose; keep
            // them briefly so a double-submit still gets a coherent 409 rather
            // than a confusing 404.
            if let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: now) {
                try await ExpenseImportSession.query(on: app.db)
                    .filter(\.$status != ExpenseImportSession.Status.ready)
                    .filter(\.$updatedAt < cutoff)
                    .delete()
            }
        } catch {
            app.logger.warning("expense_import.retention_failed error=\(error)")
        }
    }
}
