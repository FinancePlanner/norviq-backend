//
//  Portfolio+Application.swift
//  StockPlanBackend
//

import Vapor

extension Application {
    struct PortfolioValuationServiceKey: StorageKey {
        typealias Value = any PortfolioValuationService
    }

    var portfolioValuationService: any PortfolioValuationService {
        get { storage[PortfolioValuationServiceKey.self]! }
        set { storage[PortfolioValuationServiceKey.self] = newValue }
    }
}
