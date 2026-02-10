import Vapor
import Fluent
import Foundation
import NIOCore

final class AuthTokenCleanup: LifecycleHandler, @unchecked Sendable {
    private let interval: TimeInterval
    private var scheduled: RepeatedTask?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func didBoot(_ app: Application) throws {
        let eventLoop = app.eventLoopGroup.next()
        scheduled = eventLoop.scheduleRepeatedTask(initialDelay: .seconds(10), delay: .seconds(Int64(interval))) { task in
            Task {
                await self.cleanup(app)
            }
        }
    }

    func shutdown(_ app: Application) {
        scheduled?.cancel()
    }

    private func cleanup(_ app: Application) async {
        let now = Date()
        do {
            _ = try await PasswordResetToken.query(on: app.db)
                .filter(\.$expiresAt <= now)
                .delete()

            _ = try await RefreshToken.query(on: app.db)
                .group(.or) { group in
                    group.filter(\.$expiresAt <= now)
                    group.filter(\.$revokedAt != nil)
                }
                .delete()
        } catch {
            app.logger.warning("Auth token cleanup failed: \(error)")
        }
    }
}
