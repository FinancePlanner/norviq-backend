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

/// Decides which upstream failures the ownership features answer with an empty
/// result instead of an error.
///
/// **Read this before assuming the bucket is narrow.** In practice it is close
/// to "everything": `FMPMarketDataProvider.fetchJSON` collapses the upstream
/// status before this layer ever sees it. A 404 stays 404 and a 402 stays 402,
/// but 401, 403, a body that failed to decode, **and its `default:` branch —
/// every other status, so 429 throttling and a 500 or 503 from FMP itself** —
/// all arrive here as 502. Nothing at this layer can tell those apart.
///
/// So the honest statement of the rule is: for these three features, any
/// upstream answer that is not a decodable success degrades to an empty
/// result, whatever caused it. That is a deliberate trade for public,
/// crawlable ticker pages — an FMP outage renders a page with no insider
/// section rather than a 502 — and it has two consequences worth knowing:
///
/// 1. An outage is indistinguishable from a plan gap in the response. The
///    `warnOnce` log line is the only signal, which is why it names both.
/// 2. A degraded response is **not written to the cache** (see
///    `MarketDataService+Ownership`), so a throttle or an outage costs an
///    empty answer for that request only, not for the whole six-hour TTL.
///
/// Narrowing `fetchJSON`'s mapping so a 429 or a 5xx stays distinguishable is
/// recorded as follow-up; it is shared by every market endpoint and cannot be
/// changed from here.
enum MarketDataDegradation {
    private static let gate = OnceLogGate()

    /// Whether `error` should be answered with an empty result instead of being
    /// re-thrown.
    ///
    /// `serviceUnavailable` is the one failure that does not degrade: the
    /// provider raises it for a missing `FMP_API_KEY`, and the ownership
    /// services raise it when no FMP provider is configured at all. Both are
    /// misconfigurations the caller should see. Note that a 503 *from FMP* does
    /// not reach here as a 503 — `fetchJSON` has already turned it into a 502.
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
    /// afterwards. Both causes fail on every single request for as long as they
    /// last, so logging per request would bury everything else.
    ///
    /// The message names both causes on purpose: this line is what staging has
    /// to debug from, and an empty response cannot tell them apart.
    static func warnOnce(feature: String, error: any Error, logger: Logger) {
        guard gate.shouldLog(feature) else { return }
        logger.warning(
            """
            \(feature) degraded to an empty result and will stay quiet about it for the rest of \
            this process. Either the FMP plan does not cover this endpoint, or FMP is throttling \
            or down — the upstream status is not distinguishable here. The empty result is not \
            cached, so this self-heals without a restart. error=\(error)
            """
        )
    }
}
