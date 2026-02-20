# Shared Models Package Guide (Vapor + SwiftUI)

This guide shows how to create one Swift Package for API models used by both:
- your Vapor backend (`StockPlanBackend`)
- your iOS SwiftUI app

The goal is to share request/response DTOs, not Fluent DB models.

## 1. Decide What Goes in the Shared Package

Put in shared package:
- API request/response structs (`AuthLoginRequest`, `StockResponse`, etc.)
- enums used by both sides (`scenario`, transaction type, etc.)
- lightweight value types and validation helpers that are platform-agnostic

Keep out of shared package:
- `Fluent` models (`final class Stock: Model`)
- `Vapor`, `Fluent`, `JWT`, DB migrations, repositories, controllers
- app/UI-specific state objects

Rule: shared package should depend only on `Foundation` (and maybe `swift-foundation` later if needed).

## 2. Create the New Package

Create it as a separate repo/folder (recommended sibling to backend and iOS app):

```bash
cd /Users/fernando_idwell/Projects/StockProject
mkdir StockPlanShared
cd StockPlanShared
swift package init --type library
```

Update `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StockPlanShared",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "StockPlanShared", targets: ["StockPlanShared"])
    ],
    targets: [
        .target(name: "StockPlanShared"),
        .testTarget(name: "StockPlanSharedTests", dependencies: ["StockPlanShared"])
    ]
)
```

## 3. Add Shared DTOs (Pure Swift Types)

Suggested layout:

```text
Sources/StockPlanShared/
  Auth/
    AuthDTOs.swift
  Stocks/
    StockDTOs.swift
  Portfolio/
    PortfolioDTOs.swift
```

Example DTO style:

```swift
import Foundation

public struct AuthLoginRequest: Codable, Sendable {
    public let email: String
    public let password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}
```

Important:
- Use `public` access control for anything consumed outside the package.
- Prefer `Codable & Sendable`.
- Keep wire-format compatibility with your current backend (you currently use many date strings in DTOs).

## 4. Connect Package to Vapor Backend

In `StockPlanBackend/Package.swift` add local dependency first:

```swift
dependencies: [
    // existing deps...
    .package(path: "../StockPlanShared"),
],
targets: [
    .executableTarget(
        name: "StockPlanBackend",
        dependencies: [
            // existing deps...
            .product(name: "StockPlanShared", package: "StockPlanShared"),
        ]
    )
]
```

Then in backend DTO files:
- remove duplicated DTO struct definitions
- `import StockPlanShared`
- use shared types directly (or temporary `typealias` to minimize churn)

Example temporary alias approach:

```swift
import StockPlanShared

typealias StockRequest = StockPlanShared.StockRequest
typealias StockResponse = StockPlanShared.StockResponse
```

Your controllers already use `req.content.decode(...)` and `res.content.encode(...)`, which work with `Decodable`/`Encodable`, so shared `Codable` types are enough.

## 5. Connect Package to iOS App (SwiftUI)

In Xcode for iOS app:
1. `File > Add Packages...`
2. Add local path (during development) or git URL (after publishing)
3. Add product `StockPlanShared` to app target

Use same DTOs in networking layer:

```swift
import StockPlanShared

let payload = AuthLoginRequest(email: email, password: password)
```

## 6. Migrate Safely in Small Phases

Recommended order for your current backend:
1. `AuthDTOs.swift`
2. `StockDTO.swift`
3. `Portfolio/PortfolioDTOs.swift`
4. remaining feature DTOs (News, Dashboard, Broker, Market, Statistics)

For each phase:
1. move DTOs to shared package
2. replace backend structs with imports/aliases
3. build backend + iOS app
4. run tests before next phase

## 7. Versioning and Release Flow

Use semantic versioning on shared package:
- `0.x` while evolving quickly
- `1.0.0` once API contracts stabilize

Typical flow:
1. merge DTO changes in `StockPlanShared`
2. tag release (`v0.3.0`)
3. update dependency version in backend and iOS app
4. ship both sides together when breaking changes exist

## 8. Practical Rules That Prevent Pain

- Do not share Fluent `Model` classes; share API contracts only.
- Avoid backend-only imports (`Vapor`, `Fluent`) in shared module.
- Keep property names stable to preserve JSON compatibility.
- If you later change string dates to `Date`, do it in one planned migration with explicit encoder/decoder strategy on both sides.
- Add JSON round-trip tests in shared package for critical payloads.

## 9. Optional Next Step (Later)

You already have `openapi.yaml` in backend. After this shared package is stable, you can consider generating part of the client contracts from OpenAPI and exposing them through the shared package. Do this later; manual shared DTO migration first is simpler.
