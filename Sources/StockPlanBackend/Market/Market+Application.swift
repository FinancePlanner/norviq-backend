//
//  Market+Application.swift
//  StockPlanBackend
//
//  Created by Fernando Correia on 10.02.26.
//

import Vapor

extension Application {
    struct MarketDataRepositoryKey: StorageKey {
        typealias Value = any MarketDataRepository
    }

    struct MarketDataServiceKey: StorageKey {
        typealias Value = any MarketDataService
    }

    var marketDataRepository: any MarketDataRepository {
        get { storage[MarketDataRepositoryKey.self]! }
        set { storage[MarketDataRepositoryKey.self] = newValue }
    }

    var marketDataService: any MarketDataService {
        get { storage[MarketDataServiceKey.self]! }
        set { storage[MarketDataServiceKey.self] = newValue }
    }
}
