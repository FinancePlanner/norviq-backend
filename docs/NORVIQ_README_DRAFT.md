# Norviq (StockPlan)

A personal stock portfolio tracker and financial planning system built with a Full-Stack Swift architecture. 

## System Overview

Norviq comprises a server-side Vapor application for RESTful APIs and a SwiftUI iOS mobile application, connected via a shared Swift package for DTOs and type-safe data models.

The system is designed to help active investors follow positions, write due diligence, set base/bear/bull targets, and manage personal expenses.

## Architecture

The system utilizes a Full-Stack Swift approach:
- **Backend (`StockPlanBackend`)**: Built on Vapor 4.x, utilizing PostgreSQL, JWT auth, and Docker for deployment.
- **Client (`StockPlanIOSApp / financeplan`)**: Built with SwiftUI using an MVVM architecture, utilizing `Factory` for Dependency Injection.
- **Shared Models (`StockPlanShared`)**: Codable DTOs (e.g., `StockResponse`, auth payloads, watchlists) shared between the backend and client.

---

## 1. Backend (`StockPlanBackend`)

The backend provides secure data storage, API endpoints, and orchestrates external data sync (like broker CSV imports and market data fetching).

### Core Domains & Directory Structure
The API is split into domain boundaries:
- `Auth`: User registration, login, JWT issuance.
- `Stocks` & `Portfolio`: CRUD for holdings and portfolio aggregation.
- `Market` & `News`: Integration with external market data providers (e.g., quotes, 5/10 yr history).
- `Research` & `Targets`: Due Diligence (thesis, risks, catalysts) and Base/Bear/Bull scenario tracking.
- `Broker`: CSV import pipeline for external broker holdings (MVP version).
- `Expenses` & `Dashboard`: Budget planner and aggregated home snapshots.
- `Activity`, `Gamification`, `Feedback`, `Statistics`, `UserProfile`.

*Location:* `Sources/StockPlanBackend/`

### Tech Stack
- **Framework**: Vapor 4.x
- **Database**: PostgreSQL (prod) / SQLite (dev)
- **Deployment**: Docker (`docker-compose.yml`), tailored for lightweight VPS hosting (e.g., Hetzner).

### Key Features
- Route versioning under `/v1`.
- Secure JWT-based endpoint authorization.
- Caching and rate limiting for external data (Market / News).

---

## 2. iOS Client (`StockPlanIOSApp / financeplan`)

A native iOS app designed for performance and clean UI, organized by functional features rather than technical layers.

### Core Modules & Directory Structure
- `App Entry`: `NorviqaApp.swift` (`@main`), `ContentView.swift` (splash/login routing).
- `Features/`:
  - `Home`: TabView dashboard, insights, search.
  - `Portfolio`: Holdings lists, cost-basis donuts (Swift Charts), and portfolio CRUD.
  - `Stocks`: Detailed stock insights (Overview, Projections, Compare), peer comparisons, edit position sheets.
  - `Expenses`: Budget planner UI, reports and expenses comparison.
  - `Auth`: Login screen and session management (`SessionManager`).
  - `Onboarding` & `UserProfile`: CSV import flow and user settings.
- `Components/`: Reusable SwiftUI building blocks (`GlassCard`, `MeshGradientBackground`, `FormComponents`).
- `API/`: HTTP clients mapping backend endpoints (e.g., `StockHTTPClient`, `AuthHTTPClient`).

*Location:* `financeplan/financeplan/`

### UI & Navigation Patterns
- **MVVM Style**: SwiftUI Views observe `@MainActor` ViewModels, which in turn use Protocol-oriented services.
- **Dependency Injection**: Resolves singletons like `stockService` or `authSessionManager` using the [Factory](https://github.com/hmlongco/Factory) package.
- **Navigation**: Uses `NavigationStack` for detail pushes and `TabView` for top-level navigation, heavily relying on SwiftUI Sheets for editing (e.g., `EditStockPositionSheet`).

### Environments
The app can point to three environments via `AppEnvironment.swift`:
- **Local**: `http://localhost:8080` (requires Docker/Vapor running locally).
- **Production**: `https://api.norviqa.io`

---

## Shared Models (`StockPlanShared`)

Business logic contracts are consumed as a Swift Package dependency (`FinanceShared`). This ensures that changes to the backend API schemas are strongly typed and instantly flag errors in the iOS Client.
