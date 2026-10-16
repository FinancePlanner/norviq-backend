import Vapor

extension Application {
    private struct RecapRepositoryKey: StorageKey {
        typealias Value = any RecapRepository
    }

    var recapRepository: any RecapRepository {
        get { storage[RecapRepositoryKey.self] ?? DatabaseRecapRepository() }
        set { storage[RecapRepositoryKey.self] = newValue }
    }
}
