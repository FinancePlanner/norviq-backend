import Foundation
import StockPlanShared

struct RetirementRuleRegistry: Sendable {
    static let currentVersion = "2026.1"

    func rulePack(jurisdiction: TaxJurisdiction, version: String? = nil) -> RetirementRulePack? {
        guard version == nil || version == Self.currentVersion else { return nil }
        return RetirementRulePack(
            jurisdiction: jurisdiction,
            version: Self.currentVersion,
            effectiveFrom: "2026-01-01",
            currency: currency(jurisdiction),
            wrappers: wrappers(jurisdiction),
            sources: sources(jurisdiction),
            disclaimer: "Educational planning assumptions only. Verify eligibility, limits, and tax treatment with the official source and a qualified adviser before acting."
        )
    }

    private func currency(_ jurisdiction: TaxJurisdiction) -> String {
        jurisdiction == .unitedStates ? "USD" : "EUR"
    }

    private func wrappers(_ jurisdiction: TaxJurisdiction) -> [RetirementWrapperRule] {
        switch jurisdiction {
        case .unitedStates:
            [
                .init(
                    wrapper: .us401k,
                    maximumEmployeeAnnualContribution: 24500,
                    maximumTotalAnnualContribution: 72000,
                    minimumWithdrawalAge: 59,
                    earlyWithdrawalPenaltyRate: 0.10,
                    contributionTaxDeductible: true,
                    withdrawalsTaxable: true,
                    notes: ["2026 base limits; catch-up limits depend on age and plan terms."]
                ),
                .init(
                    wrapper: .us403b,
                    maximumEmployeeAnnualContribution: 24500,
                    maximumTotalAnnualContribution: 72000,
                    minimumWithdrawalAge: 59,
                    earlyWithdrawalPenaltyRate: 0.10,
                    contributionTaxDeductible: true,
                    withdrawalsTaxable: true
                ),
                .init(
                    wrapper: .traditionalIRA,
                    maximumEmployeeAnnualContribution: 7500,
                    minimumWithdrawalAge: 59,
                    earlyWithdrawalPenaltyRate: 0.10,
                    contributionTaxDeductible: true,
                    withdrawalsTaxable: true,
                    notes: ["Traditional and Roth IRA contributions share one annual limit; deductibility and Roth eligibility depend on income."]
                ),
                .init(
                    wrapper: .rothIRA,
                    maximumEmployeeAnnualContribution: 7500,
                    minimumWithdrawalAge: 59,
                    earlyWithdrawalPenaltyRate: 0.10,
                    contributionTaxDeductible: false,
                    withdrawalsTaxable: false,
                    notes: ["Qualified distribution rules and income limits apply."]
                ),
            ]
        case .portugal:
            [
                .init(
                    wrapper: .portugalPPR,
                    contributionTaxDeductible: false,
                    withdrawalsTaxable: true,
                    notes: ["PPR contributions may qualify for an age-based 20% tax credit; early reimbursement rules can recapture benefits."]
                ),
                .init(
                    wrapper: .portugalOccupationalPension,
                    contributionTaxDeductible: true,
                    withdrawalsTaxable: true,
                    notes: ["Employer plan terms and individual tax circumstances determine limits."]
                ),
            ]
        case .spain:
            [
                .init(
                    wrapper: .spainIndividualPension,
                    maximumEmployeeAnnualContribution: 1500,
                    contributionTaxDeductible: true,
                    withdrawalsTaxable: true,
                    notes: ["The reduction is also limited by a percentage of qualifying earned income."]
                ),
                .init(
                    wrapper: .spainEmploymentPension,
                    maximumTotalAnnualContribution: 10000,
                    contributionTaxDeductible: true,
                    withdrawalsTaxable: true,
                    notes: ["The general limit can increase by up to EUR 8,500 for qualifying employment contributions."]
                ),
            ]
        case .germany:
            [
                .init(
                    wrapper: .germanyRiester,
                    contributionTaxDeductible: true,
                    withdrawalsTaxable: true,
                    notes: ["Eligibility, allowances, and the optimal contribution depend on household circumstances."]
                ),
                .init(
                    wrapper: .germanyRurup,
                    contributionTaxDeductible: true,
                    withdrawalsTaxable: true,
                    notes: ["The deductible Basisrente ceiling is indexed; use the taxpayer-specific official assessment."]
                ),
                .init(
                    wrapper: .germanyOccupationalPension,
                    contributionTaxDeductible: true,
                    withdrawalsTaxable: true,
                    notes: ["Employer and social-insurance rules vary by arrangement."]
                ),
            ]
        case .france:
            [
                .init(
                    wrapper: .francePERIndividual,
                    minimumContributionAge: 18,
                    contributionTaxDeductible: true,
                    withdrawalsTaxable: true,
                    notes: ["The personalized deduction ceiling is income-based and may include unused ceiling from prior years."]
                ),
                .init(
                    wrapper: .francePERCompany,
                    minimumContributionAge: 18,
                    contributionTaxDeductible: true,
                    withdrawalsTaxable: true,
                    notes: ["Employer contributions reduce the personalized voluntary-contribution deduction ceiling."]
                ),
            ]
        case .italy:
            [
                .init(
                    wrapper: .italyComplementaryFund,
                    maximumTotalAnnualContribution: 5164.57,
                    contributionTaxDeductible: true,
                    withdrawalsTaxable: true,
                    notes: ["The standard deduction ceiling includes employer and employee contributions, subject to statutory exceptions."]
                ),
                .init(
                    wrapper: .italyPIP,
                    maximumTotalAnnualContribution: 5164.57,
                    contributionTaxDeductible: true,
                    withdrawalsTaxable: true
                ),
            ]
        }
    }

    private func sources(_ jurisdiction: TaxJurisdiction) -> [RetirementRuleSource] {
        let reviewedAt = "2026-07-13"
        switch jurisdiction {
        case .unitedStates:
            return [
                .init(
                    title: "IRS 401(k) and profit-sharing contribution limits",
                    url: "https://www.irs.gov/retirement-plans/plan-participant-employee/retirement-topics-401k-and-profit-sharing-plan-contribution-limits",
                    reviewedAt: reviewedAt
                ),
                .init(
                    title: "IRS IRA contribution limits",
                    url: "https://www.irs.gov/retirement-plans/plan-participant-employee/retirement-topics-ira-contribution-limits",
                    reviewedAt: reviewedAt
                ),
            ]
        case .portugal:
            return [.init(
                title: "Autoridade Tributaria - deductions and PPR tax benefits",
                url: "https://info.portaldasfinancas.gov.pt/pt/apoio_ao_contribuinte/Cidadaos/Rendimentos/Declaracao/Deducoes_beneficios_taxas/Paginas/default.aspx",
                reviewedAt: reviewedAt
            )]
        case .spain:
            return [.init(
                title: "Agencia Tributaria - pension contribution and reduction limits",
                url: "https://sede.agenciatributaria.gob.es/Sede/ayuda/manuales-videos-folletos/manuales-ayuda-presentacion/irpf-2025/8-cumplimentacion-irpf/8_2-base-liquidable-general-base-ahorro/8_2_2-reducciones-aportaciones-prevision-social/8_2_2_6-aportaciones-anuales-maximas-limite-reduccion.html",
                reviewedAt: reviewedAt
            )]
        case .germany:
            return [.init(
                title: "Bundesfinanzministerium - pension taxation overview",
                url: "https://www.bundesfinanzministerium.de/Content/DE/Standardartikel/Themen/Steuern/Steuerliche_Themengebiete/Rentenbesteuerung/2021-04-28-Rentenbesteuerung-Eine-Frage-der-Gerechtigkeit.html",
                reviewedAt: reviewedAt
            )]
        case .france:
            return [.init(
                title: "Service-Public.fr - individual PER",
                url: "https://www.service-public.fr/particuliers/vosdroits/F36526/0?idFicheParent=F34982",
                reviewedAt: reviewedAt
            )]
        case .italy:
            return [.init(
                title: "COVIP - complementary pension tax rules",
                url: "https://www.covip.it/sites/default/files/discipline_fiscali/risposta_n._76_2024.pdf",
                reviewedAt: reviewedAt
            )]
        }
    }
}
