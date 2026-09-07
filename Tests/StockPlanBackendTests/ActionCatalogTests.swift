import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import VaporTesting

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
        // The point of the catalog: adding an action must reach every surface
        // without a second edit somewhere else. Checked under both confirmation
        // modes, because the persistent assistant and Telegram run deferred and
        // used to derive their tools from a hand-written list of five.
        for mode in Self.allModes {
            let assistantNames = Set(AIChatToolRegistry.toolDefinitions(mode: mode).map(\.function.name))
            for action in ActionCatalog.all {
                #expect(
                    assistantNames.contains(action.name),
                    "\(action.name) is in the catalog but not offered to the assistant under \(mode)"
                )
            }
        }
    }

    @Test("Portfolio and goal actions reach the deferred surface")
    func telegramReachesPortfolioActions() {
        // Before this the persistent assistant — the iOS app, web /assistant and
        // Telegram — could write expenses and goals and nothing else, while MCP
        // grew a full portfolio surface. The destructive names are listed
        // explicitly: reaching them is the requirement, guarded not withheld.
        let names = Set(
            AIChatToolRegistry
                .toolDefinitions(mode: .deferred(requiring: .destructiveOnly))
                .map(\.function.name)
        )
        for expected in [
            "upsert_watchlist_item", "remove_watchlist_item", "list_watchlist",
            "record_trade", "delete_trade", "list_transactions",
            "add_position", "sell_position", "delete_position",
            "list_goals", "add_goal", "update_goal", "delete_goal",
        ] {
            #expect(names.contains(expected), "deferred surface is missing \(expected)")
        }
    }

    // MARK: - Confirmation modes

    @Test("A model-supplied confirm never unlocks a destructive write on a deferred surface")
    func deferredIgnoresModelSuppliedConfirm() {
        // The one that matters. Telegram executes on a button tap, so "delete"
        // must never be one hop from a sentence — and a model that invents
        // `confirm: true` must not be the thing that closes that gap.
        for scope in [ConfirmationScope.destructiveOnly, .everyWrite] {
            for action in ActionCatalog.all where action.destructive {
                let disposition = ActionCatalog.disposition(
                    name: action.name,
                    arguments: ActionArguments(json: #"{"confirm": true, "id": "\#(UUID().uuidString)"}"#),
                    mode: .deferred(requiring: scope)
                )
                #expect(
                    Self.needsConfirmation(disposition),
                    "\(action.name) ran on a model-supplied confirm under \(scope)"
                )
            }
        }
    }

    @Test("The deferred schema does not advertise confirm")
    func deferredSchemaOmitsConfirm() {
        // Advertising it would let a model ask in prose and then pass it on the
        // next turn of the same request, which is the same one-hop deletion.
        for scope in [ConfirmationScope.destructiveOnly, .everyWrite] {
            for tool in ActionCatalog.toolDefinitions(mode: .deferred(requiring: scope)) {
                guard let action = ActionCatalog.definition(named: tool.function.name),
                      action.destructive else { continue }
                #expect(
                    tool.function.parameters.properties["confirm"] == nil,
                    "\(action.name) advertises confirm on a deferred surface"
                )
                #expect(!tool.function.parameters.required.contains("confirm"))
            }
        }
    }

    @Test("Inline mode still gates destructive actions on an in-call confirm")
    func inlineModeIsUnchanged() {
        // /v1/ai/chat and the published MCP schema both depend on this.
        for action in ActionCatalog.all where action.destructive {
            #expect(Self.needsConfirmation(ActionCatalog.disposition(
                name: action.name, arguments: ActionArguments([:]), mode: .inline
            )), "\(action.name) ran inline without a confirm")
            #expect(Self.runs(ActionCatalog.disposition(
                name: action.name,
                arguments: ActionArguments(["confirm": true]),
                mode: .inline
            )), "\(action.name) refused a legitimate inline confirm")
        }
    }

    @Test("everyWrite defers writes but never reads")
    func everyWriteDefersWritesOnly() {
        // This is what keeps a token holding only assistant:write from gaining
        // domain write power now that writes can apply inline. Tested as a pure
        // decision, with no token and no HTTP.
        let mode = ActionConfirmationMode.deferred(requiring: .everyWrite)
        for action in ActionCatalog.all {
            let disposition = ActionCatalog.disposition(
                name: action.name, arguments: ActionArguments([:]), mode: mode
            )
            if action.readOnly {
                #expect(Self.runs(disposition), "\(action.name) is a read but was deferred")
            } else {
                #expect(Self.needsConfirmation(disposition), "\(action.name) is a write but ran under everyWrite")
            }
        }
    }

    @Test("destructiveOnly applies harmless writes and defers the rest")
    func destructiveOnlyAppliesHarmlessWrites() {
        let mode = ActionConfirmationMode.deferred(requiring: .destructiveOnly)
        for action in ActionCatalog.all {
            let disposition = ActionCatalog.disposition(
                name: action.name, arguments: ActionArguments([:]), mode: mode
            )
            if action.destructive {
                #expect(Self.needsConfirmation(disposition), "\(action.name) was not deferred")
            } else {
                #expect(Self.runs(disposition), "\(action.name) was deferred but is not destructive")
            }
        }
    }

    @Test("Confirmed mode runs what a persisted row already approved")
    func confirmedModeRuns() {
        for action in ActionCatalog.all {
            #expect(Self.runs(ActionCatalog.disposition(
                name: action.name, arguments: ActionArguments([:]), mode: .confirmed
            )))
        }
    }

    @Test("An unknown name is unknown in every mode")
    func unknownIsUnknownEverywhere() {
        for mode in Self.allModes + [.confirmed] {
            let disposition = ActionCatalog.disposition(
                name: "drop_all_tables", arguments: ActionArguments([:]), mode: mode
            )
            if case .unknown = disposition {} else {
                Issue.record("drop_all_tables was not unknown under \(mode)")
            }
        }
    }

    // MARK: - Divergence guards

    @Test("Catalog and read-registry names do not collide")
    func readAndWriteNamesAreDisjoint() {
        // A duplicate function name in one tools array is a hard 400 from
        // OpenAI-compatible providers, so every turn would fail. The two lists
        // happen to be disjoint today; this makes it an invariant.
        let reads = Set(AIReadToolRegistry.toolDefinitions().map(\.function.name))
        let actions = Set(ActionCatalog.all.map(\.name))
        #expect(reads.isDisjoint(with: actions), "colliding names: \(reads.intersection(actions).sorted())")
    }

    @Test("Legacy assistant tool names still resolve")
    func legacyNamesResolve() {
        // Rows in ai_pending_actions created before the catalog reached this
        // surface still carry the old names. Argument shapes were identical, so
        // an alias is the whole migration.
        #expect(ActionCatalog.canonicalName(for: "create_expense") == "add_expense")
        #expect(ActionCatalog.canonicalName(for: "create_goal") == "add_goal")
        #expect(ActionCatalog.canonicalName(for: "add_expense") == "add_expense")
        for legacy in ["create_expense", "delete_expense", "create_goal", "update_goal", "delete_goal"] {
            let canonical = ActionCatalog.canonicalName(for: legacy)
            #expect(
                ActionCatalog.contains(canonical),
                "legacy \(legacy) maps to \(canonical), which is not in the catalog"
            )
        }
    }

    @Test("Every action has authored confirmation and completion copy")
    func everyActionHasCopy() {
        // The summary is the only thing a user reads before approving a
        // deletion, so a new action falling back to "Apply this change" is a
        // real defect, not a cosmetic one.
        for action in ActionCatalog.all {
            #expect(ActionCatalog.hasCopy(for: action.name), "\(action.name) has no authored summary/completion copy")
        }
    }

    @Test("A destructive summary names what it is about to touch")
    func destructiveSummariesIdentifyTheirTarget() {
        let id = UUID()
        for action in ActionCatalog.all where action.destructive {
            let summary = ActionCatalog.confirmationSummary(
                name: action.name,
                arguments: ActionArguments(["id": id.uuidString, "symbol": "AVGO"])
            )
            #expect(!summary.isEmpty)
            let namesTarget = summary.contains(String(id.uuidString.prefix(8))) || summary.contains("AVGO")
            #expect(namesTarget, "\(action.name) summary identifies nothing: \(summary)")
        }
    }

    // MARK: - Turn-level write budget

    @Test("A turn cannot apply unbounded writes")
    func writeBudgetIsBounded() {
        // get_insights feeds untrusted_data into the same loop, so without a
        // ceiling injected text could drive maxToolRounds worth of writes.
        #expect(AIAssistantTurnService.maxInlineWritesPerTurn > 0)
        #expect(AIAssistantTurnService.maxInlineWritesPerTurn <= 5)
        #expect(AIAssistantTurnService.isErrorPayload(AIAssistantTurnService.writeBudgetError))
    }

    @Test("A model-invented confirm is not stored on the proposal")
    func confirmIsStrippedBeforePersisting() {
        let stripped = AIAssistantTurnService.strippingConfirm(#"{"id":"abc","confirm":true}"#)
        #expect(!stripped.contains("confirm"))
        #expect(stripped.contains("abc"))
        // Untouched when there is nothing to strip.
        #expect(AIAssistantTurnService.strippingConfirm(#"{"id":"abc"}"#) == #"{"id":"abc"}"#)
    }

    @Test("Error payloads are recognised so a failed write is not audited as done")
    func errorPayloadDetection() {
        #expect(AIAssistantTurnService.isErrorPayload(ActionCatalog.errorPayload("nope")))
        #expect(!AIAssistantTurnService.isErrorPayload(ActionCatalog.statusPayload("deleted")))
    }

    // MARK: - Helpers

    private static let allModes: [ActionConfirmationMode] = [
        .inline,
        .deferred(requiring: .destructiveOnly),
        .deferred(requiring: .everyWrite),
    ]

    private static func needsConfirmation(_ disposition: ActionDisposition) -> Bool {
        if case .needsConfirmation = disposition {
            return true
        }
        return false
    }

    private static func runs(_ disposition: ActionDisposition) -> Bool {
        if case .run = disposition {
            return true
        }
        return false
    }

    @Test("An unknown action is refused rather than guessed at")
    func unknownActionIsRefused() {
        #expect(ActionCatalog.definition(named: "drop_all_tables") == nil)
        #expect(ActionCatalog.contains("add_position"))
    }

    // MARK: - Published catalog

    @Test("GET /v1/actions/catalog publishes every action with its schema", .databaseLocked)
    func catalogEndpointPublishesActions() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()

            let identifier = UUID().uuidString.prefix(8).lowercased()
            var token = ""
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(StockPlanBackend.AuthRegisterRequest(
                    username: "catalog_\(identifier)",
                    password: "Password123!",
                    confirmPassword: "Password123!",
                    email: "catalog_\(identifier)@example.com",
                    dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
                ))
            }, afterResponse: { res async throws in
                token = try res.content.decode(AuthResponse.self).token
            })

            try await app.testing().test(.GET, "v1/actions/catalog", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(ActionCatalogController.CatalogResponse.self)
                let published = Dictionary(uniqueKeysWithValues: body.actions.map { ($0.name, $0) })

                // Every catalog action is published, so the Go side can be diffed
                // against this rather than hand-maintained in parallel.
                for action in ActionCatalog.all {
                    #expect(published[action.name] != nil, "\(action.name) missing from the published catalog")
                }

                // Destructive actions publish their confirm requirement, so a
                // consumer can see the gate rather than infer it from the name.
                for action in ActionCatalog.all where action.destructive {
                    let entry = published[action.name]
                    #expect(entry?.destructive == true)
                    #expect(entry?.required.contains("confirm") == true)
                    #expect(entry?.properties["confirm"] != nil)
                }
            })

            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
