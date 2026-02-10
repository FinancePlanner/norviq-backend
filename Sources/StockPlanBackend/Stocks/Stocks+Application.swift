import Vapor

extension Application {
    struct StocksRepositoryKey: StorageKey {
        typealias Value = any StocksRepository
    }

    struct StocksServiceKey: StorageKey {
        typealias Value = any StockService
    }

    var stocksRepository: any StocksRepository {
        get { storage[StocksRepositoryKey.self]! }
        set { storage[StocksRepositoryKey.self] = newValue }
    }

    var stocksService: any StockService {
        get { storage[StocksServiceKey.self]! }
        set { storage[StocksServiceKey.self] = newValue }
    }
}
