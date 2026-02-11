import Vapor

extension Application {
    struct NewsServiceKey: StorageKey {
        typealias Value = any NewsService
    }

    var newsService: any NewsService {
        get { storage[NewsServiceKey.self]! }
        set { storage[NewsServiceKey.self] = newValue }
    }
}
