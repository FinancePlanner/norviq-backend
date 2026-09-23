import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// Standing tasks and proactive messages against a real database: the
/// create_watch proposal and confirm, the watch job (due selection, append,
/// push, no double run), and the daily tip landing in the thread.
extension AIEnvironmentSuites {
    @Suite("Assistant standing tasks", .serialized)
    struct AIAssistantWatchTests {
        final class PushRecorder: PushNotificationSending, @unchecked Sendable {
            private let lock = NSLock()
            private var _messages: [AssistantPushMessage] = []
            var messages: [AssistantPushMessage] {
                lock.withLock { _messages }
            }

            func sendAssistantMessage(message: AssistantPushMessage, devices: [PushDevice], req _: Request) async -> TargetPushSendSummary {
                lock.withLock { _messages.append(message) }
                return .init(delivered: devices.count, failed: 0)
            }

            func sendTargetHit(target _: Target, currentPrice _: Double, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
                .init(delivered: 0, failed: 0)
            }

            func sendBudgetAlert(snapshot _: BudgetSnapshot, threshold _: Int, remainingAmount _: Double, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
                .init(delivered: 0, failed: 0)
            }

            func sendEarningsReminder(symbol _: String, earningsDate _: String, leadDays _: Int, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
                .init(delivered: 0, failed: 0)
            }

            func sendTaxOpportunity(opportunity _: TaxOpportunityResponse, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
                .init(delivered: 0, failed: 0)
            }

            func sendAutomationAlert(message _: AutomationPushMessage, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
                .init(delivered: 0, failed: 0)
            }

            func sendRebalancingDrift(alert _: RebalancingAlert, portfolioName _: String, devices _: [PushDevice], req _: Request) async -> TargetPushSendSummary {
                .init(delivered: 0, failed: 0)
            }
        }

        final class RunnerRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var _prompts: [String] = []
            let answer: String
            let delay: UInt64
            init(answer: String, delayNanoseconds: UInt64 = 0) {
                self.answer = answer; delay = delayNanoseconds
            }

            var prompts: [String] {
                lock.withLock { _prompts }
            }

            var runner: AIAssistantWatchJob.Runner {
                { _, _, prompt, _ in
                    self.lock.withLock { self._prompts.append(prompt) }
                    if self.delay > 0 {
                        try await Task.sleep(nanoseconds: self.delay)
                    }
                    return self.answer
                }
            }
        }

        private func withApp(_ test: (Application, PushRecorder) async throws -> Void) async throws {
            try await DatabaseTestLock.withLock {
                setenv("BYPASS_BILLING", "false", 1)
                let app = try await Application.make(.testing)
                do {
                    try await configure(app)
                    let recorder = PushRecorder()
                    app.pushNotificationSender = recorder
                    try await app.autoMigrate()
                    try await test(app, recorder)
                    try await app.autoRevert()
                } catch {
                    try? await app.autoRevert()
                    try await app.asyncShutdown()
                    throw error
                }
                try await app.asyncShutdown()
            }
        }

        private func registerUser(on app: Application, identifier: String) async throws -> AuthResponse {
            let request = AuthRegisterRequest(
                username: "watch_\(identifier)",
                password: "Password123!",
                confirmPassword: "Password123!",
                email: "watch+\(identifier)@example.com",
                dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
            )
            var response: AuthResponse?
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(request)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                response = try res.content.decode(AuthResponse.self)
            })
            return try #require(response)
        }

        private func makeConversation(on app: Application, userId: UUID) async throws -> AIConversation {
            let conversation = try AIConversation(
                userId: userId,
                titleEncrypted: app.userPIIEncryptionService.encryptString("Thread"),
                expiresAt: Date().addingTimeInterval(3600)
            )
            try await conversation.create(on: app.db)
            return conversation
        }

        private func seedWatch(
            on app: Application,
            userId: UUID,
            conversationId: UUID,
            nextRunAt: Date,
            condition: String? = nil,
            enabled: Bool = true
        ) async throws -> AIAssistantWatch {
            let crypto = app.userPIIEncryptionService
            let watch = AIAssistantWatch()
            watch.userId = userId
            watch.conversationId = conversationId
            watch.titleEncrypted = try crypto.encryptString("Watch NVDA")
            watch.specEncrypted = try crypto.encryptString("Watch NVDA and tell me when it drops below 100")
            watch.conditionEncrypted = try condition.map { try crypto.encryptString($0) }
            watch.scheduleHuman = "Every hour"
            watch.intervalMinutes = 60
            watch.nextRunAt = nextRunAt
            watch.enabled = enabled
            try await watch.create(on: app.db)
            return watch
        }

        private func messages(on app: Application, conversationId: UUID) async throws -> [AIAssistantMessage] {
            try await AIAssistantMessage.query(on: app.db)
                .filter(\.$conversation.$id == conversationId)
                .sort(\.$createdAt, .ascending).all()
        }

        @Test("Only due, enabled watches run; the answer is appended as a proactive message and pushed")
        func dueSelectionAppendAndPush() async throws {
            try await withApp { app, push in
                let user = try await registerUser(on: app, identifier: "due")
                let conversation = try await makeConversation(on: app, userId: user.userId)
                let conversationId = try conversation.requireID()
                let due = try await seedWatch(on: app, userId: user.userId, conversationId: conversationId,
                                              nextRunAt: Date().addingTimeInterval(-90 * 60))
                _ = try await seedWatch(on: app, userId: user.userId, conversationId: conversationId,
                                        nextRunAt: Date().addingTimeInterval(3600))
                _ = try await seedWatch(on: app, userId: user.userId, conversationId: conversationId,
                                        nextRunAt: Date().addingTimeInterval(-3600), enabled: false)

                let runner = RunnerRecorder(answer: "NVDA is at 131, up 2% today.")
                let summary = await AIAssistantWatchJob(runner: runner.runner).runOnce(app)
                #expect(summary.claimed == 1)
                #expect(summary.posted == 1)
                #expect(runner.prompts.count == 1)
                #expect(runner.prompts.first?.contains("Watch NVDA and tell me when it drops below 100") == true)

                let rows = try await messages(on: app, conversationId: conversationId)
                #expect(rows.count == 1)
                let message = try #require(rows.first)
                #expect(message.origin == "proactive")
                #expect(message.sourceLabel == "Standing task")
                #expect(try app.userPIIEncryptionService.decryptString(message.contentEncrypted) == "NVDA is at 131, up 2% today.")

                let pushed = try #require(push.messages.first)
                #expect(push.messages.count == 1)
                #expect(pushed.conversationId == conversationId)
                #expect(pushed.messageId == message.id)
                #expect(pushed.sourceLabel == "Standing task")
                #expect(pushed.deepLink == "financeplan://assistant/conversations/\(conversationId.uuidString)")

                // Advanced past now on its hourly anchor, not re-run.
                let reloaded = try #require(try await AIAssistantWatch.find(due.id, on: app.db))
                #expect(reloaded.nextRunAt > Date())
                #expect(reloaded.lastRunAt != nil)
                #expect(await AIAssistantWatchJob(runner: runner.runner).runOnce(app).claimed == 0)

                // The thread API shows the caption.
                try await app.testing().test(.GET, "v1/ai/assistant/conversations/\(conversationId)", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: user.token)
                }) { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(AIConversationResponse.self)
                    #expect(body.messages.first?.origin == .proactive)
                    #expect(body.messages.first?.sourceLabel == "Standing task")
                }
            }
        }

        @Test("Two replicas running at once claim each due watch exactly once")
        func noDoubleRun() async throws {
            try await withApp { app, push in
                let user = try await registerUser(on: app, identifier: "race")
                let conversation = try await makeConversation(on: app, userId: user.userId)
                let conversationId = try conversation.requireID()
                for _ in 0 ..< 3 {
                    _ = try await seedWatch(on: app, userId: user.userId, conversationId: conversationId,
                                            nextRunAt: Date().addingTimeInterval(-60))
                }
                let runner = RunnerRecorder(answer: "Update.", delayNanoseconds: 50_000_000)
                let jobA = AIAssistantWatchJob(runner: runner.runner)
                let jobB = AIAssistantWatchJob(runner: runner.runner)
                async let a = jobA.runOnce(app)
                async let b = jobB.runOnce(app)
                let (first, second) = await (a, b)
                #expect(first.claimed + second.claimed == 3)
                #expect(runner.prompts.count == 3)
                #expect(try await messages(on: app, conversationId: conversationId).count == 3)
                #expect(push.messages.count == 3)
            }
        }

        @Test("A conditional watch stays quiet on NO_UPDATE and switches off after it fires")
        func conditionalWatch() async throws {
            try await withApp { app, push in
                let user = try await registerUser(on: app, identifier: "cond")
                let conversation = try await makeConversation(on: app, userId: user.userId)
                let conversationId = try conversation.requireID()
                let watch = try await seedWatch(on: app, userId: user.userId, conversationId: conversationId,
                                                nextRunAt: Date().addingTimeInterval(-60), condition: "it drops below 100")

                let quiet = await AIAssistantWatchJob(runner: RunnerRecorder(answer: "NO_UPDATE").runner).runOnce(app)
                #expect(quiet.silent == 1)
                #expect(try await messages(on: app, conversationId: conversationId).isEmpty)
                #expect(push.messages.isEmpty)
                #expect(try await AIAssistantWatch.find(watch.id, on: app.db)?.enabled == true)

                let row = try #require(try await AIAssistantWatch.find(watch.id, on: app.db))
                row.nextRunAt = Date().addingTimeInterval(-60)
                try await row.save(on: app.db)
                let fired = await AIAssistantWatchJob(runner: RunnerRecorder(answer: "NVDA dropped to 98.").runner).runOnce(app)
                #expect(fired.posted == 1)
                #expect(try await AIAssistantWatch.find(watch.id, on: app.db)?.enabled == false)
                #expect(push.messages.count == 1)
            }
        }

        @Test("A standing-task request proposes create_watch; confirming creates it and posts the Standing task message")
        func proposeAndConfirm() async throws {
            try await withApp { app, _ in
                let user = try await registerUser(on: app, identifier: "confirm")
                let conversation = try await makeConversation(on: app, userId: user.userId)
                let conversationId = try conversation.requireID()

                var turn: AIAssistantTurnResponse?
                try await app.testing().test(.POST, "v1/ai/assistant/conversations/\(conversationId)/chat", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: user.token)
                    try req.content.encode(["content": "Watch NVDA and tell me when it drops below 100"])
                }) { res async throws in
                    #expect(res.status == .ok)
                    turn = try res.content.decode(AIAssistantTurnResponse.self)
                }
                let proposed = try #require(turn)
                #expect(proposed.kind == .confirmationRequired)
                #expect(proposed.message.origin == .reply)
                #expect(proposed.watchProposal == AIWatchProposalResponse(
                    title: "Watch NVDA", scheduleHuman: "Every hour", intervalMinutes: 60,
                    spec: "Watch NVDA and tell me when it drops below 100"
                ))
                let action = try #require(proposed.pendingAction)
                #expect(action.toolName == "create_watch")
                #expect(action.arguments.contains("\"scheduleHuman\":\"Every hour\""))

                var confirmed: AIConfirmedActionResponse?
                try await app.testing().test(.POST, "v1/ai/assistant/actions/\(action.id)/confirm", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: user.token)
                }) { res async throws in
                    #expect(res.status == .ok)
                    confirmed = try res.content.decode(AIConfirmedActionResponse.self)
                }
                let result = try #require(confirmed)
                #expect(result.message == "Got it — I'll watch NVDA and ping you when it drops below 100.")
                let watchId = try #require(result.resultId.flatMap(UUID.init(uuidString:)))
                let watch = try #require(try await AIAssistantWatch.find(watchId, on: app.db))
                #expect(watch.enabled)
                #expect(watch.intervalMinutes == 60)
                #expect(watch.conversationId == conversationId)
                #expect(watch.nextRunAt > Date())

                let rows = try await messages(on: app, conversationId: conversationId)
                #expect(rows.map(\.role) == ["user", "assistant", "assistant"])
                let last = try #require(rows.last)
                #expect(last.origin == "proactive")
                #expect(last.sourceLabel == "Standing task")

                // Replaying the confirm is refused.
                try await app.testing().test(.POST, "v1/ai/assistant/actions/\(action.id)/confirm", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: user.token)
                }) { res async in
                    #expect(res.status == .conflict)
                }
            }
        }

        @Test("A daily tip lands in the latest thread as a proactive message and pushes only when enabled")
        func dailyTipAppend() async throws {
            try await withApp { app, push in
                let user = try await registerUser(on: app, identifier: "tip")
                #expect(try await AIAssistantProactive.deliverDailyTip(title: "t", body: "b", userId: user.userId, app: app) == nil)

                let conversation = try await makeConversation(on: app, userId: user.userId)
                let conversationId = try conversation.requireID()
                let message = try #require(try await AIAssistantProactive.deliverDailyTip(
                    title: "Spending is ahead of pace", body: "You are 12% over plan for day 23.",
                    userId: user.userId, app: app
                ))
                #expect(message.$conversation.id == conversationId)
                #expect(message.origin == "proactive")
                #expect(message.sourceLabel == "Daily tip")
                #expect(try app.userPIIEncryptionService.decryptString(message.contentEncrypted)
                    == "**Spending is ahead of pace**\n\nYou are 12% over plan for day 23.")
                #expect(push.messages.isEmpty)

                let preference = AIAssistantPreference(userId: user.userId)
                preference.pushEnabled = true
                try await preference.create(on: app.db)
                _ = try await AIAssistantProactive.deliverDailyTip(title: "Again", body: "b", userId: user.userId, app: app)
                #expect(push.messages.count == 1)
                #expect(push.messages.first?.sourceLabel == "Daily tip")
                #expect(push.messages.first?.conversationId == conversationId)
            }
        }
    }
}
