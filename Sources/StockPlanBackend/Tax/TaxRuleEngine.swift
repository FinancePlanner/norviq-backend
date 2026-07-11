import Foundation
import StockPlanShared

struct TaxRuleContext: Sendable {
    let profile: TaxProfileRequest
    let ruleVersion: String
}

protocol TaxRulePack: Sendable {
    var jurisdiction: TaxJurisdiction { get }
    var ruleVersion: String { get }
    var isValidated: Bool { get }

    func supportLevel(instrumentType: String, wrapper: TaxAccountWrapper) -> TaxSupportLevel
    func rate(isLongTerm: Bool, profile: TaxProfileRequest) -> Decimal?
    func assumptions(taxYear: Int) -> [String]
}

struct ConfiguredTaxRulePack: TaxRulePack {
    let jurisdiction: TaxJurisdiction
    let ruleVersion: String
    let isValidated: Bool

    func supportLevel(instrumentType: String, wrapper: TaxAccountWrapper) -> TaxSupportLevel {
        guard wrapper == .taxable else { return .professionalReview }
        let normalized = instrumentType.lowercased()
        guard ["stock", "equity", "etf"].contains(normalized) else {
            return .professionalReview
        }
        return isValidated ? .supported : .estimateOnly
    }

    func rate(isLongTerm: Bool, profile: TaxProfileRequest) -> Decimal? {
        if jurisdiction == .unitedStates {
            return isLongTerm ? profile.longTermCapitalGainsRate : profile.shortTermCapitalGainsRate
        }
        return profile.marginalIncomeTaxRate
    }

    func assumptions(taxYear: Int) -> [String] {
        var values = ["Rule pack \(jurisdiction.rawValue) \(ruleVersion) was used for tax year \(taxYear)."]
        if !isValidated {
            values.append("This rule pack has not been enabled for actionable recommendations; results are estimates for review.")
        }
        values.append("Future-year projections use enacted rules when configured and otherwise carry forward the latest configured rates.")
        return values
    }
}

struct TaxRuleRegistry: Sendable {
    private let packs: [TaxJurisdiction: ConfiguredTaxRulePack]

    init(validatedJurisdictions: Set<TaxJurisdiction>) {
        packs = Dictionary(uniqueKeysWithValues: TaxJurisdiction.allCases.map { jurisdiction in
            let version = "\(jurisdiction.rawValue)-2026.1"
            return (jurisdiction, ConfiguredTaxRulePack(
                jurisdiction: jurisdiction,
                ruleVersion: version,
                isValidated: validatedJurisdictions.contains(jurisdiction)
            ))
        })
    }

    func pack(for jurisdiction: TaxJurisdiction) -> ConfiguredTaxRulePack {
        packs[jurisdiction]!
    }

    func capabilities(taxYear: Int) -> [TaxRuleCapability] {
        let wrappers = TaxAccountWrapper.allCases
        let types = ["stock", "etf", "option", "future", "bond", "fund", "crypto", "other"]
        return TaxJurisdiction.allCases.flatMap { jurisdiction in
            let pack = pack(for: jurisdiction)
            return types.map { instrumentType in
                TaxRuleCapability(
                    jurisdiction: jurisdiction,
                    taxYear: taxYear,
                    ruleVersion: pack.ruleVersion,
                    instrumentType: instrumentType,
                    supportLevel: pack.supportLevel(instrumentType: instrumentType, wrapper: .taxable),
                    supportedAccountWrappers: wrappers.filter {
                        pack.supportLevel(instrumentType: instrumentType, wrapper: $0) != .unsupported
                    },
                    limitations: limitations(pack: pack, instrumentType: instrumentType)
                )
            }
        }
    }

    private func limitations(pack: ConfiguredTaxRulePack, instrumentType: String) -> [String] {
        var values = [String]()
        if !pack.isValidated {
            values.append("Professional validation required before actionable recommendations are enabled.")
        }
        if !["stock", "equity", "etf"].contains(instrumentType.lowercased()) {
            values.append("Imported and reported, but specialized optimization is not enabled in this rule version.")
        }
        return values
    }
}
