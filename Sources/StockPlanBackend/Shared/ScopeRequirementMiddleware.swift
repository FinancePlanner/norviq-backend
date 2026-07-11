import Vapor

/// Enforces a scope on requests authenticated with a third-party token.
/// First-party sessions carry no ScopeContext and pass through untouched.
struct ScopeRequirementMiddleware: AsyncMiddleware {
    let required: APIScope

    init(_ required: APIScope) {
        self.required = required
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if let context = request.auth.get(ScopeContext.self),
           !context.scopes.contains(required)
        {
            throw Abort(.forbidden, reason: "insufficient_scope: '\(required.rawValue)' required")
        }
        return try await next.respond(to: request)
    }
}

/// Blocks third-party tokens entirely — for routes inside scoped groups that are
/// not part of the external tool surface (household partner, recurring templates,
/// suggestion dismissal, token management).
struct FirstPartyOnlyMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.auth.get(ScopeContext.self) == nil else {
            throw Abort(.forbidden, reason: "This endpoint requires a first-party session.")
        }
        return try await next.respond(to: request)
    }
}
