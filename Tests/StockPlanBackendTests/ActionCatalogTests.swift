import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Action catalog")
struct ActionCatalogTests {
    @Test("Action names are unique")
    func namesAreUnique() {
        let names = ActionCatalog.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test("Every destructive action requires an explicit confirm")
    func destructiveActionsRequireConfirm() {
        // A destructive action reachable in one model turn is the failure this
        // guards: Telegram executes on a button tap, so "delete" must never be
        // one hop from a sentence.
        for tool in ActionCatalog.toolDefinitions() {
            guard let action = ActionCatalog.definition(named: tool.function.name), action.destructive else {
                continue
            }
            #expect(
                tool.function.parameters.properties["confirm"] != nil,
                "\(action.name) is destructive but has no confirm in its schema"
            )
            #expect(
                tool.function.parameters.required.contains("confirm"),
                "\(action.name) is destructive but confirm is not required"
            )
        }
    }

    @Test("Deletes and sells are marked destructive")
    func riskyActionsAreMarkedDestructive() {
        // Catches a new action being added without the flag, which would let it
        // through on a single turn.
        for action in ActionCatalog.all {
            let risky = action.name.hasPrefix("delete_")
                || action.name.hasPrefix("remove_")
                || action.name.hasPrefix("sell_")
            if risky {
                #expect(action.destructive, "\(action.name) looks destructive but is not flagged")
            }
        }
    }

    @Test("Every action declares its required fields in its own schema")
    func requiredFieldsExist() {
        for action in ActionCatalog.all {
            for field in action.required {
                #expect(
                    action.properties[field] != nil,
                    "\(action.name) requires '\(field)' but does not declare it"
                )
            }
        }
    }

    @Test("The assistant surface exposes the catalog, not a hand-maintained copy")
    func assistantSurfaceMatchesCatalog() {
        // The point of the catalog: adding an action must reach the assistant
        // (and therefore Telegram) without a second edit somewhere else.
        let assistantNames = Set(AIChatToolRegistry.toolDefinitions().map(\.function.name))
        for action in ActionCatalog.all {
            #expect(
                assistantNames.contains(action.name),
                "\(action.name) is in the catalog but not offered to the assistant"
            )
        }
    }

    @Test("Portfolio write actions reach the assistant")
    func telegramReachesPortfolioActions() {
        // Before the catalog the assistant could only write expenses, so this is
        // the regression that matters for Telegram.
        let names = Set(AIChatToolRegistry.toolDefinitions().map(\.function.name))
        for expected in [
            "upsert_watchlist_item", "remove_watchlist_item", "list_watchlist",
            "record_trade", "delete_trade", "list_transactions",
            "add_position", "sell_position", "delete_position",
        ] {
            #expect(names.contains(expected), "assistant is missing \(expected)")
        }
    }

    @Test("An unknown action is refused rather than guessed at")
    func unknownActionIsRefused() {
        #expect(ActionCatalog.definition(named: "drop_all_tables") == nil)
        #expect(ActionCatalog.contains("add_position"))
    }
}
