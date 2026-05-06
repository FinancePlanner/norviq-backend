<claude-mem-context>
# Memory Context

# [StockPlanBackend] recent context, 2026-05-06 7:44am GMT+1

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision 🚨security_alert 🔐security_note
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 34 obs (13,671t read) | 343,178t work | 96% savings

### May 5, 2026
1 7:38a 🔵 StockPlanBackend crashes at startup with invalidPEMDocument
2 7:39a 🔵 Root cause traced to UserPIIEncryption fallback key being invalid PEM
3 " 🔵 OAUTH_APPLE_PRIVATE_KEY in .env files has split PEM header — malformed for local runs
4 7:40a 🔵 Docker Compose auto-loads .env, passing potentially garbled APNS/OAuth keys into container
5 " 🔴 TDD failing test created for APNS malformed key crash at startup
6 7:41a 🔵 TDD RED confirmed: configureAPNS missing + pre-existing BillingTests compile errors
7 " 🔴 configureAPNS extracted with fault-tolerant PEM parsing for non-production environments
8 " 🔴 swift build passes after configureAPNS extraction — fix confirmed compilable
9 7:42a 🔴 BillingTests compile errors fixed: allSatisfy KeyPath replaced with closure
59 11:06p ⚖️ CI Fix Plan: Redis Fatal Error + Compiler Warnings in Swift/Vapor Backend
60 " 🔵 Confirmed: IdempotencyMiddleware Active in Tests When REDIS_URL Set
61 " 🔵 Crashing Test Located in AuthTests.swift; No Custom Application+Testing Helper
62 11:07p 🔵 Test Bootstrap Already Has flushRedisIfConfigured Helper But May Trigger Crash
64 " 🔵 AuthTests.withApp Skips Redis Flush; Registration POST Hits IdempotencyMiddleware Directly
67 11:08p ⚖️ Plan Finalized: Gate IdempotencyMiddleware by Environment + Fix ExportService Warnings
69 11:11p ⚖️ CI Redis Fatal Error Fix Plan - Swift/Vapor Test Suite
72 11:12p 🔴 IdempotencyMiddleware Gated Out of Testing Environment
73 " 🔴 ExportService Swift Compiler Warnings Fixed
75 11:13p 🔵 DataExportRepository.update() Returns Non-Void — Unused Result Warnings Persist
76 " 🔴 ExportService `repository.update()` Unused-Result Warnings Silenced with `_ =`
77 " 🔴 StockPlanBackend Builds Clean — All Warnings Eliminated
S14 StockPlanBackend Builds Clean — All Warnings Eliminated (May 5 at 11:13 PM)
S15 Fix CI failure: Redis fatal crash during Swift tests + ExportService compiler warnings in StockPlanBackend (May 5 at 11:14 PM)
### May 6, 2026
92 7:04a 🔵 Vapor Redis Fatal Error During CI Tests
93 " 🔵 Redis Configuration Audit: Current State of StockPlanBackend
94 7:05a 🔵 Test Assertion Mismatch: Redis Health Check Expects "skipped" But CI Sets REDIS_URL
97 7:06a ⚖️ Redis Disabled in .testing Environment
99 " 🔴 Redis Disabled in .testing Environment in configure.swift
101 7:08a 🔴 configure.swift Change Compiles Clean
102 " 🔴 readinessEndpoint Test Passes With REDIS_URL Set
103 " 🔴 Auth Registration Test Passes With REDIS_URL Set — No IdempotencyMiddleware Interference
105 7:09a 🔵 Full Local Test Run: 218 Failures All Due to Missing Postgres, Zero Redis Crashes
108 7:12a 🔵 Local Postgres Running But Lacks Test Database and User
109 7:13a 🔵 Local Dev Database Used for Full Test Verification
110 " 🔵 Full Test Run With Local Postgres: All Failures Now USER_PII_ENCRYPTION_ACTIVE_KEY, Zero Redis Crashes
111 7:14a 🔴 Full Test Suite Passing With All Required Env Vars Set

Access 343k tokens of past work via get_observations([IDs]) or mem-search skill.
</claude-mem-context>