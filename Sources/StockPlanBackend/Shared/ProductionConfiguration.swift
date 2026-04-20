import Vapor

enum ProductionConfiguration {
    static func validate(for app: Application) throws {
        guard app.environment == .production else { return }

        try validateJWTSecret(Environment.get("JWT_SECRET"))
        _ = try allowedOrigins(from: Environment.get("ALLOWED_ORIGINS"), isProduction: true)
    }

    static func allowedOrigins(from rawValue: String?, isProduction: Bool) throws -> [String] {
        let configured = rawValue?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let origins = configured, !origins.isEmpty else {
            if isProduction {
                throw Abort(.internalServerError, reason: "ALLOWED_ORIGINS is required in production.")
            }
            return ["http://localhost:3000", "http://localhost:8080"]
        }

        if isProduction {
            let unsafeOrigins = origins.filter { origin in
                let lowercased = origin.lowercased()
                return lowercased == "*"
                    || lowercased.contains("localhost")
                    || lowercased.contains("127.0.0.1")
                    || lowercased.contains("0.0.0.0")
            }
            guard unsafeOrigins.isEmpty else {
                throw Abort(
                    .internalServerError,
                    reason: "ALLOWED_ORIGINS contains unsafe production origins: \(unsafeOrigins.joined(separator: ", "))"
                )
            }
        }

        return origins
    }

    static func validateJWTSecret(_ rawValue: String?) throws {
        let secret = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !secret.isEmpty else {
            throw Abort(.internalServerError, reason: "JWT_SECRET is required in production.")
        }
        guard secret != "dev-secret" else {
            throw Abort(.internalServerError, reason: "JWT_SECRET must not use the development default in production.")
        }
        guard secret.count >= 32 else {
            throw Abort(.internalServerError, reason: "JWT_SECRET must be at least 32 characters in production.")
        }
    }
}
