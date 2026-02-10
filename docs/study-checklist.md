# Study Checklist: Swift + Vapor + SwiftUI (8 Weeks)

Use this alongside `docs/study.md`.
Target pace: 60-90 minutes per day.

## Week 1: Swift Core (Types, Optionals, Error Handling)

- [ ] Day 1: Set up study environment, verify `swift --version`, create a `notes.md` for learning logs.
- [ ] Day 2: Practice `struct`, `class`, `enum`, and protocol basics with 3 small examples.
- [ ] Day 3: Drill optionals (`if let`, `guard let`, nil-coalescing) with parsing exercises.
- [ ] Day 4: Practice functions, computed properties, and immutability vs mutability.
- [ ] Day 5: Implement custom error types and `throws`/`do-catch` in a small parser.
- [ ] Day 6: Write XCTest cases for your parser and error paths.
- [ ] Day 7: Review and refactor your exercises; write a one-page summary of weak points.

## Week 2: Swift Concurrency + Codable + SPM

- [ ] Day 8: Learn `async/await` with a fake async API client.
- [ ] Day 9: Use `async let` and task groups for parallel calls in a toy example.
- [ ] Day 10: Learn `@MainActor`, `Sendable`, and actor basics; fix one deliberate race condition.
- [ ] Day 11: Practice `Codable` decoding for nested JSON and optional fields.
- [ ] Day 12: Add date decoding strategies and numeric formatting rules.
- [ ] Day 13: Organize code as a Swift package target and write unit tests.
- [ ] Day 14: Review all concurrency and decoding examples; write down recurring mistakes.

## Week 3: Vapor Basics + First CRUD Slice

- [ ] Day 15: Read `configure.swift` and route registration flow in this repo.
- [ ] Day 16: Create a new resource scaffold (DTO, controller, repository, service).
- [ ] Day 17: Add Fluent model + migration for the new resource.
- [ ] Day 18: Implement `POST` and `GET list` endpoints.
- [ ] Day 19: Implement `GET by id`, `PUT`, and `DELETE`.
- [ ] Day 20: Add request validation and consistent error responses.
- [ ] Day 21: Manual endpoint testing with Bruno; fix all obvious edge cases.

## Week 4: Auth, Middleware, and Better Architecture

- [ ] Day 22: Trace current auth flow (token issue, verification, protected groups).
- [ ] Day 23: Protect new resource routes with JWT/session middleware.
- [ ] Day 24: Enforce ownership checks for reads and writes.
- [ ] Day 25: Refactor business logic out of controller into service where needed.
- [ ] Day 26: Add repository tests and service tests for key rules.
- [ ] Day 27: Add integration tests for auth + CRUD happy path.
- [ ] Day 28: Review architecture decisions and document your dependency graph.

## Week 5: SwiftUI Fundamentals + Networking Layer

- [ ] Day 29: Create iOS app shell with navigation and feature folders.
- [ ] Day 30: Build a typed API client using `URLSession` and async/await.
- [ ] Day 31: Implement login and token storage abstraction (prepare for Keychain).
- [ ] Day 32: Build one list screen backed by real API data.
- [ ] Day 33: Add loading, empty, and error states for that screen.
- [ ] Day 34: Add create form flow with request validation feedback.
- [ ] Day 35: Manual end-to-end run: login -> list -> create -> reload.

## Week 6: SwiftUI State + CRUD Completion

- [ ] Day 36: Refactor state ownership (`@State`, `@StateObject`, `@EnvironmentObject`) intentionally.
- [ ] Day 37: Add detail screen and edit flow for your resource.
- [ ] Day 38: Add delete flow with confirmation and optimistic UI handling.
- [ ] Day 39: Implement pull-to-refresh and task cancellation safety.
- [ ] Day 40: Handle API error decoding into typed, user-friendly messages.
- [ ] Day 41: Add UI tests or deterministic preview/test data states.
- [ ] Day 42: End-to-end bug bash across happy and failure paths.

## Week 7: Integration Hardening

- [ ] Day 43: Add pagination support to one list endpoint and corresponding UI.
- [ ] Day 44: Add server-side filtering/sorting and wire it to app controls.
- [ ] Day 45: Standardize API error schema across endpoints.
- [ ] Day 46: Add request/response logging on one critical backend flow.
- [ ] Day 47: Add retry policy for transient network failures in the app client.
- [ ] Day 48: Add token refresh flow (or explicit re-login handling if refresh is not implemented).
- [ ] Day 49: Validate OpenAPI contract and align iOS models with backend DTOs.

## Week 8: Production Readiness and Confidence

- [ ] Day 50: Review migrations and data safety practices (idempotency, rollback awareness).
- [ ] Day 51: Add smoke test checklist for backend startup and key endpoints.
- [ ] Day 52: Add basic observability checklist (logs, failures, latency hotspots).
- [ ] Day 53: Run full test suite and fix remaining flaky tests.
- [ ] Day 54: Perform a full manual system test from iOS app to backend.
- [ ] Day 55: Write a short architecture document for your final setup.
- [ ] Day 56: Self-assessment against the "Definition of Done" and plan next 4 weeks.
