import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("Terminal position actions", .serialized)
struct TerminalPositionActionsTests {
    @Test("set_terminal_scenario always needs confirmation; reads run")
    func confirmation() {
        let args = ActionArguments(["ticker": "AMZN", "valueWanted": 1_000_000])
        for mode in [ActionConfirmationMode.inline, .deferred(requiring: .destructiveOnly), .deferred(requiring: .everyWrite)] {
            guard case .needsConfirmation = ActionCatalog.disposition(name: "set_terminal_scenario", arguments: args, mode: mode) else {
                Issue.record("set_terminal_scenario ran without confirmation in \(mode)")
                continue
            }
        }
        guard case .run = ActionCatalog.disposition(name: "get_terminal_positions", arguments: ActionArguments([:]), mode: .deferred(requiring: .everyWrite)) else {
            Issue.record("get_terminal_positions should run")
            return
        }
    }

    @Test("The confirmation summary names the ticker and the values")
    func summary() {
        let summary = ActionCatalog.confirmationSummary(
            name: "set_terminal_scenario",
            arguments: ActionArguments(["ticker": "amzn", "terminalMarketCap": 10_000_000_000_000, "valueWanted": 1_000_000])
        )
        #expect(summary.contains("AMZN"))
        #expect(summary.contains("10000000000000"))
        #expect(ActionCatalog.hasCopy(for: "lookup_share_facts"))
    }

    @Test("Handlers: incomplete create is an error payload; complete create and read work")
    func handlers() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let req = Request(application: app, on: app.eventLoopGroup.next())
            let context = AIToolContext(userId: user.userId)
            let set = try #require(ActionCatalog.definition(named: "set_terminal_scenario"))
            let incomplete = try await set.handler(context, ActionArguments(["ticker": "SOFI", "valueWanted": 250_000]), req)
            #expect(incomplete.contains("\"error\""))

            let created = try await set.handler(context, ActionArguments([
                "ticker": "SOFI", "terminalShareCount": 1_750_000_000, "terminalMarketCap": 150_000_000_000, "valueWanted": 250_000,
            ]), req)
            #expect(created.contains("\"ticker\":\"SOFI\""))

            let get = try #require(ActionCatalog.definition(named: "get_terminal_position"))
            let read = try await get.handler(context, ActionArguments(["ticker": "sofi"]), req)
            #expect(read.contains("sharesNeeded"))
            let none = try await get.handler(context, ActionArguments(["ticker": "NVDA"]), req)
            #expect(none.contains("none"))
        }
    }
}
