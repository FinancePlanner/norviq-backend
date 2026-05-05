<claude-mem-context>
# Memory Context

# [StockPlanBackend] recent context, 2026-05-05 6:34pm GMT+1

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 9 obs (3,789t read) | 117,777t work | 97% savings

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

Access 118k tokens of past work via get_observations([IDs]) or mem-search skill.
</claude-mem-context>