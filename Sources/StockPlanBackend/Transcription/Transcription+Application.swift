import Vapor

extension Application {
    struct TranscriptionProviderKey: StorageKey {
        typealias Value = any TranscriptionProvider
    }

    /// Always present. With no key configured this is the disabled provider,
    /// so callers ask `isEnabled` instead of unwrapping.
    var transcriptionProvider: any TranscriptionProvider {
        get { storage[TranscriptionProviderKey.self] ?? DisabledTranscriptionProvider() }
        set { storage[TranscriptionProviderKey.self] = newValue }
    }

    struct TranscriptionLimitsKey: StorageKey {
        typealias Value = TranscriptionLimits
    }

    var transcriptionLimits: TranscriptionLimits {
        get { storage[TranscriptionLimitsKey.self] ?? .default }
        set { storage[TranscriptionLimitsKey.self] = newValue }
    }
}
