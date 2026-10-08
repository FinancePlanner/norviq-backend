import Foundation
import NIOConcurrencyHelpers
@testable import StockPlanBackend
import Testing
import Vapor

/// Records which model a rung was asked to run, so the tests can assert on the
/// slug that actually served a turn rather than on the tier list alone.
private final class ModelRecorder: @unchecked Sendable {
    private let lock = NIOLock()
    private var value: [String] = []

    func record(_ model: String) {
        lock.withLock { value.append(model) }
    }

    var seen: [String] {
        lock.withLock { value }
    }
}

private struct RecordingChatClient: OpenAIChatClient {
    let model: String
    let recorder: ModelRecorder

    func chat(
        messages _: [OpenAIMessage],
        tools _: [OpenAITool],
        responseFormat _: String?,
        on _: Request
    ) async throws -> OpenAIMessage {
        recorder.record(model)
        return OpenAIMessage(role: "assistant", content: model)
    }
}

extension AIEnvironmentSuites {
    @Suite("AI model router", .serialized)
    struct AIModelRouterTests {
        private func clearEnv() {
            for key in [
                "AI_PROVIDER", "AI_MODEL", "AI_API_KEY", "AI_MAX_TOKENS",
                "AI_FALLBACK_ENABLED", "AI_FALLBACK_PROVIDERS",
                "AI_FREE_PROVIDERS", "AI_PRO_FALLBACK_PROVIDERS",
                "AI_PLAN_ROUTING_ENABLED",
                "AI_FALLBACK_OPENROUTER_API_KEY", "AI_FALLBACK_OPENAI_API_KEY",
                "OPENROUTER_API_KEY", "OPENAI_API_KEY",
                "ANTHROPIC_API_KEY", "ANTHROPIC_FIRST", "ANTHROPIC_MODEL", "ANTHROPIC_EFFORT",
                "ANTHROPIC_THINKING", "ANTHROPIC_SCOPE", "ANTHROPIC_MAX_TOKENS", "ANTHROPIC_BASE_URL",
            ] {
                unsetenv(key)
            }
        }

        /// The deployed production shape: OpenRouter, a paid primary, a free floor.
        private func setProductionLikeEnv() {
            setenv("AI_PROVIDER", "openrouter", 1)
            setenv("OPENROUTER_API_KEY", "sk-or-test", 1)
            setenv("AI_MODEL", "deepseek/deepseek-v4-flash", 1)
        }

        private func withRequest(_ test: (Request) async throws -> Void) async throws {
            let app = try await Application.make(.testing)
            do {
                let req = Request(application: app, on: app.eventLoopGroup.next())
                try await test(req)
            } catch {
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }

        // MARK: - The money guard

        @Test("A metered slug in the free list is dropped rather than billed to a free user")
        func meteredSlugInFreeListIsDropped() {
            defer { clearEnv() }
            clearEnv()
            setProductionLikeEnv()
            setenv(
                "AI_FREE_PROVIDERS",
                "openrouter|nvidia/nemotron-3-ultra-550b-a55b:free,openrouter|anthropic/claude-sonnet-4.6",
                1
            )

            let free = AIProviderConfiguration.loadFreeTiers(maxTokens: 700)

            #expect(free.map(\.model) == ["nvidia/nemotron-3-ultra-550b-a55b:free"])
            #expect(!free.contains { $0.model == "anthropic/claude-sonnet-4.6" })
        }

        @Test("A free list of nothing but metered slugs falls back to the built-in free defaults")
        func fullyMeteredFreeListFallsBackToDefaults() {
            defer { clearEnv() }
            clearEnv()
            setProductionLikeEnv()
            setenv("AI_FREE_PROVIDERS", "openrouter|deepseek/deepseek-v4-flash,openai|gpt-5.6-luna", 1)

            let free = AIProviderConfiguration.loadFreeTiers(maxTokens: 700)

            #expect(free.map(\.model) == AIProviderConfiguration.defaultFallbackModels)
        }

        @Test("Only :free-suffixed slugs and the free auto-router count as free")
        func freeSlugClassification() {
            #expect(AIProviderConfiguration.isFreeModelSlug("nvidia/nemotron-3-ultra-550b-a55b:free"))
            #expect(AIProviderConfiguration.isFreeModelSlug("z-ai/glm-5.2:FREE"))
            #expect(AIProviderConfiguration.isFreeModelSlug("openrouter/free"))
            #expect(!AIProviderConfiguration.isFreeModelSlug("deepseek/deepseek-v4-flash"))
            #expect(!AIProviderConfiguration.isFreeModelSlug("anthropic/claude-sonnet-4.6"))
            // `:free` must be the suffix, not merely present.
            #expect(!AIProviderConfiguration.isFreeModelSlug("vendor/model:free-preview"))
        }

        // MARK: - Free chain composition

        @Test("The free chain keeps the configured order and carries the OpenRouter key")
        func freeChainOrderAndCredentials() {
            defer { clearEnv() }
            clearEnv()
            setProductionLikeEnv()
            setenv(
                "AI_FREE_PROVIDERS",
                "openrouter|nvidia/nemotron-3-super-120b-a12b:free, openrouter|z-ai/glm-5.2:free",
                1
            )

            let free = AIProviderConfiguration.loadFreeTiers(maxTokens: 1200)

            #expect(free.map(\.model) == [
                "nvidia/nemotron-3-super-120b-a12b:free",
                "z-ai/glm-5.2:free",
            ])
            #expect(Set(free.map(\.apiKey)) == ["sk-or-test"])
            #expect(Set(free.map(\.baseURL)) == ["https://openrouter.ai/api/v1"])
            #expect(Set(free.map(\.maxTokens)) == [1200])
            // Hoisted out of the macro: `allSatisfy` rethrows, which #expect cannot absorb.
            let allUsable = free.allSatisfy(\.isUsable)
            #expect(allUsable)
        }

        @Test("With no free list at all the built-in free defaults are used")
        func freeChainDefaults() {
            defer { clearEnv() }
            clearEnv()
            setProductionLikeEnv()

            #expect(
                AIProviderConfiguration.loadFreeTiers(maxTokens: 700).map(\.model)
                    == AIProviderConfiguration.defaultFallbackModels
            )
        }

        @Test("AI_FALLBACK_PROVIDERS still supplies the free floor when AI_FREE_PROVIDERS is unset")
        func legacyFallbackListSuppliesFreeFloor() {
            defer { clearEnv() }
            clearEnv()
            setProductionLikeEnv()
            setenv("AI_FALLBACK_PROVIDERS", "openrouter|z-ai/glm-5.2:free", 1)

            #expect(AIProviderConfiguration.loadFreeTiers(maxTokens: 700).map(\.model) == ["z-ai/glm-5.2:free"])
        }

        @Test("The free chain is not silenced by the fallback kill switch")
        func fallbackKillSwitchDoesNotEmptyTheFreeChain() {
            defer { clearEnv() }
            clearEnv()
            setProductionLikeEnv()
            setenv("AI_FALLBACK_ENABLED", "false", 1)

            // AI_FALLBACK_ENABLED means "the paid chain does not demote". It must not
            // mean "free users have no model at all".
            #expect(!AIProviderConfiguration.loadFreeTiers(maxTokens: 700).isEmpty)
            #expect(AIProviderConfiguration.loadFallbacks(maxTokens: 700).isEmpty)
        }

        // MARK: - Pro chain composition

        @Test("The pro chain leads with the paid primary and ends on the free floor")
        func proChainOrder() {
            defer { clearEnv() }
            clearEnv()
            setProductionLikeEnv()
            setenv("AI_PRO_FALLBACK_PROVIDERS", "openrouter|anthropic/claude-sonnet-4.6", 1)
            setenv("AI_FREE_PROVIDERS", "openrouter|nvidia/nemotron-3-super-120b-a12b:free", 1)

            let config = AIProviderConfiguration.load()

            #expect(config.proTiers.map(\.model) == [
                "deepseek/deepseek-v4-flash",
                "anthropic/claude-sonnet-4.6",
                "nvidia/nemotron-3-super-120b-a12b:free",
            ])
            #expect(config.freeTiers.map(\.model) == ["nvidia/nemotron-3-super-120b-a12b:free"])
        }

        @Test("With no paid alternates the pro chain is the primary plus the free floor")
        func proChainWithoutAlternates() {
            defer { clearEnv() }
            clearEnv()
            setProductionLikeEnv()
            setenv("AI_PRO_FALLBACK_PROVIDERS", "", 1)

            let config = AIProviderConfiguration.load()

            #expect(config.proTiers.map(\.model)
                == ["deepseek/deepseek-v4-flash"] + AIProviderConfiguration.defaultFallbackModels)
        }

        @Test("An unconfigured primary leaves the pro chain equal to the free floor")
        func proChainWithoutPrimary() {
            defer { clearEnv() }
            clearEnv()
            // A key for the rungs but no primary provider configured at all.
            setenv("AI_PROVIDER", "custom", 1)
            setenv("OPENROUTER_API_KEY", "sk-or-test", 1)

            let config = AIProviderConfiguration.load()

            #expect(!config.isConfigured)
            #expect(config.proTiers.map(\.model) == config.freeTiers.map(\.model))
        }

        // MARK: - Anthropic trial rung

        private func chainModels(_ config: AIProviderConfiguration) -> [[String]] {
            [config.proTiers, config.legacyTiers, config.freeRouterTiers, config.freeTiers].map { $0.map(\.model) }
        }

        @Test("With the Anthropic env unset, or the key set without ANTHROPIC_FIRST, every chain is unchanged")
        func anthropicOffLeavesChainsIdentical() {
            defer { clearEnv() }
            clearEnv()
            setProductionLikeEnv()
            let baseline = AIProviderConfiguration.load()
            #expect(baseline.anthropicTier == nil)
            #expect(baseline.freeRouterTiers.map(\.model) == baseline.freeTiers.map(\.model))

            setenv("ANTHROPIC_API_KEY", "sk-ant-test", 1)
            #expect(AIProviderConfiguration.load().anthropicTier == nil)
            #expect(chainModels(AIProviderConfiguration.load()) == chainModels(baseline))

            setenv("ANTHROPIC_FIRST", "false", 1)
            #expect(chainModels(AIProviderConfiguration.load()) == chainModels(baseline))

            // FIRST without a key is just as inert.
            unsetenv("ANTHROPIC_API_KEY")
            setenv("ANTHROPIC_FIRST", "true", 1)
            #expect(chainModels(AIProviderConfiguration.load()) == chainModels(baseline))
        }

        @Test("ANTHROPIC_FIRST leads the pro, legacy and free router chains; freeTiers stays free-only")
        func anthropicScopeAll() {
            defer { clearEnv() }
            clearEnv()
            setProductionLikeEnv()
            let baseline = AIProviderConfiguration.load()
            setenv("ANTHROPIC_API_KEY", "sk-ant-test", 1)
            setenv("ANTHROPIC_FIRST", "true", 1)

            let config = AIProviderConfiguration.load()
            let lead = "claude-haiku-5-5"

            #expect(config.anthropicScope == .all)
            #expect(config.proTiers.map(\.model) == [lead] + baseline.proTiers.map(\.model))
            #expect(config.legacyTiers.map(\.model) == [lead] + baseline.legacyTiers.map(\.model))
            #expect(config.freeRouterTiers.map(\.model) == [lead] + baseline.freeTiers.map(\.model))
            #expect(config.freeTiers.map(\.model) == baseline.freeTiers.map(\.model))
            #expect(config.freeTiers.allSatisfy { AIProviderConfiguration.isFreeModelSlug($0.model) })
        }

        @Test("ANTHROPIC_SCOPE=paid keeps free users on the free floor")
        func anthropicScopePaid() async throws {
            defer { clearEnv() }
            clearEnv()
            setProductionLikeEnv()
            setenv("ANTHROPIC_API_KEY", "sk-ant-test", 1)
            setenv("ANTHROPIC_FIRST", "true", 1)
            setenv("ANTHROPIC_SCOPE", "paid", 1)

            let config = AIProviderConfiguration.load()
            #expect(config.anthropicScope == .paid)
            #expect(config.freeRouterTiers.map(\.model) == config.freeTiers.map(\.model))
            #expect(config.proTiers.first?.model == "claude-haiku-5-5")

            let app = try await Application.make(.testing)
            defer { Task { try? await app.asyncShutdown() } }
            let router = try #require(makeAIModelRouter(app))
            #expect(router.freeTiers.allSatisfy { AIProviderConfiguration.isFreeModelSlug($0.model) })
            #expect(router.proTiers.first?.model == "claude-haiku-5-5")
        }

        @Test("A built router with scope all leads both plans with the Anthropic rung")
        func anthropicRouterScopeAll() async throws {
            defer { clearEnv() }
            clearEnv()
            setProductionLikeEnv()
            setenv("ANTHROPIC_API_KEY", "sk-ant-test", 1)
            setenv("ANTHROPIC_FIRST", "true", 1)

            let app = try await Application.make(.testing)
            defer { Task { try? await app.asyncShutdown() } }
            let router = try #require(makeAIModelRouter(app))

            #expect(router.freeTiers.first?.model == "claude-haiku-5-5")
            #expect(router.proTiers.first?.model == "claude-haiku-5-5")
            #expect(router.freeTiers.dropFirst().allSatisfy { AIProviderConfiguration.isFreeModelSlug($0.model) })
            #expect(router.client(for: .free) is FallbackChatClient)
        }

        @Test("The Anthropic tier reads its model, effort, thinking, max tokens and base URL from the env")
        func anthropicTierSettings() throws {
            defer { clearEnv() }
            clearEnv()
            setProductionLikeEnv()
            setenv("AI_MAX_TOKENS", "2000", 1)
            setenv("ANTHROPIC_API_KEY", "sk-ant-test", 1)
            setenv("ANTHROPIC_FIRST", "true", 1)

            let defaults = try #require(AIProviderConfiguration.load().anthropicTier)
            #expect(defaults.model == "claude-haiku-5-5")
            #expect(defaults.baseURL == "https://api.anthropic.com")
            // Not AI_MAX_TOKENS: that budget is sized for a model that does not think.
            #expect(defaults.maxTokens == 4096)
            #expect(defaults.supportsResponseFormat)
            #expect(defaults.dialect == .anthropicMessages(AnthropicMessagesOptions(effort: nil, thinkingEnabled: true)))

            setenv("ANTHROPIC_MODEL", "claude-sonnet-5-5", 1)
            setenv("ANTHROPIC_EFFORT", "Low", 1)
            setenv("ANTHROPIC_THINKING", "disabled", 1)
            setenv("ANTHROPIC_MAX_TOKENS", "8000", 1)
            setenv("ANTHROPIC_BASE_URL", "https://proxy.test/", 1)

            let custom = try #require(AIProviderConfiguration.load().anthropicTier)
            #expect(custom.model == "claude-sonnet-5-5")
            #expect(custom.maxTokens == 8000)
            #expect(custom.baseURL == "https://proxy.test")
            #expect(custom.dialect == .anthropicMessages(AnthropicMessagesOptions(effort: "low", thinkingEnabled: false)))
        }

        // MARK: - Router

        @Test("The router hands each plan its own chain")
        func routerSelectsByPlan() async throws {
            try await withRequest { req in
                let recorder = ModelRecorder()
                let router = AIModelRouter(
                    free: RecordingChatClient(model: "free-chain", recorder: recorder),
                    pro: RecordingChatClient(model: "pro-chain", recorder: recorder)
                )

                let freeReply = try await router.client(for: .free)
                    .chat(messages: [], tools: [], responseFormat: nil, on: req)
                let proReply = try await router.client(for: .pro)
                    .chat(messages: [], tools: [], responseFormat: nil, on: req)

                #expect(freeReply.content == "free-chain")
                #expect(proReply.content == "pro-chain")
                #expect(recorder.seen == ["free-chain", "pro-chain"])
            }
        }

        @Test("A built router gives free users a chain that can only reach free slugs")
        func builtRouterFreeChainIsFreeOnly() async throws {
            defer { clearEnv() }
            clearEnv()
            setProductionLikeEnv()

            let app = try await Application.make(.testing)
            defer { Task { try? await app.asyncShutdown() } }

            let router = try #require(makeAIModelRouter(app))

            #expect(router.freeTiers.allSatisfy { AIProviderConfiguration.isFreeModelSlug($0.model) })
            #expect(router.proTiers.first?.model == "deepseek/deepseek-v4-flash")
            #expect(router.proTiers.contains { AIProviderConfiguration.isFreeModelSlug($0.model) })
        }

        @Test("AI_PLAN_ROUTING_ENABLED=false builds no router, leaving the legacy chain in place")
        func planRoutingKillSwitch() async throws {
            defer { clearEnv() }
            clearEnv()
            setProductionLikeEnv()
            setenv("AI_PLAN_ROUTING_ENABLED", "false", 1)

            let app = try await Application.make(.testing)
            defer { Task { try? await app.asyncShutdown() } }

            // The rollback lever. No router means the resolver falls through to
            // `app.openAIChatClient`, which still leads with the paid primary.
            #expect(makeAIModelRouter(app) == nil)

            setenv("AI_PLAN_ROUTING_ENABLED", "true", 1)
            #expect(makeAIModelRouter(app) != nil)
        }

        @Test("With no key at all no router is built, so nothing shadows the shared client")
        func routerWithoutAnyKey() async throws {
            defer { clearEnv() }
            clearEnv()
            setenv("AI_PROVIDER", "openrouter", 1)

            let app = try await Application.make(.testing)
            defer { Task { try? await app.asyncShutdown() } }

            // Two disabled chains are not a routing decision. Nil keeps the resolver
            // on `app.openAIChatClient`, which a caller may have set deliberately.
            #expect(makeAIModelRouter(app) == nil)
        }

        // MARK: - Capability interaction

        @Test("A JSON turn on the free chain skips the ultra model and lands on the 120b")
        func jsonTurnOnFreeChainSkipsIncapableRung() async throws {
            defer { clearEnv() }
            clearEnv()
            setProductionLikeEnv()

            // The shipped default order: ultra first, 120b behind it.
            let free = AIProviderConfiguration.loadFreeTiers(maxTokens: 700)
            #expect(free.first?.model == "nvidia/nemotron-3-ultra-550b-a55b:free")
            #expect(free.first?.supportsResponseFormat == false)
            #expect(free.last?.model == "nvidia/nemotron-3-super-120b-a12b:free")
            #expect(free.last?.supportsResponseFormat == true)

            try await withRequest { req in
                let recorder = ModelRecorder()
                let chain = FallbackChatClient(rungs: free.map { tier in
                    .init(tier: tier, client: RecordingChatClient(model: tier.model, recorder: recorder))
                })

                let reply = try await chain.chat(
                    messages: [], tools: [], responseFormat: "json_object", on: req
                )

                #expect(reply.content == "nvidia/nemotron-3-super-120b-a12b:free")
                #expect(recorder.seen == ["nvidia/nemotron-3-super-120b-a12b:free"])
            }
        }
    }
}
