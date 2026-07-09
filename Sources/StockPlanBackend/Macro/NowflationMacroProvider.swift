import Foundation
import Vapor

/// Protocol for fetching macro/inflation data.
/// Future: live Nowflation fetch + primary FRED/BLS sources.
protocol MacroDataProviding: Sendable {
    func fetchCurrentSnapshot(on req: Request) async throws -> InflationSnapshotResponse
}

/// Stub / disabled provider (safe default when no config).
struct DisabledMacroProvider: MacroDataProviding {
    func fetchCurrentSnapshot(on _: Request) async throws -> InflationSnapshotResponse {
        throw Abort(.serviceUnavailable, reason: "Macro data provider is disabled")
    }
}

/// Placeholder for real Nowflation fetcher.
/// TODO: Implement HTTP client that fetches https://nowflation.com and/or its open JSON endpoints.
/// Parse headline, gauges, components, top movers (Utilities, Food, Shelter emphasis).
/// Cache results. Respect daily cadence.
struct NowflationMacroProvider: MacroDataProviding {
    let client: any Client

    func fetchCurrentSnapshot(on _: Request) async throws -> InflationSnapshotResponse {
        // Phase 1 implementation will go here.
        // For now we let the controller return the static realistic snapshot.
        // This keeps the endpoint working immediately.
        throw Abort(.notImplemented, reason: "NowflationMacroProvider live fetch not yet implemented — using controller stub")
    }
}
