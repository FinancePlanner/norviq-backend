import Foundation
import StockPlanShared
import Vapor

/// One user-facing action, defined once.
///
/// Norviq exposes the same actions through three surfaces: the MCP server (Go,
/// over HTTP, authorised by scoped tokens), `/v1/ai/chat` (in-process,
/// first-party session), and the persistent assistant — the iOS app, web
/// `/assistant`, and the Telegram bot. Those had entirely separate tool lists,
/// so an action added to one silently did not exist on the other — which is why
/// Telegram could write expenses and nothing else while MCP grew a full
/// portfolio surface.
///
/// A definition carries its schema *and* its handler so the two cannot drift.
/// `GET /v1/actions/catalog` publishes the schemas, so the MCP side can be
/// checked against this list rather than hand-maintained in parallel.
///
/// ## Two confirmation models, one gate
///
/// The surfaces disagree about *when* consent arrives. `/v1/ai/chat` and MCP are
/// request-scoped: the model asks the user in prose and calls again with
/// `confirm: true` in the same conversation turn. The persistent assistant
/// cannot do that — it persists a proposal and the user answers in a *later*
/// message, or by tapping a button, possibly minutes later.
///
/// The reconciling idea is that **a persisted, status-checked `AIPendingAction`
/// *is* the deferred `confirm: true`**. It is the same gate, evaluated at a
/// different time by a different party. So the handlers know nothing about this;
/// only `ActionConfirmationMode` does, and it decides purely — see
/// ``ActionCatalog/disposition(name:arguments:mode:)``.
struct ActionDefinition: Sendable {
    let name: String
    let description: String
    let properties: [String: OpenAIParameter]
    let required: [String]
    /// Destructive actions must not fire on a single model turn. Under `.inline`
    /// the model must pass `confirm: true`; under `.deferred` they can only ever
    /// be *proposed*, and a human answer against a persisted row is what runs
    /// them. `confirm` is appended to their schema only in the inline shape.
    let destructive: Bool
    /// Reads live in `AIReadToolRegistry`, but a handful sit here because they
    /// return the ids the write actions need (you cannot `delete_trade` without
    /// `list_transactions`). Marking them lets `.everyWrite` defer every real
    /// write without also gating the lookups that make writes usable.
    let readOnly: Bool
    let handler: @Sendable (AIToolContext, ActionArguments, Request) async throws -> String

    init(
        _ name: String,
        _ description: String,
        properties: [String: OpenAIParameter] = [:],
        required: [String] = [],
        destructive: Bool = false,
        readOnly: Bool = false,
        handler: @escaping @Sendable (AIToolContext, ActionArguments, Request) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.properties = properties
        self.required = required
        self.destructive = destructive
        self.readOnly = readOnly
        self.handler = handler
    }
}

/// How the calling surface proves the user consented to a destructive action.
///
/// This is the single dial for the platform's write posture. Changing a surface
/// from "propose everything" to "apply the harmless ones immediately" is one
/// value here, not a change to tool derivation, dispatch, or the executor.
enum ActionConfirmationMode: Sendable, Equatable {
    /// Consent arrives in the same call. Destructive actions run only with
    /// `confirm: true`. Used by `/v1/ai/chat`, and the shape published to MCP.
    case inline
    /// Consent arrives out of band, later. Destructive actions *never* run here
    /// no matter what the model passed; the caller persists a proposal.
    case deferred(requiring: ConfirmationScope)
    /// The caller has already matched a persisted, status-checked row against a
    /// real human answer. Run it.
    ///
    /// This is an ungated entry point by construction. It is named explicitly so
    /// `grep` finds every call site; the only legitimate caller is
    /// ``AIConfirmedActionExecutor``.
    case confirmed
}

/// Which actions a deferred surface insists on confirming.
enum ConfirmationScope: Sendable, Equatable {
    /// Destructive actions are proposed; other writes apply immediately.
    case destructiveOnly
    /// Every write is proposed. Reads still run. Used for scoped bearer tokens,
    /// which must not gain domain write power from holding `assistant:write`.
    case everyWrite
}

/// The whole safety decision, as a value. Deliberately carries no side effect so
/// it can be unit-tested without a database or a `Request`.
enum ActionDisposition: Sendable {
    case unknown
    case run(ActionDefinition)
    case needsConfirmation(ActionDefinition)
}

enum ActionCatalog {
    /// Every write action, across every domain, plus the few reads that supply
    /// the ids writes need. Everything else read-only is in AIReadToolRegistry.
    static var all: [ActionDefinition] {
        expenseActions + watchlistActions + transactionActions + positionActions + goalActions
    }

    static func definition(named name: String) -> ActionDefinition? {
        all.first { $0.name == name }
    }

    static func contains(_ name: String) -> Bool {
        definition(named: name) != nil
    }

    /// Tool names that predate the catalog and were renamed on the way in.
    ///
    /// The persistent assistant used to hand-write its own proposal tools; rows
    /// in `ai_pending_actions` created before this change still carry those
    /// names. The argument shapes were identical, so an alias is sufficient and
    /// complete — no data migration, which would have raced the very rows it was
    /// trying to fix and rewritten `ai_action_audits` history to a name that was
    /// never proposed.
    ///
    /// Proposals expire in 15 minutes, so the exposure window is one deploy.
    /// Safe to delete after 2026-10-01.
    private static let legacyToolNames: [String: String] = [
        "create_expense": "add_expense",
        "create_goal": "add_goal",
    ]

    static func canonicalName(for name: String) -> String {
        legacyToolNames[name] ?? name
    }

    /// Schemas in the shape the model APIs expect.
    ///
    /// Under `.inline` a destructive action gains a required `confirm` flag, so
    /// refusing to act without it is expressible in the schema rather than only
    /// in prose. Under `.deferred` the flag is *omitted* — if it were advertised,
    /// a model could ask in prose and then pass `confirm: true` on the next turn
    /// of the same request, which on Telegram is one hop from a sentence to a
    /// deletion. On a deferred surface the only thing that runs a destructive
    /// action is a persisted row plus a human answer.
    static func toolDefinitions(mode: ActionConfirmationMode = .inline) -> [OpenAITool] {
        all.map { action in
            var properties = action.properties
            var required = action.required
            if action.destructive, mode == .inline {
                properties["confirm"] = OpenAIParameter(
                    type: "boolean",
                    description: "must be true to actually perform this; ask the user first"
                )
                required.append("confirm")
            }
            return OpenAITool(function: OpenAIFunctionDef(
                name: action.name,
                description: action.description,
                parameters: OpenAIJSONSchema(properties: properties, required: required)
            ))
        }
    }

    /// Decides whether an action may run, without running it.
    ///
    /// Pure: no database, no `Request`, no I/O. This is what makes the safety
    /// posture cheap to test exhaustively, and it is the only place the rules
    /// live.
    static func disposition(
        name: String,
        arguments: ActionArguments,
        mode: ActionConfirmationMode
    ) -> ActionDisposition {
        guard let action = definition(named: canonicalName(for: name)) else {
            return .unknown
        }
        switch mode {
        case .confirmed:
            return .run(action)
        case .inline:
            // The model supplies consent in-call.
            if action.destructive, arguments.bool("confirm") != true {
                return .needsConfirmation(action)
            }
            return .run(action)
        case let .deferred(scope):
            // `arguments` is deliberately not consulted: a model-supplied
            // confirm must never unlock a write on a deferred surface.
            if action.readOnly {
                return .run(action)
            }
            switch scope {
            case .destructiveOnly:
                return action.destructive ? .needsConfirmation(action) : .run(action)
            case .everyWrite:
                return .needsConfirmation(action)
            }
        }
    }

    static func execute(
        name: String,
        arguments: ActionArguments,
        context: AIToolContext,
        mode: ActionConfirmationMode = .inline,
        on req: Request
    ) async throws -> String {
        switch disposition(name: name, arguments: arguments, mode: mode) {
        case .unknown:
            return #"{"error":"unknown tool"}"#
        case .needsConfirmation:
            return #"{"status":"needs_confirmation","message":"Ask the user to confirm, then call again with confirm=true."}"#
        case let .run(action):
            do {
                return try await action.handler(context, arguments, req)
            } catch let abort as any AbortError {
                // The model reads this, so surface the reason rather than a stack.
                return errorPayload(abort.reason)
            } catch {
                req.logger.warning("action_failed name=\(name) error=\(error)")
                return errorPayload("That action could not be completed.")
            }
        }
    }

    // MARK: - Shared helpers

    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func errorPayload(_ message: String) -> String {
        (try? encode(["error": message])) ?? #"{"error":"unknown"}"#
    }

    static func statusPayload(_ status: String) -> String {
        (try? encode(["status": status])) ?? #"{"status":"ok"}"#
    }
}
