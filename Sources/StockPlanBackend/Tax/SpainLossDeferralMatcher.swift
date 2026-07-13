import Foundation

enum SpainMarketAdmissionPolicy {
    static func windowMonths(status: String?, source: String?, reviewedAt: Date?) -> Int? {
        guard source?.isEmpty == false, reviewedAt != nil else { return nil }
        return switch status {
        case "regulated": 2
        case "unlisted": 12
        default: nil
        }
    }
}

struct SpainLossDeferralReplacement: Sendable, Equatable {
    let lotId: UUID
    let acquisitionDate: Date
    let remainingQuantity: Double
}

struct SpainLossDeferralAllocation: Sendable, Equatable {
    let replacementLotId: UUID
    let matchedQuantity: Double
    let deferredLoss: Double
}

struct SpainLossDeferralMatcher: Sendable {
    func match(
        saleDate: Date,
        soldQuantity: Double,
        realizedPnL: Double,
        replacements: [SpainLossDeferralReplacement],
        windowMonths: Int = 2,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [SpainLossDeferralAllocation] {
        guard soldQuantity > 0, realizedPnL < 0, windowMonths > 0,
              let windowStart = calendar.date(byAdding: .month, value: -windowMonths, to: saleDate),
              let windowEnd = calendar.date(byAdding: .month, value: windowMonths, to: saleDate)
        else { return [] }

        let lossPerUnit = -realizedPnL / soldQuantity
        var unmatched = soldQuantity
        var allocations = [SpainLossDeferralAllocation]()
        for replacement in replacements
            .filter({
                $0.remainingQuantity > 0
                    && $0.acquisitionDate >= windowStart
                    && $0.acquisitionDate <= windowEnd
            })
            .sorted(by: {
                ($0.acquisitionDate, $0.lotId.uuidString) < ($1.acquisitionDate, $1.lotId.uuidString)
            })
            where unmatched > 0
        {
            let quantity = min(unmatched, replacement.remainingQuantity)
            allocations.append(.init(
                replacementLotId: replacement.lotId,
                matchedQuantity: quantity,
                deferredLoss: quantity * lossPerUnit
            ))
            unmatched -= quantity
        }
        return allocations
    }
}
