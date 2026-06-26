import Vapor

private struct StocksRepositoryKey: StorageKey {
    typealias Value = any StocksRepository
}

private struct StocksServiceKey: StorageKey {
    typealias Value = any StockService
}

extension Application {
    var stocksRepository: any StocksRepository {
        get { storage[StocksRepositoryKey.self]! }
        set { storage[StocksRepositoryKey.self] = newValue }
    }

    var stocksService: any StockService {
        get { storage[StocksServiceKey.self]! }
        set { storage[StocksServiceKey.self] = newValue }
    }
}

extension Request {
    var stocksService: any StockService {
        StockServiceImpl(repo: application.stocksRepository, req: self)
    }
}
