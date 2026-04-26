import Fluent
import Foundation
import NIOCore
import Vapor

final class AuthTokenCleanup: LifecycleHandler, @unchecked Sendable {
    private let interval: TimeInterval
    private let state = AuthTokenCleanupState()

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func didBoot(_ app: Application) throws {
        let eventLoop = app.eventLoopGroup.next()
        let scheduled = eventLoop.scheduleRepeatedTask(initialDelay: .seconds(10), delay: .seconds(Int64(interval))) { _ in
            guard self.state.beginRun() else {
                app.logger.debug("auth_token_cleanup skipped overlapping run")
                return
            }
            let task = Task {
                defer { self.state.finishRun() }
                await self.cleanup(app)
            }
            self.state.setCurrentTask(task)
        }
        state.setScheduled(scheduled)
    }

    func shutdown(_: Application) {
        state.cancelAll()
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

private final class AuthTokenCleanupState: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: RepeatedTask?
    private var currentTask: Task<Void, Never>?
    private var isRunning = false

    func setScheduled(_ scheduled: RepeatedTask) {
        lock.lock()
        self.scheduled?.cancel()
        self.scheduled = scheduled
        lock.unlock()
    }

    func beginRun() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else {
            return false
        }
        isRunning = true
        return true
    }

    func setCurrentTask(_ task: Task<Void, Never>) {
        lock.lock()
        currentTask = task
        lock.unlock()
    }

    func finishRun() {
        lock.lock()
        currentTask = nil
        isRunning = false
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        scheduled?.cancel()
        scheduled = nil
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
        lock.unlock()
    }
}
