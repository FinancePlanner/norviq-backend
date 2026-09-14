import StockPlanShared
import Vapor

extension ProjectionAssumptions: @retroactive Content {}
extension ProjectionYear: @retroactive Content {}
extension ProjectionResult: @retroactive Content {}
extension SensitivityPoint: @retroactive Content {}
extension CostOfLife: @retroactive Content {}
extension RetirementNeedInput: @retroactive Content {}
extension DepletionYear: @retroactive Content {}
extension RetirementNeed: @retroactive Content {}
extension PlanLever: @retroactive Content {}
extension GrowthProjectionRequest: @retroactive Content {}
extension GrowthProjectionResponse: @retroactive Content {}
extension PlanningPrefill: @retroactive Content {}
extension RetirementPlanningRequest: @retroactive Content {}
extension RetirementPlanningResponse: @retroactive Content {}
extension PlanningScenarioInput: @retroactive Content {}
extension PlanningScenario: @retroactive Content {}
extension PlanningScenarioUpsertRequest: @retroactive Content {}
