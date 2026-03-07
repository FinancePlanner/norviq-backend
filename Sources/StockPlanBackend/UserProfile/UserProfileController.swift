import Vapor

struct UserProfileController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let userProfile = protected.grouped("user-profile")

        userProfile.get(use: getProfile)
        userProfile.put(use: updateProfile)
        userProfile.delete(use: deleteProfile)
    }

    @Sendable
    func getProfile(req: Request) async throws -> GetUserProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await req.application.userProfileService.get(userId: session.userId, on: req.db)
    }

    @Sendable
    func updateProfile(req: Request) async throws -> UpdateUserProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(UpdateUserProfileRequest.self)
        return try await req.application.userProfileService.update(userId: session.userId, payload: payload, on: req.db)
    }

    @Sendable
    func deleteProfile(req: Request) async throws -> DeleteUserProfileResponse {
        let session = try req.auth.require(SessionToken.self)
        return try await req.application.userProfileService.delete(userId: session.userId, on: req.db)
    }
}
