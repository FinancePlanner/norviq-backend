import Vapor
import Logging
import NIOCore
import NIOPosix

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        try bootstrapLogging(from: &env)

        let app = try await Application.make(env)

        // This attempts to install NIO as the Swift Concurrency global executor.
        // You can enable it if you'd like to reduce the amount of context switching between NIO and Swift Concurrency.
        // Note: this has caused issues with some libraries that use `.wait()` and cleanly shutting down.
        // If enabled, you should be careful about calling async functions before this point as it can cause assertion failures.
        // let executorTakeoverSuccess = NIOSingletons.unsafeTryInstallSingletonPosixEventLoopGroupAsConcurrencyGlobalExecutor()
        // app.logger.debug("Tried to install SwiftNIO's EventLoopGroup as Swift's global concurrency executor", metadata: ["success": .stringConvertible(executorTakeoverSuccess)])

        do {
            try await configure(app)
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private static func bootstrapLogging(from env: inout Environment) throws {
        let logFormat = ProcessInfo.processInfo.environment["LOG_FORMAT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if logFormat == "json" || (logFormat == nil && env == .production) {
            try LoggingSystem.bootstrap(from: &env) { level in
                { label in JSONLogHandler(label: label, level: level) }
            }
        } else {
            try LoggingSystem.bootstrap(from: &env)
        }
    }
}
