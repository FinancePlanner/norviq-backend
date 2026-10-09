import Vapor

extension Application {
    private struct TerminalAIClientKey: StorageKey {
        typealias Value = any OpenAIChatClient
    }

    /// Web-search chat client for terminal suggestions; nil when no AI key is
    /// configured (the AI routes then answer 503). Tests replace it.
    var terminalAIClient: (any OpenAIChatClient)? {
        get { storage[TerminalAIClientKey.self] }
        set { storage[TerminalAIClientKey.self] = newValue }
    }
}
