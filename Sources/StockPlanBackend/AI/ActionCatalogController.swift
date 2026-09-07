import Foundation
import Vapor

/// The action catalog, published.
///
/// `ActionCatalog` unifies the two Swift consumers (the HTTP controllers and the
/// in-process assistant), but norviq-mcp is a separate Go service that hand-writes
/// its tool structs. That is how a tool decoding `GET /v1/stocks` as
/// `{items, nextCursor}` shipped while the endpoint actually returns a bare array:
/// nothing compared the two sides.
///
/// This endpoint makes the Swift catalog readable by the Go side, so drift becomes
/// a check rather than something spotted by eye.
struct ActionCatalogController: RouteCollection {
    struct ActionSchema: Content {
        let name: String
        let description: String
        /// True when the action needs an explicit `confirm`. Clients must render a
        /// confirmation for these; a client that ignores it still cannot execute,
        /// because the server refuses without the flag.
        let destructive: Bool
        let required: [String]
        let properties: [String: PropertySchema]
    }

    struct PropertySchema: Content {
        let type: String
        let description: String?
        let enumValues: [String]?
    }

    struct CatalogResponse: Content {
        let actions: [ActionSchema]
    }

    func boot(routes: any RoutesBuilder) throws {
        // Capability metadata about the caller's own account, so any authenticated
        // credential may read it: a client cannot ask for the right scopes without
        // first knowing which actions exist.
        routes
            .grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
            .get("actions", "catalog", use: catalog)
    }

    @Sendable
    func catalog(req _: Request) async throws -> CatalogResponse {
        CatalogResponse(actions: ActionCatalog.all.map { action in
            var properties: [String: PropertySchema] = [:]
            for (key, parameter) in action.properties {
                properties[key] = PropertySchema(
                    type: parameter.type,
                    description: parameter.description,
                    enumValues: parameter.enumValues
                )
            }
            if action.destructive {
                properties["confirm"] = PropertySchema(
                    type: "boolean",
                    description: "must be true to actually perform this; ask the user first",
                    enumValues: nil
                )
            }
            return ActionSchema(
                name: action.name,
                description: action.description,
                destructive: action.destructive,
                required: action.destructive ? action.required + ["confirm"] : action.required,
                properties: properties
            )
        }
        .sorted { $0.name < $1.name })
    }
}
