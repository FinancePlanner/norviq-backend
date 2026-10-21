import Foundation
import Vapor

/// Environment switches for Groups. Off unless both `SOCIAL_ENABLED` and
/// `GROUPS_ENABLED` are set, so the routes can deploy before the apps show
/// the tab. `GROUPS_PUBLIC_ENABLED` turns off the stranger-facing directory
/// (and creating or switching to public groups) without touching private ones.
struct GroupsConfiguration: Sendable {
    let enabled: Bool
    let publicDirectory: Bool

    static func fromEnvironment() -> GroupsConfiguration {
        let enabled = SocialConfiguration.fromEnvironment().enabled && envBool("GROUPS_ENABLED", default: false)
        return GroupsConfiguration(
            enabled: enabled,
            publicDirectory: enabled && envBool("GROUPS_PUBLIC_ENABLED", default: true)
        )
    }
}

/// 404 while Groups is off, so the feature is invisible rather than broken.
struct GroupsEnabledMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard GroupsConfiguration.fromEnvironment().enabled else {
            throw Abort(.notFound)
        }
        return try await next.respond(to: request)
    }
}
