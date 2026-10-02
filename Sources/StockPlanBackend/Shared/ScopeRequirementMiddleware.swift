import Vapor

/// Enforces a scope on requests authenticated with a third-party token.
/// First-party sessions carry no ScopeContext and pass through untouched.
struct ScopeRequirementMiddleware: AsyncMiddleware {
    /// The request passes when the token holds at least one of these.
    let accepted: Set<APIScope>

    init(_ required: APIScope) {
        self.init(anyOf: [required])
    }

    /// Accepts a token holding any one of `accepted` — used where a route is
    /// migrating to a narrower scope but must keep older tokens working.
    init(anyOf accepted: Set<APIScope>) {
        self.accepted = accepted
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        try check(request)
        return try await next.respond(to: request)
    }

    /// The same check for a handler whose required scope depends on the body
    /// (e.g. what a pilot follow writes into). Same 403 and reason as the
    /// middleware; first-party sessions pass.
    static func require(_ scope: APIScope, on request: Request) throws {
        try ScopeRequirementMiddleware(scope).check(request)
    }

    private func check(_ request: Request) throws {
        if let context = request.auth.get(ScopeContext.self),
           context.scopes.isDisjoint(with: accepted)
        {
            throw Abort(.forbidden, reason: "insufficient_scope: \(requirementDescription) required")
        }
    }

    private var requirementDescription: String {
        accepted
            .map(\.rawValue)
            .sorted()
            .map { "'\($0)'" }
            .joined(separator: " or ")
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
