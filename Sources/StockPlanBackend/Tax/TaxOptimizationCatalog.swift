import Fluent
import Foundation
import StockPlanShared
import Vapor

struct TaxReplacementCatalog: Codable, Sendable {
    let version: String
    let effectiveFrom: String
    let entries: [TaxReplacementCatalogEntry]
}

struct TaxReplacementCatalogEntry: Codable, Sendable {
    let sourceSymbols: [String]
    let sourceTaxIdentityGroup: String?
    let replacementSymbol: String
    let replacementName: String
    let replacementExchange: String
    let replacementCurrency: String
    let replacementInstrumentType: String
    let eligibleJurisdictions: [TaxJurisdiction]
    let expenseRatio: Decimal?
    let priority: Int
    let reviewedAt: String
    let reviewReference: String
}

struct TaxEfficiencyCatalog: Codable, Sendable {
    let version: String
    let effectiveFrom: String
    let entries: [TaxEfficiencyCatalogEntry]
}

struct TaxEfficiencyCatalogEntry: Codable, Sendable {
    let assetClass: String
    let expectedYield: Decimal
    let ordinaryIncomeShare: Decimal
    let turnover: Decimal
    let reviewedAt: String
    let reviewReference: String
}

enum TaxOptimizationCatalogError: Error, LocalizedError {
    case missingResource(String)
    case emptyVersion(String)
    case unreviewedReplacement(String)
    case invalidReplacement(String)
    case invalidEfficiencyEntry(String)

    var errorDescription: String? {
        switch self {
        case let .missingResource(name): "Missing bundled tax catalog \(name)."
        case let .emptyVersion(name): "Tax catalog \(name) must declare a version."
        case let .unreviewedReplacement(symbol): "Replacement \(symbol) has no review evidence."
        case let .invalidReplacement(symbol): "Replacement \(symbol) has invalid source or jurisdiction metadata."
        case let .invalidEfficiencyEntry(assetClass): "Tax efficiency entry \(assetClass) is outside supported bounds."
        }
    }
}

struct TaxOptimizationCatalog: Sendable {
    let replacements: TaxReplacementCatalog
    let efficiency: TaxEfficiencyCatalog

    static func bundled() throws -> TaxOptimizationCatalog {
        let decoder = JSONDecoder()
        let replacements = try decoder.decode(
            TaxReplacementCatalog.self,
            from: resourceData(named: "tax-replacement-catalog")
        )
        let efficiency = try decoder.decode(
            TaxEfficiencyCatalog.self,
            from: resourceData(named: "tax-efficiency-catalog")
        )
        let catalog = TaxOptimizationCatalog(replacements: replacements, efficiency: efficiency)
        try catalog.validate()
        return catalog
    }

    func validate() throws {
        guard !replacements.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaxOptimizationCatalogError.emptyVersion("replacement")
        }
        guard !efficiency.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaxOptimizationCatalogError.emptyVersion("efficiency")
        }
        for entry in replacements.entries {
            let reviewed = !entry.reviewedAt.isEmpty && !entry.reviewReference.isEmpty
            guard reviewed else {
                throw TaxOptimizationCatalogError.unreviewedReplacement(entry.replacementSymbol)
            }
            let hasSource = !entry.sourceSymbols.isEmpty || entry.sourceTaxIdentityGroup?.isEmpty == false
            let hasInstrumentMetadata = !entry.replacementName.isEmpty
                && !entry.replacementExchange.isEmpty
                && !entry.replacementCurrency.isEmpty
                && !entry.replacementInstrumentType.isEmpty
            guard hasSource,
                  !entry.replacementSymbol.isEmpty,
                  hasInstrumentMetadata,
                  !entry.eligibleJurisdictions.isEmpty
            else {
                throw TaxOptimizationCatalogError.invalidReplacement(entry.replacementSymbol)
            }
        }
        for entry in efficiency.entries {
            let values = [entry.expectedYield, entry.ordinaryIncomeShare, entry.turnover]
            guard !entry.assetClass.isEmpty,
                  values.allSatisfy({ $0 >= 0 && $0 <= 1 }),
                  !entry.reviewedAt.isEmpty,
                  !entry.reviewReference.isEmpty
            else { throw TaxOptimizationCatalogError.invalidEfficiencyEntry(entry.assetClass) }
        }
    }

    func efficiencyEntry(for instrumentType: String) -> TaxEfficiencyCatalogEntry? {
        let normalized = instrumentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return efficiency.entries.first { $0.assetClass == normalized }
    }

    private static func resourceData(named name: String) throws -> Data {
        let candidates = [
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources"),
            Bundle.module.url(forResource: name, withExtension: "json"),
        ]
        guard let url = candidates.compactMap(\.self).first else {
            throw TaxOptimizationCatalogError.missingResource(name)
        }
        return try Data(contentsOf: url)
    }
}

struct TaxReplacementScorer: Sendable {
    struct Metrics: Sendable, Equatable {
        let correlation: Decimal?
        let volatilitySimilarity: Decimal?
        let allocationFit: Decimal
        let expenseEfficiency: Decimal
        let overlappingReturns: Int
    }

    func score(_ metrics: Metrics) -> (score: Decimal, confidence: Decimal) {
        let correlation = bounded(metrics.correlation ?? Decimal(string: "0.50")!)
        let volatility = bounded(metrics.volatilitySimilarity ?? Decimal(string: "0.50")!)
        let score = correlation * Decimal(string: "0.45")!
            + volatility * Decimal(string: "0.20")!
            + bounded(metrics.allocationFit) * Decimal(string: "0.25")!
            + bounded(metrics.expenseEfficiency) * Decimal(string: "0.10")!
        let confidence: Decimal = metrics.overlappingReturns >= 126 ? Decimal(string: "0.90")! : Decimal(string: "0.55")!
        return (bounded(score), confidence)
    }

    private func bounded(_ value: Decimal) -> Decimal {
        min(1, max(0, value))
    }
}

struct TaxReplacementService: Sendable {
    private let catalog: TaxOptimizationCatalog
    private let scorer = TaxReplacementScorer()
    private let priceBars = MarketPriceBarRepository()

    init(catalog: TaxOptimizationCatalog) {
        self.catalog = catalog
    }

    func candidates(
        for source: Instrument,
        jurisdiction: TaxJurisdiction,
        on database: any Database
    ) async throws -> [TaxReplacementCandidate] {
        let sourceSymbol = source.symbol.uppercased()
        let matchingEntries = catalog.replacements.entries.filter { entry in
            let symbolMatches = entry.sourceSymbols.map { $0.uppercased() }.contains(sourceSymbol)
            let identityMatches = entry.sourceTaxIdentityGroup != nil
                && entry.sourceTaxIdentityGroup == source.taxIdentityGroup
            return (symbolMatches || identityMatches) && entry.eligibleJurisdictions.contains(jurisdiction)
        }
        guard !matchingEntries.isEmpty else { return [] }

        let replacementSymbols = matchingEntries.map { $0.replacementSymbol.uppercased() }
        let instruments = try await Instrument.query(on: database)
            .filter(\.$symbol ~~ replacementSymbols)
            .all()
        let bySymbol = Dictionary(grouping: instruments, by: { $0.symbol.uppercased() })
        var candidates = [TaxReplacementCandidate]()
        for entry in matchingEntries.sorted(by: { $0.priority < $1.priority }) {
            guard let replacement = bySymbol[entry.replacementSymbol.uppercased()]?.first,
                  !isSubstantiallyIdentical(source, replacement),
                  let replacementID = replacement.id
            else { continue }
            let metrics = try await metrics(source: source, replacement: replacement, entry: entry, on: database)
            let result = scorer.score(metrics)
            var warnings = [
                "The funds use distinct stated benchmarks, but whether securities are substantially identical depends on all facts and circumstances. Confirm treatment with a tax professional.",
            ]
            if metrics.overlappingReturns < 126 {
                warnings.append(
                    "Less than 126 overlapping daily returns were available; ranking uses reviewed catalog priority with reduced confidence."
                )
            }
            candidates.append(TaxReplacementCandidate(
                instrumentId: replacementID.uuidString,
                symbol: replacement.symbol,
                name: replacement.name,
                score: result.score,
                correlationScore: metrics.correlation,
                volatilityScore: metrics.volatilitySimilarity,
                allocationFitScore: metrics.allocationFit,
                expenseEfficiencyScore: metrics.expenseEfficiency,
                expenseRatio: entry.expenseRatio,
                confidence: result.confidence,
                catalogVersion: catalog.replacements.version,
                reviewedAt: entry.reviewedAt,
                reviewReference: entry.reviewReference,
                warnings: warnings
            ))
        }
        return candidates.sorted { ($0.score, $0.symbol) > ($1.score, $1.symbol) }
    }

    private func metrics(
        source: Instrument,
        replacement: Instrument,
        entry: TaxReplacementCatalogEntry,
        on database: any Database
    ) async throws -> TaxReplacementScorer.Metrics {
        let end = Date()
        let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: -400, to: end)!
        let sourcePrices = try await priceBars.adjustedCloses(
            instrumentKey: source.symbol,
            from: start,
            to: end,
            on: database
        )
        let replacementPrices = try await priceBars.adjustedCloses(
            instrumentKey: replacement.symbol,
            from: start,
            to: end,
            on: database
        )
        let paired = pairedReturns(sourcePrices, replacementPrices)
        let correlation = paired.count >= 126 ? decimal(correlation(paired.map(\.0), paired.map(\.1))) : nil
        let volatilitySimilarity: Decimal? = paired.count >= 126
            ? decimal(volatilitySimilarity(paired.map(\.0), paired.map(\.1)))
            : nil
        let expense = entry.expenseRatio.map { max(0, 1 - min(1, $0 * 20)) } ?? Decimal(string: "0.50")!
        return .init(
            correlation: correlation.map { max(0, ($0 + 1) / 2) },
            volatilitySimilarity: volatilitySimilarity,
            allocationFit: 1,
            expenseEfficiency: expense,
            overlappingReturns: paired.count
        )
    }

    private func isSubstantiallyIdentical(_ lhs: Instrument, _ rhs: Instrument) -> Bool {
        if lhs.id == rhs.id {
            return true
        }
        if let lhsISIN = lhs.isin, !lhsISIN.isEmpty, lhsISIN == rhs.isin {
            return true
        }
        if let lhsCUSIP = lhs.cusip, !lhsCUSIP.isEmpty, lhsCUSIP == rhs.cusip {
            return true
        }
        if let group = lhs.taxIdentityGroup, !group.isEmpty, group == rhs.taxIdentityGroup {
            return true
        }
        return false
    }

    private func pairedReturns(
        _ lhs: [(date: Date, close: Double)],
        _ rhs: [(date: Date, close: Double)]
    ) -> [(Double, Double)] {
        let left = returnsByDay(lhs)
        let right = returnsByDay(rhs)
        return Set(left.keys).intersection(right.keys).sorted().compactMap { day in
            guard let l = left[day], let r = right[day] else { return nil }
            return (l, r)
        }
    }

    private func returnsByDay(_ prices: [(date: Date, close: Double)]) -> [String: Double] {
        var result = [String: Double]()
        guard prices.count > 1 else { return result }
        for index in prices.indices.dropFirst() {
            let previous = prices[index - 1].close
            guard previous > 0 else { continue }
            result[Self.dayFormatter.string(from: prices[index].date)] = prices[index].close / previous - 1
        }
        return result
    }

    private func correlation(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, lhs.count > 1 else { return 0 }
        let leftMean = lhs.reduce(0, +) / Double(lhs.count)
        let rightMean = rhs.reduce(0, +) / Double(rhs.count)
        let numerator = zip(lhs, rhs).reduce(0) { $0 + ($1.0 - leftMean) * ($1.1 - rightMean) }
        let leftVariance = lhs.reduce(0) { $0 + pow($1 - leftMean, 2) }
        let rightVariance = rhs.reduce(0) { $0 + pow($1 - rightMean, 2) }
        let denominator = sqrt(leftVariance * rightVariance)
        return denominator > 0 ? numerator / denominator : 0
    }

    private func volatilitySimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let left = standardDeviation(lhs)
        let right = standardDeviation(rhs)
        let scale = max(left, right)
        return scale > 0 ? max(0, 1 - abs(left - right) / scale) : 1
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return sqrt(values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1))
    }

    private func decimal(_ value: Double) -> Decimal {
        Decimal(value.isFinite ? value : 0)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
