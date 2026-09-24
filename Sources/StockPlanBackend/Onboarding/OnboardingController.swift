import Foundation
import StockPlanShared
import Vapor

struct OnboardingController: RouteCollection {
    /// Everything else on the row is server-owned. Both spellings are accepted
    /// because the backend decoder accepts both.
    static let clientWritableKeys: Set<String> = [
        "funnelStep", "funnel_step",
        "funnelCompleted", "funnel_completed",
        "guidedStartDismissed", "guided_start_dismissed",
    ]

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let onboarding = protected.grouped("onboarding")
        onboarding.grouped(ScopeRequirementMiddleware(.settingsRead)).get(use: get)
        onboarding.grouped(ScopeRequirementMiddleware(.settingsWrite)).patch(use: patch)
    }

    @Sendable
    func get(req: Request) async throws -> OnboardingStateDTO {
        let session = try req.auth.require(SessionToken.self)
        return try await OnboardingStateService.fetchOrCreate(userId: session.userId, on: req.db).toDTO()
    }

    @Sendable
    func patch(req: Request) async throws -> OnboardingStateDTO {
        let session = try req.auth.require(SessionToken.self)
        let patch = try Self.decodePatch(req)
        return try await OnboardingStateService.apply(patch, userId: session.userId, on: req.db).toDTO()
    }

    static func decodePatch(_ req: Request) throws -> OnboardingPatchRequest {
        guard
            let body = req.body.string,
            let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        else {
            throw Abort(.badRequest, reason: "Expected a JSON object")
        }
        if let rejected = object.keys.sorted().first(where: { !clientWritableKeys.contains($0) }) {
            throw Abort(.badRequest, reason: "\(rejected) is set by the server, not by clients")
        }
        let patch = try req.content.decode(OnboardingPatchRequest.self)
        if patch.funnelCompleted == false {
            throw Abort(.badRequest, reason: "funnelCompleted is one-way")
        }
        if let step = patch.funnelStep, OnboardingFunnelStep(rawValue: step) == nil {
            throw Abort(.badRequest, reason: "Unknown funnel step \(step)")
        }
        return patch
    }
}
