import Fluent
import StockPlanShared
import Vapor

/// Upstream market-data provider returned HTTP 429. Surfaces as 503 with a
/// Retry-After hint so clients back off, instead of a generic 502.
struct MarketDataProviderRateLimitedError: AbortError {
    let retryAfterSeconds: Int

    init(retryAfterSeconds: Int = 30) {
        self.retryAfterSeconds = retryAfterSeconds
    }

    var status: HTTPResponseStatus {
        .serviceUnavailable
    }

    var reason: String {
        "Market data provider is rate limited. Try again shortly."
    }

    var headers: HTTPHeaders {
        ["Retry-After": String(retryAfterSeconds)]
    }
}

/// Collapses concurrent fetches for the same key into a single upstream call.
/// The first caller becomes the leader and performs the fetch with its own
/// Request; followers suspend until the leader publishes the result. This
/// keeps N concurrent cache misses for one symbol at one provider call.
actor InFlightFetchCoordinator<Value: Sendable> {
    enum Entry {
        case leader
        case follower(Value)
    }

    private var waiters: [String: [CheckedContinuation<Value, any Error>]] = [:]

    /// Returns nil when the caller is elected leader (it must fetch and then
    /// call `complete`), or the shared result once the in-flight fetch ends.
    func joinOrLead(key: String) async throws -> Value? {
        if waiters[key] != nil {
            return try await withCheckedThrowingContinuation { continuation in
                waiters[key, default: []].append(continuation)
            }
        }
        waiters[key] = []
        return nil
    }

    func complete(key: String, result: Result<Value, any Error>) {
        let pending = waiters.removeValue(forKey: key) ?? []
        for continuation in pending {
            continuation.resume(with: result)
        }
    }
}

extension DefaultMarketDataService {
    func fetchAndCacheBasicFinancials(
        symbol: String,
        providerName: String,
        redisKey: String,
        on req: Request
    ) async throws -> BasicFinancialsResponse {
        guard let fresh = try await provider.basicFinancials(symbol: symbol, on: req) else {
            throw Abort(.notFound, reason: "Basic financials not found for \(symbol).")
        }

        let response = makeBasicFinancialsResponse(from: fresh)
        do {
            let cached = try await upsertBasicFinancialsCache(
                response, provider: providerName, on: req.db
            )
            let decoded = decodeBasicFinancialsPayload(cached.payload) ?? response
            await redisSetValue(
                redisKey, value: decoded, ttlSeconds: cacheConfig.basicFinancialsTTLSeconds,
                on: req
            )
            return decoded
        } catch {
            if isMissingDatabaseRelationError(error, relation: BasicFinancialsCache.schema) {
                req.logger.warning(
                    "market.basic-financials live response returned without DB cache because relation \(BasicFinancialsCache.schema) is missing"
                )
                await redisSetValue(
                    redisKey, value: response,
                    ttlSeconds: cacheConfig.basicFinancialsTTLSeconds, on: req
                )
                return response
            }
            throw error
        }
    }
}
