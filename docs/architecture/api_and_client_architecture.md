# API and Client Architecture & Best Practices

This document outlines the architectural decisions, data structure usage, and development best practices recently applied across the StockPlanBackend (Vapor) and StockPlanIOSApp (SwiftUI) codebases.

## 1. Shared Data Structures (`StockPlanShared`)

A central tenet of the project is maintaining a strict type contract between the client and server using a shared Swift package (`StockPlanShared`).

- **DTOs as the Source of Truth:** Data Transfer Objects (DTOs) like `UpdateUsernameRequest`, `UpdatePasswordRequest`, and `BudgetSnapshotRequest` are defined here. This guarantees that if the server expects a field, the iOS client must provide it, catching schema mismatches at compile time rather than runtime.
- **Protocol Conformance:** Shared models strictly conform to `Codable`, `Sendable`, and `Equatable`. 
- **Vapor `Content` Conformance:** The backend relies on Vapor's `Content` protocol to encode/decode HTTP bodies automatically. Rather than adding Vapor as a dependency to the shared package (which would bloat the iOS client), we apply `@retroactive Content` extensions in the backend codebase (`StockPlanShared+Content.swift`). For highly specialized or diverging models (like `MarketDataDTOs`), we maintain backend-specific structs that mirror the shared DTOs but directly conform to `Content`.

## 2. API Architecture & Best Practices

The Vapor backend follows a clean, modular architecture separating Routing, Services, and Repositories.

### Routing & Controllers
- **Surgical Endpoints:** Instead of relying on massive, monolithic `PUT` requests to update entire entities (e.g., updating a user's entire profile), the API provides surgical `PATCH` endpoints (`/v1/users/username`, `/v1/users/email`, `/v1/users/password`). This reduces payload size, minimizes the risk of accidental data overwrites, and simplifies audit logging.
- **Strict Validation:** Controllers decode the specific DTOs and immediately hand them off to the Service layer for business validation.

### Service Layer & Fluent
- **Concurrency & Sendable:** All services (e.g., `UserProfileService`) are protocols marked as `Sendable` and return asynchronous `Task` results (`async throws`).
- **Robust Upserts & Normalization:** When handling time-sensitive records like `BudgetSnapshot`, the service layer enforces strict normalization (e.g., forcing dates to the 1st of the month at `00:00:00 UTC`). It uses date ranges rather than exact timestamp matching for `SELECT` queries before performing an `INSERT` or `UPDATE`, mitigating subtle timezone bugs and preventing PostgreSQL unique constraint violations (`PSQLError`).
- **Security:** Passwords are never returned in DTOs. When updating passwords, the current password must be verified against the `Bcrypt` hash before generating a new hash for the updated password.

## 3. iOS Client Architecture (SwiftUI)

The iOS app strictly adheres to modern SwiftUI and Swift 6 concurrency patterns, guided by the `swiftui-pro` skill principles.

### Concurrency & Strict Isolation
- **`@MainActor` Enforcement:** Any type that interacts with the UI, including ViewModels (`ObservableObject`) and newly observed state managers (`@Observable`), is strictly isolated to the `@MainActor`.
- **Safe Dependency Injection:** The app uses `Factory` for dependency injection. Because `AppEnvironmentManager` uses the `@Observable` macro (which implicitly isolates it to the main actor), accessing it inside a non-isolated Factory closure causes synchronous-to-isolated concurrency warnings in Swift 6. This is resolved by explicitly marking the factory closures with `@MainActor in`, ensuring all UI-driving services are resolved safely on the main thread.

### View Construction & Hygiene
- **Component Simplification:** Complex, overly nested views are broken down into standard SwiftUI primitives. For example, `EditProfileView` was refactored from a custom scroll view with manual dividers into a native SwiftUI `List` with `Section` blocks. This not only improves code readability but automatically inherits iOS system styling and accessibility behaviors.
- **Modern Data Flow:** We avoid fragile manual bindings (like `Binding(get:set:)`). Instead, views rely on localized `@State` properties (e.g., `@State private var username: String`) that are initialized from the source of truth (`originalProfile`). Mutations only propagate back to the ViewModel explicitly via user intent (e.g., tapping "Save").
- **Focused Inputs:** Views utilize `@FocusState` to manage keyboard focus predictably, and input fields apply semantic modifiers like `.keyboardType(.emailAddress)`, `.textInputAutocapitalization(.never)`, and `.autocorrectionDisabled()` to enhance the user experience.

### SwiftUI Pro Guidelines Adopted
- **Modern APIs:** Avoid deprecated modifiers. Use `foregroundStyle()` over `foregroundColor()`.
- **Accessibility by Default:** Native SwiftUI constructs (`List`, `Section`, `TextField`) are preferred because they provide robust VoiceOver and Dynamic Type support out of the box.
- **Performance:** Complex logic is offloaded to background Tasks or ViewModels. State is mutated on the main thread, but network calls (via `UserProfileHTTPClient`) occur asynchronously without blocking the UI.
