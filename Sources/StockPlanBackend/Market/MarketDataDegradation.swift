import NIOConcurrencyHelpers
import Vapor

/// Remembers which keys have already been logged, so a permanently unavailable
/// upstream costs one log line per process rather than one per request.
final class OnceLogGate: Sendable {
    private let seen = NIOLockedValueBox<Set<String>>([])

    init() {}

    /// `true` the first time `key` is passed in this process, `false` after.
    func shouldLog(_ key: String) -> Bool {
        seen.withLockedValue { $0.insert(key).inserted }
    }
}

/// Tells "this plan or this symbol has nothing here" apart from "the service is
/// broken", for the market features that must answer with an empty result
/// rather than an error.
enum MarketDataDegradation {
    private static let gate = OnceLogGate()

    /// Whether `error` should be answered with an empty result instead of being
    /// re-thrown.
    ///
    /// `FMPMarketDataProvider.fetchJSON` has already folded the upstream status
    /// into an `Abort`: a 404 stays 404, a 402 stays 402, and a 401, a 403 *and*
    /// a body that failed to decode all arrive as 502. Nothing at this layer can
    /// tell a forbidden response from a malformed one, and for these features
    /// both mean the same thing, so 502 degrades too.
    ///
    /// `serviceUnavailable` deliberately does not: that is a missing
    /// `FMP_API_KEY`, which is a misconfiguration the caller should see.
    static func isMissingData(_ error: any Error) -> Bool {
        guard let abort = error as? any AbortError else { return false }
        switch abort.status {
        case .notFound, .paymentRequired, .unauthorized, .forbidden, .badGateway:
            return true
        default:
            return false
        }
    }

    /// Logs the first degradation of `feature` in this process and stays quiet
    /// afterwards. An FMP plan that does not include an endpoint fails on every
    /// single request, so logging per request would bury everything else.
    static func warnOnce(feature: String, error: any Error, logger: Logger) {
        guard gate.shouldLog(feature) else { return }
        logger.warning(
            "\(feature) degraded to an empty result and will stay quiet about it. error=\(error)"
        )
    }
}
