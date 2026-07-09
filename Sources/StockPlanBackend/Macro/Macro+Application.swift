import Vapor

extension Application {
    struct MacroRepositoryKey: StorageKey {
        typealias Value = any MacroRepository
    }

    struct MacroServiceKey: StorageKey {
        typealias Value = any MacroService
    }

    struct MacroProviderRegistryKey: StorageKey {
        typealias Value = MacroProviderRegistry
    }

    struct MacroSyncStatusKey: StorageKey {
        typealias Value = MacroSyncStatus
    }

    var macroRepository: any MacroRepository {
        get { storage[MacroRepositoryKey.self]! }
        set { storage[MacroRepositoryKey.self] = newValue }
    }

    var macroService: any MacroService {
        get { storage[MacroServiceKey.self]! }
        set { storage[MacroServiceKey.self] = newValue }
    }

    var macroProviderRegistry: MacroProviderRegistry {
        get { storage[MacroProviderRegistryKey.self]! }
        set { storage[MacroProviderRegistryKey.self] = newValue }
    }

    var macroSyncStatus: MacroSyncStatus {
        get { storage[MacroSyncStatusKey.self]! }
        set { storage[MacroSyncStatusKey.self] = newValue }
    }
}
