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
        if jurisdiction == .germany {
            // InvStG partial exemptions require fund classification metadata that is
            // not currently present in imported instruments.
            return normalized == "etf" ? .professionalReview : .estimateOnly
        }
        // Portugal is evidence-backed for FIFO and headline-rate estimates, but remains
        // estimate-only until annual Category G aggregation elections and carried losses
        // are represented explicitly in the profile contract.
        if jurisdiction == .portugal {
            return .estimateOnly
        }
        return isValidated ? .supported : .estimateOnly
    }

    func rate(isLongTerm: Bool, profile: TaxProfileRequest) -> Decimal? {
        if jurisdiction == .unitedStates {
            return isLongTerm ? profile.longTermCapitalGainsRate : profile.shortTermCapitalGainsRate
        }
        if jurisdiction == .portugal {
            // CIRS Article 72(1)(c): autonomous 28% rate on the positive securities balance.
            // Article 72(14) mandates aggregation for assets held under 365 days when
            // taxable income, including that balance, reaches the final Article 68 band.
            let topBandThreshold2026: Decimal = 86634
            if profile.capitalGainsTaxationMode == .aggregateWithIncome {
                return profile.marginalIncomeTaxRate
            }
            if !isLongTerm, profile.estimatedTaxableIncome >= topBandThreshold2026 {
                return profile.marginalIncomeTaxRate
            }
            return 0.28
        }
        if jurisdiction == .germany {
            // EStG section 32d: 25%; SolzG section 4: 5.5% of that tax.
            // Church tax is excluded until denomination and state are collected.
            return 0.26375
        }
        return profile.marginalIncomeTaxRate
    }

    func assumptions(taxYear: Int) -> [String] {
        var values = ["Rule pack \(jurisdiction.rawValue) \(ruleVersion) was used for tax year \(taxYear)."]
        if jurisdiction == .portugal {
            values.append("Portuguese securities are matched FIFO within each imported account or custodian under CIRS Article 43(8)(d) and (9).")
            values.append("The estimate applies the 28% autonomous rate, or the entered marginal rate for sub-365-day holdings above the 2026 mandatory-aggregation threshold of EUR 86,634.")
            values.append("Annual Category G netting and eligible five-year carried losses are calculated from imported disposals; incomplete broker history requires professional review.")
        }
        if jurisdiction == .germany {
            values.append("German fungible securities are matched FIFO within each imported brokerage account or depot under EStG Article 20(4).")
            values.append("The estimate applies 25% investment-income tax plus the 5.5% solidarity surcharge on that tax, for a combined 26.375% rate.")
            values.append("Stock-disposal losses are isolated from other capital income and carried forward separately under EStG Article 20(6).")
            values.append("The saver allowance is not deducted because complete capital income across financial institutions is unavailable.")
        }
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
            let version = switch jurisdiction {
            case .portugal: "PT-2026.2"
            case .germany: "DE-2026.1"
            default: "\(jurisdiction.rawValue)-2026.1"
            }
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
        if pack.jurisdiction == .portugal {
            values.append("FIFO is applied separately per imported account or custodian.")
            values.append("Annual Category G balance netting depends on complete disposal history from every custodian.")
            values.append("Five-year securities-loss carryforward is applied only when aggregation is elected or mandatory.")
        }
        if pack.jurisdiction == .germany {
            values.append("FIFO is applied separately per imported brokerage account or depot.")
            values.append("Church tax, foreign-tax credits, pre-2009 holdings, substantial shareholdings, business assets, and non-resident cases require professional review.")
            if ["etf", "fund"].contains(instrumentType.lowercased()) {
                values.append("Fund partial exemptions require investment-fund classification metadata and are not estimated by this rule version.")
            }
        }
        if !pack.isValidated {
            values.append("Professional validation required before actionable recommendations are enabled.")
        }
        if !["stock", "equity", "etf"].contains(instrumentType.lowercased()) {
            values.append("Imported and reported, but specialized optimization is not enabled in this rule version.")
        }
        return values
    }
}
