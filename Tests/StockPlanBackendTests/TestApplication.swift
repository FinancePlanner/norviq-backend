import Foundation
import Vapor

/// Application factory for suites that need an app in a *non-test* environment.
///
/// `Application.make` finishes with `DotEnvFile.load(for: app.environment, …)`
/// (Vapor, `Sources/Vapor/Application.swift:176`), which `setenv`s every
/// `KEY=VALUE` of `.env.<environment>` and then of `.env` into the **process**
/// environment (`Sources/Vapor/Utilities/DotEnv.swift:230`). Nothing ever takes
/// them back out again, and `setenv` is called with `overwrite: 0`, so the very
/// first value wins for the rest of the run.
///
/// One `Application.make(.production)` therefore copies a developer's untracked
/// `.env.production` — here 66 keys, among them `DATABASE_*`, `REDIS_URL`,
/// `JWT_SECRET`, `APNS_*` and `USER_PII_ENCRYPTION_ACTIVE_KEY` — into the
/// environment that every later suite in the same process boots against. That
/// is not a race between readers and writers: it is a one-way, irreversible
/// overwrite whose blast radius is "every suite scheduled after it", which is
/// why the damage looked non-deterministic under parallel scheduling. CI has no
/// `.env.production`, so it only ever bites locally.
///
/// `makeIsolated` restores the process environment to exactly what it was
/// before the call, so a local dotenv file cannot change what any test sees.
/// Developers do not have to move their `.env.production` aside.
///
/// `.testing` apps deliberately keep going through `Application.make` directly:
/// they load `.env.<testing>` (which does not exist) plus the shared `.env`,
/// and the local `.env` is how a developer's `DATABASE_*` reaches the suite.
enum TestApplication {
    /// Makes an application for `environment` without leaving any dotenv value
    /// behind in the process environment.
    ///
    /// The whole snapshot/make/restore window runs under ``DatabaseTestLock``
    /// so that no concurrently scheduled suite can observe the environment
    /// while the dotenv values are momentarily present.
    static func makeIsolated(_ environment: Environment) async throws -> Application {
        try await DatabaseTestLock.withLock {
            let before = ProcessInfo.processInfo.environment
            let app = try await Application.make(environment)
            for (key, value) in ProcessInfo.processInfo.environment where before[key] != value {
                if let original = before[key] {
                    setenv(key, original, 1)
                } else {
                    unsetenv(key)
                }
            }
            return app
        }
    }
}
