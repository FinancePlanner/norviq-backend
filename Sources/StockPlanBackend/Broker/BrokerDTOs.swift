import Vapor

struct BrokerConnectionResponse: Content {
    let id: String
    let provider: String
    let status: String
}

struct BrokerHoldingResponse: Content {
    let symbol: String
    let quantity: Double
    let currency: String
}

struct BrokerSyncResponse: Content {
    let runId: String
    let status: String
}
