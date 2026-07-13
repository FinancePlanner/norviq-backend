import Fluent
import Foundation
import Vapor

struct ScenarioSnapshotCaptureService {
    func capture(
        portfolioListId: UUID,
        userId: UUID,
        baseCurrency: String,
        cryptoHoldingIds: [UUID],
        req: Request
    ) async throws -> ScenarioSnapshotModel {
        let holdings = try await Stock.query(on: req.db)
            .filter(\.$userId == userId)
            .filter(\.$portfolioListId == portfolioListId)
            .sort(\.$symbol)
            .all()
        let profiles = try await HoldingRiskProfileModel.owned(by: userId, on: req.db).all()
        let profilesByHolding = Dictionary(uniqueKeysWithValues: profiles.map { ($0.holdingId, $0) })
        var items: [ScenarioJSONValue] = []
        var warnings: [ScenarioJSONValue] = []
        var totalValue = 0.0
        for holding in holdings {
            guard let holdingID = holding.id else { throw Abort(.internalServerError, reason: "Holding id missing") }
            let profile = profilesByHolding[holdingID]
            let quote = try? await req.application.marketDataService.quote(symbol: holding.symbol, on: req)
            let requiresManual = ["real_estate", "commodity"].contains(profile?.assetCategory ?? holding.category.rawValue)
            if requiresManual, profile?.manualValue == nil || profile?.benchmarkProxy == nil {
                throw Abort(.unprocessableEntity, reason: "Manual or unpriced holdings require manualValue and benchmarkProxy")
            }
            let manualUnitPrice = profile?.manualValue.map { $0 / max(holding.shares, 1) }
            let price = quote?.currentPrice ?? manualUnitPrice ?? holding.buyPrice
            let currency = (quote?.currency ?? baseCurrency).uppercased()
            var fxRate = 1.0
            if currency != baseCurrency {
                if let fx = try? await req.application.marketDataService.fx(pair: "\(currency)\(baseCurrency)", on: req) {
                    fxRate = fx.rate
                } else {
                    warnings.append(.object([
                        "code": .string("stale_fx"), "holding_id": .string(holding.id?.uuidString ?? ""),
                        "message": .string("FX unavailable; value uses a 1:1 fallback."),
                    ]))
                }
            }
            if quote == nil {
                warnings.append(.object([
                    "code": .string("stale_price"), "holding_id": .string(holding.id?.uuidString ?? ""),
                    "message": .string("Live quote unavailable; purchase price used."),
                ]))
            }
            let value = (profile?.manualValue ?? (holding.shares * price)) * fxRate
            totalValue += value
            items.append(.object([
                "id": .string(holding.id?.uuidString ?? ""), "instrument_key": .string(holding.symbol.uppercased()),
                "symbol": .string(holding.symbol.uppercased()), "quantity": .number(holding.shares),
                "price": .number(price), "currency": .string(currency), "fx_rate": .number(fxRate),
                "value_in_base_currency": .number(value), "asset_category": .string(profile?.assetCategory ?? holding.category.rawValue),
                "sector": profile?.sector.map(ScenarioJSONValue.string) ?? .null,
                "region": profile?.region.map(ScenarioJSONValue.string) ?? .null,
                "benchmark_proxy": profile?.benchmarkProxy.map(ScenarioJSONValue.string) ?? .null,
                "duration": profile?.duration.map(ScenarioJSONValue.number) ?? .null,
                "convexity": profile?.convexity.map(ScenarioJSONValue.number) ?? .null,
                "factor_overrides": .object(profile?.factorOverrides.values ?? [:]),
            ]))
        }

        try await appendCash(userId: userId, baseCurrency: baseCurrency, req: req, items: &items, warnings: &warnings, totalValue: &totalValue)
        try await appendCrypto(userId: userId, selectedIDs: cryptoHoldingIds, baseCurrency: baseCurrency, req: req, items: &items, warnings: &warnings, totalValue: &totalValue)
        guard !items.isEmpty else { throw Abort(.unprocessableEntity, reason: "Portfolio has no holdings or cash") }

        let now = Date()
        return ScenarioSnapshotModel(
            userId: userId, portfolioListId: portfolioListId, baseCurrency: baseCurrency,
            valuationTimestamp: now,
            payload: ScenarioJSON(["total_value": .number(totalValue), "holdings": .array(items)]),
            warnings: ScenarioJSON(["items": .array(warnings)])
        )
    }

    private func appendCash(
        userId: UUID, baseCurrency: String, req: Request, items: inout [ScenarioJSONValue],
        warnings: inout [ScenarioJSONValue], totalValue: inout Double
    ) async throws {
        let accounts = try await Account.query(on: req.db).filter(\.$userId == userId).all()
        let accountIDs = accounts.compactMap(\.id)
        guard !accountIDs.isEmpty else { return }
        let balances = try await CashBalance.query(on: req.db).filter(\.$accountId ~~ accountIDs).all()
        var latest: [String: CashBalance] = [:]
        for balance in balances {
            let key = "\(balance.accountId)|\(balance.currency.uppercased())"
            if latest[key] == nil || balance.asOf > latest[key]!.asOf {
                latest[key] = balance
            }
        }
        for balance in latest.values where balance.balance != 0 {
            let currency = balance.currency.uppercased() == "BASE" ? baseCurrency : balance.currency.uppercased()
            let fxRate = await conversionRate(from: currency, to: baseCurrency, req: req, holdingID: balance.id, warnings: &warnings)
            let value = balance.balance * fxRate; totalValue += value
            items.append(.object([
                "id": .string(balance.id?.uuidString ?? ""), "instrument_key": .string("CASH:\(currency)"),
                "symbol": .string(currency), "quantity": .number(balance.balance), "price": .number(1),
                "currency": .string(currency), "fx_rate": .number(fxRate), "value_in_base_currency": .number(value),
                "asset_category": .string("cash"),
            ]))
        }
    }

    private func appendCrypto(
        userId: UUID, selectedIDs: [UUID], baseCurrency: String, req: Request,
        items: inout [ScenarioJSONValue], warnings: inout [ScenarioJSONValue], totalValue: inout Double
    ) async throws {
        guard !selectedIDs.isEmpty else { return }
        let holdings = try await CryptoPortfolioItem.query(on: req.db)
            .filter(\.$userId == userId).filter(\.$id ~~ selectedIDs).all()
        guard holdings.count == Set(selectedIDs).count else { throw Abort(.notFound, reason: "Crypto holding not found") }
        for holding in holdings {
            let quote = try? await req.application.cryptoService.quote(symbols: holding.symbol, on: req).first
            let price = quote?.price ?? holding.averageBuyPrice
            if quote == nil {
                warnings.append(warning("stale_price", holding.id, "Live crypto quote unavailable; average purchase price used."))
            }
            let quoteCurrency = "USD"
            let fxRate = await conversionRate(
                from: quoteCurrency, to: baseCurrency, req: req,
                holdingID: holding.id, warnings: &warnings
            )
            let value = holding.quantity * price * fxRate; totalValue += value
            items.append(.object([
                "id": .string(holding.id?.uuidString ?? ""), "instrument_key": .string("CRYPTO:\(holding.symbol.uppercased())"),
                "symbol": .string(holding.symbol.uppercased()), "quantity": .number(holding.quantity), "price": .number(price),
                "currency": .string(quoteCurrency), "fx_rate": .number(fxRate), "value_in_base_currency": .number(value),
                "asset_category": .string("crypto"),
            ]))
        }
    }

    private func conversionRate(
        from: String, to: String, req: Request, holdingID: UUID?, warnings: inout [ScenarioJSONValue]
    ) async -> Double {
        guard from != to else { return 1 }
        if let fx = try? await req.application.marketDataService.fx(pair: "\(from)\(to)", on: req) {
            return fx.rate
        }
        warnings.append(warning("stale_fx", holdingID, "FX unavailable; value uses a 1:1 fallback.")); return 1
    }

    private func warning(_ code: String, _ holdingID: UUID?, _ message: String) -> ScenarioJSONValue {
        .object(["code": .string(code), "holding_id": .string(holdingID?.uuidString ?? ""), "message": .string(message)])
    }
}
