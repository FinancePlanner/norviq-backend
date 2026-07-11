import Foundation
import StockPlanShared
import Vapor

extension DefaultMarketDataService {
    func normalizeFMPResultLimit(_ rawLimit: Int?, defaultLimit: Int? = nil) throws -> Int? {
        guard let resolved = rawLimit ?? defaultLimit else { return nil }
        guard resolved > 0 else { throw Abort(.badRequest, reason: "`limit` must be greater than 0.") }
        switch fmpAccessTier {
        case .free, .starter: return min(resolved, 5)
        case .premium: return resolved
        }
    }

    static func calculateDCFPrice(
        projections: [YearlyProjectionResponse], sharesOutstanding: Double?, wacc: Double,
        terminalGrowthRate: Double, netDebt: Double
    ) -> Double? {
        guard let shares = sharesOutstanding, shares > 0, !projections.isEmpty else { return nil }
        let explicit = projections.enumerated().reduce(0.0) { result, item in
            result + (item.element.fcf ?? 0) / pow(1 + wacc, Double(item.offset + 1))
        }
        let finalFCF = projections.last?.fcf ?? 0
        let terminal = finalFCF * (1 + terminalGrowthRate) / (wacc - terminalGrowthRate)
        return (explicit + terminal / pow(1 + wacc, Double(projections.count)) - netDebt) / shares
    }
}
