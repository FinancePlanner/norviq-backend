import Vapor

extension Application {
    struct MarketNewsArchiveServiceKey: StorageKey {
        typealias Value = any MarketNewsArchiveService
    }

    var marketNewsArchiveService: any MarketNewsArchiveService {
        get { storage[MarketNewsArchiveServiceKey.self]! }
        set { storage[MarketNewsArchiveServiceKey.self] = newValue }
    }
}
