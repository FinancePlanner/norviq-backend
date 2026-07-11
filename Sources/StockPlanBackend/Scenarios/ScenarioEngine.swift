import Foundation

struct ScenarioEngineHolding: Sendable, Equatable {
    let id: String
    let value: Double
    let assetClass: String
    let sector: String?
    let region: String?
    let currency: String
    let duration: Double?
    let convexity: Double?
}

struct ScenarioShockSet: Sendable {
    var holdings: [String: Double] = [:]
    var assetClasses: [String: Double] = [:]
    var sectors: [String: Double] = [:]
    var regions: [String: Double] = [:]
    var currencies: [String: Double] = [:]
    var parallelRateShiftBps: Double = 0
}

struct ScenarioEngine {
    static let version = "1.0.0"

    func customValue(for holding: ScenarioEngineHolding, shocks: ScenarioShockSet) -> Double {
        if let override = shocks.holdings[holding.id] {
            return holding.value * (1 + override)
        }

        var multiplier = 1.0
        multiplier *= 1 + (shocks.assetClasses[holding.assetClass] ?? 0)
        multiplier *= 1 + (holding.sector.flatMap { shocks.sectors[$0] } ?? 0)
        multiplier *= 1 + (holding.region.flatMap { shocks.regions[$0] } ?? 0)
        multiplier *= 1 + (shocks.currencies[holding.currency] ?? 0)

        let rateShift = shocks.parallelRateShiftBps / 10000
        if holding.assetClass == "bond", let duration = holding.duration {
            let convexity = holding.convexity ?? 0
            multiplier *= 1 - duration * rateShift + 0.5 * convexity * rateShift * rateShift
        }
        return max(0, holding.value * multiplier)
    }

    func monteCarloTerminalValues(
        initialValue: Double,
        monthlyContribution: Double,
        annualReturn: Double,
        annualVolatility: Double,
        horizonMonths: Int,
        pathCount: Int,
        seed: UInt64
    ) -> [Double] {
        var generator = SplitMix64(seed: seed)
        let monthlyMean = annualReturn / 12
        let monthlyVolatility = annualVolatility / sqrt(12)
        var values = [Double]()
        values.reserveCapacity(pathCount)

        for _ in 0 ..< pathCount {
            var value = initialValue
            for _ in 0 ..< horizonMonths {
                value = max(0, value * (1 + monthlyMean + monthlyVolatility * generator.normal()) + monthlyContribution)
            }
            values.append(value)
        }
        return values
    }

    func maximumDrawdown(_ values: [Double]) -> Double {
        guard var peak = values.first, peak > 0 else { return 0 }
        var maximum = 0.0
        for value in values {
            peak = max(peak, value)
            maximum = max(maximum, (peak - value) / peak)
        }
        return maximum
    }
}

enum ScenarioSimulationDistribution: Sendable {
    case normal
    case studentT(degreesOfFreedom: Int)
    case blockBootstrap(monthlyReturns: [Double], blockMonths: Int)
}

struct ScenarioSimulationSpec: Sendable {
    let initialValue: Double
    let monthlyContribution: Double
    let annualContributionGrowth: Double
    let annualReturn: Double
    let annualVolatility: Double
    let annualInflation: Double
    let horizonMonths: Int
    let pathCount: Int
    let seed: UInt64
    let targetAmount: Double?
    let distribution: ScenarioSimulationDistribution
}

struct ScenarioSimulationBand: Sendable, Equatable {
    let month: Int
    let p10: Double
    let p25: Double
    let p50: Double
    let p75: Double
    let p90: Double
}

struct ScenarioSimulationOutput: Sendable, Equatable {
    let bands: [ScenarioSimulationBand]
    let goalProbability: Double?
    let expectedShortfall: Double?
    let medianMaximumDrawdown: Double
}

struct CorrelatedScenarioSimulationSpec: Sendable {
    let initialValue: Double
    let weights: [Double]
    let annualReturns: [Double]
    let annualCovariance: [[Double]]
    let monthlyContribution: Double
    let annualContributionGrowth: Double
    let annualInflation: Double
    let horizonMonths: Int
    let pathCount: Int
    let seed: UInt64
    let targetAmount: Double?
    let studentTDegreesOfFreedom: Int?
}

extension ScenarioEngine {
    func simulateCorrelated(_ spec: CorrelatedScenarioSimulationSpec) -> ScenarioSimulationOutput {
        let count = spec.weights.count
        guard count > 0, spec.annualReturns.count == count,
              spec.annualCovariance.count == count,
              spec.annualCovariance.allSatisfy({ $0.count == count })
        else {
            return ScenarioSimulationOutput(bands: [], goalProbability: nil, expectedShortfall: nil, medianMaximumDrawdown: 0)
        }
        let weightTotal = spec.weights.reduce(0, +)
        let weights = weightTotal == 0 ? Array(repeating: 1 / Double(count), count: count) : spec.weights.map { $0 / weightTotal }
        let monthlyCovariance = spec.annualCovariance.map { $0.map { $0 / 12 } }
        guard let factor = cholesky(repairedCovariance(monthlyCovariance)) else {
            return ScenarioSimulationOutput(bands: [], goalProbability: nil, expectedShortfall: nil, medianMaximumDrawdown: 0)
        }
        let paths = max(1, min(spec.pathCount, 50000)); let months = max(1, min(spec.horizonMonths, 600))
        var generator = SplitMix64(seed: spec.seed)
        var columns = Array(repeating: [Double](), count: months + 1)
        var drawdowns: [Double] = []; var successes = 0; var shortfalls: [Double] = []
        for _ in 0 ..< paths {
            if Task.isCancelled {
                break
            }
            var value = spec.initialValue; var peak = value; var maximumDrawdown = 0.0
            columns[0].append(value)
            for month in 1 ... months {
                let independent = (0 ..< count).map { _ in generator.normal() }
                var correlated = Array(repeating: 0.0, count: count)
                for row in 0 ..< count {
                    correlated[row] = (0 ... row).reduce(0) { $0 + factor[row][$1] * independent[$1] }
                }
                if let degrees = spec.studentTDegreesOfFreedom {
                    let validDegrees = max(3, degrees); var chiSquared = 0.0
                    for _ in 0 ..< validDegrees {
                        let normal = generator.normal(); chiSquared += normal * normal
                    }
                    let scale = sqrt(Double(validDegrees - 2) / chiSquared)
                    correlated = correlated.map { $0 * scale }
                }
                let portfolioReturn = (0 ..< count).reduce(0.0) {
                    $0 + weights[$1] * (spec.annualReturns[$1] / 12 + correlated[$1])
                }
                let contribution = spec.monthlyContribution * pow(1 + spec.annualContributionGrowth, Double((month - 1) / 12))
                value = max(0, value * (1 + portfolioReturn) + contribution); peak = max(peak, value)
                if peak > 0 {
                    maximumDrawdown = max(maximumDrawdown, (peak - value) / peak)
                }
                columns[month].append(value)
            }
            drawdowns.append(maximumDrawdown)
            if let target = spec.targetAmount {
                let inflated = target * pow(1 + spec.annualInflation, Double(months) / 12)
                if value >= inflated {
                    successes += 1
                }; shortfalls.append(max(0, inflated - value))
            }
        }
        let bands = columns.enumerated().map { month, values in
            let sorted = values.sorted()
            return ScenarioSimulationBand(month: month, p10: percentile(sorted, 0.10), p25: percentile(sorted, 0.25), p50: percentile(sorted, 0.50), p75: percentile(sorted, 0.75), p90: percentile(sorted, 0.90))
        }
        let positive = shortfalls.filter { $0 > 0 }
        return ScenarioSimulationOutput(
            bands: bands,
            goalProbability: spec.targetAmount == nil ? nil : Double(successes) / Double(paths),
            expectedShortfall: spec.targetAmount == nil ? nil : (positive.isEmpty ? 0 : positive.reduce(0, +) / Double(positive.count)),
            medianMaximumDrawdown: percentile(drawdowns.sorted(), 0.50)
        )
    }

    func repairedCovariance(_ matrix: [[Double]]) -> [[Double]] {
        guard !matrix.isEmpty, matrix.allSatisfy({ $0.count == matrix.count }) else { return matrix }
        var repaired = matrix
        for row in repaired.indices {
            for column in repaired.indices {
                let symmetric = (matrix[row][column] + matrix[column][row]) / 2
                repaired[row][column] = symmetric.isFinite ? symmetric : 0
            }
            repaired[row][row] = max(repaired[row][row], 1e-10)
        }
        var jitter = 1e-10
        while cholesky(repaired) == nil, jitter <= 1 {
            for index in repaired.indices {
                repaired[index][index] += jitter
            }
            jitter *= 10
        }
        return repaired
    }

    func cholesky(_ matrix: [[Double]]) -> [[Double]]? {
        guard !matrix.isEmpty, matrix.allSatisfy({ $0.count == matrix.count }) else { return nil }
        var result = Array(repeating: Array(repeating: 0.0, count: matrix.count), count: matrix.count)
        for row in matrix.indices {
            for column in 0 ... row {
                let prior = (0 ..< column).reduce(0.0) { $0 + result[row][$1] * result[column][$1] }
                if row == column {
                    let value = matrix[row][row] - prior
                    guard value > 0 else { return nil }
                    result[row][column] = sqrt(value)
                } else {
                    guard result[column][column] != 0 else { return nil }
                    result[row][column] = (matrix[row][column] - prior) / result[column][column]
                }
            }
        }
        return result
    }

    func simulate(_ spec: ScenarioSimulationSpec) -> ScenarioSimulationOutput {
        let pathCount = max(1, min(spec.pathCount, 50000))
        let months = max(1, min(spec.horizonMonths, 600))
        var generator = SplitMix64(seed: spec.seed)
        var columns = Array(repeating: [Double](), count: months + 1)
        for index in columns.indices {
            columns[index].reserveCapacity(pathCount)
        }
        var drawdowns = [Double](); drawdowns.reserveCapacity(pathCount)
        var successes = 0
        var shortfalls = [Double](); shortfalls.reserveCapacity(pathCount)

        for _ in 0 ..< pathCount {
            if Task.isCancelled {
                break
            }
            var value = spec.initialValue
            var peak = value
            var maximumDrawdown = 0.0
            var bootstrapIndex = 0
            var bootstrapBlock: [Double] = []
            columns[0].append(value)
            for month in 1 ... months {
                let monthlyReturn = sampledMonthlyReturn(
                    spec: spec, generator: &generator,
                    bootstrapIndex: &bootstrapIndex, bootstrapBlock: &bootstrapBlock
                )
                let contributionYear = Double((month - 1) / 12)
                let contribution = spec.monthlyContribution * pow(1 + spec.annualContributionGrowth, contributionYear)
                value = max(0, value * (1 + monthlyReturn) + contribution)
                peak = max(peak, value)
                if peak > 0 {
                    maximumDrawdown = max(maximumDrawdown, (peak - value) / peak)
                }
                columns[month].append(value)
            }
            drawdowns.append(maximumDrawdown)
            if let nominalTarget = spec.targetAmount {
                let inflatedTarget = nominalTarget * pow(1 + spec.annualInflation, Double(months) / 12)
                if value >= inflatedTarget {
                    successes += 1
                }
                shortfalls.append(max(0, inflatedTarget - value))
            }
        }

        let bands = columns.enumerated().map { month, values in
            let sorted = values.sorted()
            return ScenarioSimulationBand(
                month: month, p10: percentile(sorted, 0.10), p25: percentile(sorted, 0.25),
                p50: percentile(sorted, 0.50), p75: percentile(sorted, 0.75), p90: percentile(sorted, 0.90)
            )
        }
        let probability = spec.targetAmount == nil ? nil : Double(successes) / Double(pathCount)
        let positiveShortfalls = shortfalls.filter { $0 > 0 }
        let expectedShortfall = positiveShortfalls.isEmpty ? (spec.targetAmount == nil ? nil : 0) : positiveShortfalls.reduce(0, +) / Double(positiveShortfalls.count)
        return ScenarioSimulationOutput(
            bands: bands, goalProbability: probability, expectedShortfall: expectedShortfall,
            medianMaximumDrawdown: percentile(drawdowns.sorted(), 0.50)
        )
    }

    private func sampledMonthlyReturn(
        spec: ScenarioSimulationSpec, generator: inout SplitMix64,
        bootstrapIndex: inout Int, bootstrapBlock: inout [Double]
    ) -> Double {
        switch spec.distribution {
        case .normal:
            return spec.annualReturn / 12 + spec.annualVolatility / sqrt(12) * generator.normal()
        case let .studentT(degreesOfFreedom):
            let degrees = max(3, degreesOfFreedom)
            var chiSquared = 0.0
            for _ in 0 ..< degrees {
                let normal = generator.normal(); chiSquared += normal * normal
            }
            let student = generator.normal() / sqrt(chiSquared / Double(degrees))
            let varianceScale = sqrt(Double(degrees - 2) / Double(degrees))
            return spec.annualReturn / 12 + spec.annualVolatility / sqrt(12) * student * varianceScale
        case let .blockBootstrap(returns, blockMonths):
            guard !returns.isEmpty else { return spec.annualReturn / 12 }
            if bootstrapIndex >= bootstrapBlock.count {
                let length = max(1, min(blockMonths, returns.count))
                let start = Int(generator.next() % UInt64(returns.count))
                bootstrapBlock = (0 ..< length).map { returns[(start + $0) % returns.count] }
                bootstrapIndex = 0
            }
            defer { bootstrapIndex += 1 }
            return bootstrapBlock[bootstrapIndex]
        }
    }

    private func percentile(_ sorted: [Double], _ percentile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * percentile))]
    }
}

private struct SplitMix64 {
    private var state: UInt64
    private var spareNormal: Double?

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func uniform() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }

    mutating func normal() -> Double {
        if let spareNormal {
            self.spareNormal = nil; return spareNormal
        }
        let first = max(uniform(), Double.leastNonzeroMagnitude)
        let second = uniform()
        let radius = sqrt(-2 * log(first))
        let angle = 2 * Double.pi * second
        spareNormal = radius * sin(angle)
        return radius * cos(angle)
    }
}
