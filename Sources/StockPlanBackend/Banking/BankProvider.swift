import Fluent
import NIOConcurrencyHelpers
import StockPlanShared
import Vapor

struct BankSyncResult: Sendable {
    var added = 0
    var modified = 0
    var removed = 0
}

enum BankProviderError: Error, AbortError {
    case notConfigured(BankProviderKind)
    case unsupportedOperation

    var status: HTTPResponseStatus {
        switch self {
        case .notConfigured: .serviceUnavailable
        case .unsupportedOperation: .badRequest
        }
    }

    var reason: String {
        switch self {
        case let .notConfigured(kind): "Bank provider \(kind.rawValue) is not configured."
        case .unsupportedOperation: "Operation not supported by this bank provider."
        }
    }
}

/// A bank-data aggregator driver. Plaid (US) and GoCardless (EU, Phase 4)
/// conform. Every operation is read-only against the institution — providers
/// must never expose a way to move money or place a payment.
protocol BankProvider: Sendable {
    var kind: BankProviderKind { get }

    /// Begin a hosted link flow (Plaid link_token / GoCardless hosted URL).
    func createLinkSession(userId: UUID, on req: Request) async throws -> BankLinkSessionResponse

    /// Complete linking, persist an encrypted connection, and fetch its accounts.
    func exchange(_ request: BankExchangeRequest, userId: UUID, on req: Request) async throws -> BankConnection

    /// Pull new/changed transactions into the staging table.
    func sync(connection: BankConnection, on req: Request) async throws -> BankSyncResult

    /// Revoke access at the provider. Throws when the provider refuses, so the
    /// caller can log it; callers treat it as best-effort and never block on it.
    func disconnect(connection: BankConnection, on req: Request) async throws

    // MARK: - Hosted-link flow (GoCardless / EU)

    // Providers that pick an institution before a hosted redirect implement
    // these; SDK-based providers (Plaid) inherit the default throwing versions.

    /// Banks selectable for a country (GoCardless). Plaid selects in-SDK.
    func listInstitutions(country: String, on req: Request) async throws -> [BankInstitutionResponse]

    /// Begin a hosted requisition for a chosen institution, returning the URL
    /// the client redirects the user to.
    func createHostedLink(userId: UUID, institutionId: String, redirectURI: String, on req: Request) async throws -> BankLinkSessionResponse

    /// Complete a hosted link identified by its callback reference, persisting an
    /// encrypted connection and its accounts.
    func completeHostedLink(reference: String, on req: Request) async throws -> BankConnection
}

extension BankProvider {
    func listInstitutions(country _: String, on _: Request) async throws -> [BankInstitutionResponse] {
        throw BankProviderError.unsupportedOperation
    }

    func createHostedLink(userId _: UUID, institutionId _: String, redirectURI _: String, on _: Request) async throws -> BankLinkSessionResponse {
        throw BankProviderError.unsupportedOperation
    }

    func completeHostedLink(reference _: String, on _: Request) async throws -> BankConnection {
        throw BankProviderError.unsupportedOperation
    }
}

/// Selects a provider by kind. GoCardless registers here in Phase 4.
struct BankProviderRegistry: Sendable {
    private let providers: [BankProviderKind: any BankProvider]

    init(providers: [any BankProvider]) {
        var map: [BankProviderKind: any BankProvider] = [:]
        for provider in providers {
            map[provider.kind] = provider
        }
        self.providers = map
    }

    func provider(for kind: BankProviderKind) throws -> any BankProvider {
        guard let provider = providers[kind] else {
            throw BankProviderError.notConfigured(kind)
        }
        return provider
    }

    var configuredKinds: [BankProviderKind] {
        Array(providers.keys)
    }

    /// The EU hosted-link aggregator to use when a client doesn't name one:
    /// Enable Banking when configured, else GoCardless.
    var preferredHostedKind: BankProviderKind {
        providers[.enablebanking] != nil ? .enablebanking : .gocardless
    }
}

extension Application {
    struct BankProviderRegistryKey: StorageKey {
        typealias Value = BankProviderRegistry
    }

    var bankProviderRegistry: BankProviderRegistry {
        get { storage[BankProviderRegistryKey.self] ?? BankProviderRegistry(providers: []) }
        set { storage[BankProviderRegistryKey.self] = newValue }
    }
}

extension Request {
    var bankProviderRegistry: BankProviderRegistry {
        application.bankProviderRegistry
    }
}

/// Best-effort revocation at the bank aggregator (Plaid `/item/remove`,
/// GoCardless requisition delete). A failure is logged, never thrown: the
/// local disconnect or account deletion must still go through. Each call is
/// capped (`timeout`), so a hung provider cannot hold a deletion open.
enum BankConnectionRevoker {
    struct TimedOut: Error {}

    static func revoke(_ connection: BankConnection, on req: Request, timeout: Duration = .seconds(10)) async {
        let connectionId = connection.id?.uuidString ?? "unknown"
        do {
            let kind = BankProviderKind(rawValue: connection.provider) ?? .plaid
            let provider = try req.bankProviderRegistry.provider(for: kind)
            // Not a task group: a group waits for every child, and an HTTP call
            // that ignores cancellation would hold it open past the deadline.
            // Whichever finishes first resumes; the loser is cancelled and left.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let once = ResumeOnce(continuation)
                let work = Task {
                    do {
                        try await provider.disconnect(connection: connection, on: req)
                        once.resume(with: .success(()))
                    } catch {
                        once.resume(with: .failure(error))
                    }
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    work.cancel()
                    once.resume(with: .failure(TimedOut()))
                }
            }
        } catch {
            req.logger.warning(
                "bank.revoke_failed provider=\(connection.provider) connection_id=\(connectionId) error_type=\(String(reflecting: type(of: error)))"
            )
        }
    }
}

/// Resumes a continuation exactly once, from whichever caller gets there first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NIOLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Void, any Error>) {
        let pending: CheckedContinuation<Void, any Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}
