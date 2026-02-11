import Vapor

extension Application {
    struct NewsRepositoryKey: StorageKey {
        typealias Value = any NewsRepository
    }

    struct NewsServiceKey: StorageKey {
        typealias Value = any NewsService
    }

    var newsRepository: any NewsRepository {
        get { storage[NewsRepositoryKey.self]! }
        set { storage[NewsRepositoryKey.self] = newValue }
    }

    var newsService: any NewsService {
        get { storage[NewsServiceKey.self]! }
        set { storage[NewsServiceKey.self] = newValue }
    }
}
