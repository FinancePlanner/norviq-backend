//
//  MarketDataRepository.swift
//  StockPlanBackend
//
//  Created by Fernando Correia on 10.02.26.
//

import Fluent
import Foundation
import Vapor

public protocol MarketDataRepository: Sendable {}

struct DatabaseMarketDataRepository: MarketDataRepository {}
