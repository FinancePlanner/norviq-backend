import Vapor

/// `ACHIEVEMENTS_ENABLED`, off by default. Independent of `SOCIAL_ENABLED`.
struct AchievementsConfiguration: Sendable {
    let enabled: Bool

    static func fromEnvironment() -> AchievementsConfiguration {
        AchievementsConfiguration(enabled: envBool("ACHIEVEMENTS_ENABLED", default: false))
    }
}

/// 404 while achievements are off, so the feature is invisible rather than broken.
struct AchievementsEnabledMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard AchievementsConfiguration.fromEnvironment().enabled else {
            throw Abort(.notFound)
        }
        return try await next.respond(to: request)
    }
}
