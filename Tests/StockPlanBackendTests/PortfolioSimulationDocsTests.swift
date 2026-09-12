@testable import StockPlanBackend
import Testing

@Suite("Portfolio Simulation Docs Tests")
struct PortfolioSimulationDocsTests {
    @Test("OpenAPI spec documents the portfolio simulation routes and schema")
    func simulationRoutesAreDocumented() throws {
        let body = try BundledOpenAPISpec.yamlString()
        // The spec is hand-maintained and these assertions are a whitelist rather than a
        // reflection of the router, so a new simulation route is only covered once named here.
        #expect(body.contains("/v1/portfolio/simulations:"))
        #expect(body.contains("/v1/portfolio/simulations/preview:"))
        #expect(body.contains("/v1/portfolio/simulations/{simulationId}:"))
        #expect(body.contains("/v1/portfolio/simulations/{simulationId}/compute:"))
        #expect(body.contains("PortfolioSimulationDocument:"))
        #expect(body.contains("operationId: listPortfolioSimulations"))
        #expect(body.contains("operationId: createPortfolioSimulation"))
        #expect(body.contains("operationId: updatePortfolioSimulation"))
        #expect(body.contains("operationId: deletePortfolioSimulation"))
        #expect(body.contains("operationId: computePortfolioSimulation"))
        #expect(body.contains("operationId: previewPortfolioSimulation"))
    }
}
