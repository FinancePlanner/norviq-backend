import Fluent
import Foundation
import NIOCore
import Vapor

final class AuthTokenCleanup: LifecycleHandler, @unchecked Sendable {
    private let interval: TimeInterval
    private let state = BackgroundJobState()

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func didBoot(_ app: Application) throws {
        let eventLoop = app.eventLoopGroup.next()
        let scheduled = eventLoop.scheduleRepeatedTask(initialDelay: .seconds(10), delay: .seconds(Int64(interval))) { _ in
            guard self.state.begin() else {
                app.logger.debug("auth_token_cleanup skipped overlapping run")
                return
            }
            let task = Task {
                defer { self.state.finish() }
                await self.cleanup(app)
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

    private func cleanup(_ app: Application) async {
        let now = Date()
        do {
            // Clean up expired password reset tokens
            _ = try await PasswordResetToken.query(on: app.db)
                .filter(\.$expiresAt <= now)
                .delete()
        } catch {
            // Silently ignore if table doesn't exist yet (migrations not run)
            if !isTableNotFoundError(error) {
                app.logger.warning("Password reset token cleanup failed: \(error)")
            }
        }

        do {
            // Clean up expired or revoked refresh tokens
            _ = try await RefreshToken.query(on: app.db)
                .group(.or) { group in
                    group.filter(\.$expiresAt <= now)
                    group.filter(\.$revokedAt != nil)
                }
                .delete()
        } catch {
            // Silently ignore if table doesn't exist yet (migrations not run)
            if !isTableNotFoundError(error) {
                app.logger.warning("refresh_token cleanup failed error_type=\(String(reflecting: type(of: error)))")
            }
        }
    }

    private func isTableNotFoundError(_ error: any Error) -> Bool {
        let errorString = String(reflecting: error)
        return errorString.contains("does not exist") || errorString.contains("relation") && errorString.contains("does not exist")
    }
}
