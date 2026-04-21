import StockPlanShared
import Vapor

struct BillingErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let error as BillingUpgradeRequiredError {
            let response = Response(status: error.status)
            try response.content.encode(
                BillingUpgradeRequiredResponse(
                    success: false,
                    code: "upgrade_required",
                    error: error.reason,
                    feature: error.feature.rawValue,
                    plan: error.plan,
                    requiredPlan: error.requiredPlan,
                    limit: error.limit,
                    current: error.current
                )
            )
            return response
        }
    }
}
