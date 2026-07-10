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
