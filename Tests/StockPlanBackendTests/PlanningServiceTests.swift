import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Planning service")
struct PlanningServiceTests {
    private let service = PlanningService(rules: RetirementRuleRegistry())

    private func need(
        currentAge: Int = 40,
        retirementAge: Int = 60,
        monthlyCostOfLifeToday: Double = 2800,
        monthlyOtherIncomeAtRetirement: Double = 0,
        housingEndsAtAge: Int? = nil
    ) -> RetirementNeedInput {
        RetirementNeedInput(
            currentAge: currentAge,
            retirementAge: retirementAge,
            longevityAge: 90,
            monthlyCostOfLifeToday: monthlyCostOfLifeToday,
            monthlyHousingToday: 900,
            housingEndsAtAge: housingEndsAtAge,
            monthlyOtherIncomeAtRetirement: monthlyOtherIncomeAtRetirement,
            expectedAnnualReturn: 0.07
        )
    }

    private func plan() -> ProjectionAssumptions {
        ProjectionAssumptions(initialAmount: 10000, monthlyContribution: 400,
                              annualReturnRate: 0.07, years: 20)
    }

    // MARK: Growth

    @Test
    func `a projection reports its sensitivity row and states its assumptions`() throws {
        let response = try service.projection(
            GrowthProjectionRequest(assumptions: plan())
        )

        #expect(response.sensitivity.count == 3)
        #expect(response.result.years.count == 21)
        #expect(response.assumptionNotes.isEmpty == false)
        #expect(response.assumptionNotes.contains { $0.contains("Projections, not advice") })
    }

    @Test
    func `custom sensitivity rates are honoured`() throws {
        let response = try service.projection(
            GrowthProjectionRequest(assumptions: plan(), sensitivityRates: [0.03, 0.11])
        )

        #expect(response.sensitivity.map(\.annualReturnRate) == [0.03, 0.11])
    }

    @Test
    func `rising contributions are called out in the assumptions`() throws {
        let assumptions = ProjectionAssumptions(initialAmount: 10000, monthlyContribution: 400,
                                                annualReturnRate: 0.07,
                                                annualContributionGrowthRate: 0.03, years: 20)
        let response = try service.projection(GrowthProjectionRequest(assumptions: assumptions))

        #expect(response.assumptionNotes.contains { $0.contains("rise 3%") })
    }

    @Test
    func `percentages read as whole numbers where they are whole`() throws {
        let response = try service.projection(GrowthProjectionRequest(assumptions: plan()))

        #expect(response.assumptionNotes.contains { $0.contains("7% a year") })
        #expect(response.assumptionNotes.contains { $0.contains("7.0%") } == false)
    }

    // MARK: Adapting to the Monte Carlo engine

    /// The planning screens are cost-of-life shaped; the Monte Carlo engine is salary shaped.
    /// This mapping is the seam, so it is worth pinning.
    @Test
    func `the monte carlo input carries the plan's balance and contributions`() {
        let input = PlanningService.retirementPlanInput(
            from: RetirementPlanningRequest(need: need(), plan: plan())
        )

        #expect(input.currentAge == 40)
        #expect(input.retirementAge == 60)
        #expect(input.longevityAge == 90)
        #expect(input.accounts.count == 1)
        #expect(input.accounts[0].currentBalance == 10000)
        #expect(input.accounts[0].employeeAnnualContribution == 4800)
        #expect(input.desiredAnnualSpending == 2800 * 12)
    }

    @Test
    func `other retirement income is netted off before the simulation sees it`() {
        let input = PlanningService.retirementPlanInput(
            from: RetirementPlanningRequest(
                need: need(monthlyOtherIncomeAtRetirement: 800),
                plan: plan()
            )
        )

        #expect(input.desiredAnnualSpending == (2800 - 800) * 12)
    }

    @Test
    func `volatility defaults to a sane figure and can be overridden`() {
        let standard = PlanningService.retirementPlanInput(
            from: RetirementPlanningRequest(need: need(), plan: plan())
        )
        let custom = PlanningService.retirementPlanInput(
            from: RetirementPlanningRequest(need: need(), plan: plan(), annualVolatility: 0.22)
        )

        #expect(standard.annualVolatility == 0.16)
        #expect(custom.annualVolatility == 0.22)
    }

    /// A cost of life below the pension covering it is not negative spending.
    @Test
    func `income larger than the cost of life floors spending at zero`() {
        let input = PlanningService.retirementPlanInput(
            from: RetirementPlanningRequest(
                need: need(monthlyCostOfLifeToday: 500, monthlyOtherIncomeAtRetirement: 900),
                plan: plan()
            )
        )

        #expect(input.desiredAnnualSpending == 0)
    }

    // MARK: Scenario storage shape

    @Test
    func `a scenario input round trips through its stored json`() throws {
        let input = PlanningScenarioInput(growth: plan(), retirement: need(housingEndsAtAge: 65))
        let data = try JSONEncoder.backendAPI.encode(input)
        let decoded = try JSONDecoder.backendAPI.decode(PlanningScenarioInput.self, from: data)

        #expect(decoded == input)
    }

    /// Scenario blobs are written by whatever version was deployed at the time, so a body that
    /// only carries one half must still decode.
    @Test
    func `a scenario blob missing the other half still decodes`() throws {
        let json = #"{"growth":{"initialAmount":1000,"monthlyContribution":100,"annualReturnRate":0.07,"annualContributionGrowthRate":0,"annualInflationRate":0.02,"years":10}}"#
        let decoded = try JSONDecoder.backendAPI.decode(PlanningScenarioInput.self, from: Data(json.utf8))

        #expect(decoded.growth != nil)
        #expect(decoded.retirement == nil)
    }

    // MARK: Wire compatibility

    /// `RetirementProjection.portfolioId` became optional so a projection can be user-scoped.
    /// Payloads written before that change still carry it, and must still decode.
    @Test
    func `a retirement projection decodes with or without a portfolio id`() throws {
        let summary = RetirementProjectionSummary(
            readinessProbability: 0.8,
            sustainableAnnualSpending: 40000,
            projectedAnnualRetirementIncome: 40000,
            annualContributionHeadroom: 0,
            shortfallAge: nil,
            medianValueAtRetirement: 1_000_000,
            medianValueAtLongevityAge: 500_000
        )
        let scoped = RetirementProjection(
            id: UUID().uuidString, portfolioId: UUID().uuidString, ruleVersion: "2026.1",
            currency: "EUR", summary: summary, points: [], assumptions: [], warnings: [],
            generatedAt: "2026-09-14T00:00:00Z"
        )
        let unscoped = RetirementProjection(
            id: UUID().uuidString, ruleVersion: "2026.1",
            currency: "EUR", summary: summary, points: [], assumptions: [], warnings: [],
            generatedAt: "2026-09-14T00:00:00Z"
        )

        let encoder = JSONEncoder.backendAPI
        let decoder = JSONDecoder.backendAPI
        let decodedScoped = try decoder.decode(RetirementProjection.self, from: encoder.encode(scoped))
        let decodedUnscoped = try decoder.decode(RetirementProjection.self, from: encoder.encode(unscoped))

        #expect(decodedScoped.portfolioId != nil)
        #expect(decodedUnscoped.portfolioId == nil)
    }

    // MARK: Pre-fill heuristics

    @Test(arguments: ["Rent", "monthly mortgage", "Renda de casa", "Hipoteca", "Miete"])
    func `housing titles are recognised across the languages Norviq serves`(_ title: String) {
        #expect(PlanningPrefillService.looksLikeHousing(title))
    }

    @Test(arguments: ["Groceries", "Netflix", "Gym", "Transport"])
    func `ordinary spending is not mistaken for housing`(_ title: String) {
        #expect(PlanningPrefillService.looksLikeHousing(title) == false)
    }
}
