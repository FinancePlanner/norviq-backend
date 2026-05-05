<claude-mem-context>
# Memory Context

# [StockPlanBackend] recent context, 2026-05-05 7:40am GMT+1

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 3 obs (1,357t read) | 58,582t work | 98% savings

### May 5, 2026
1 7:38a 🔵 StockPlanBackend crashes at startup with invalidPEMDocument
2 7:39a 🔵 Root cause traced to UserPIIEncryption fallback key being invalid PEM
3 " 🔵 OAUTH_APPLE_PRIVATE_KEY in .env files has split PEM header — malformed for local runs

Access 59k tokens of past work via get_observations([IDs]) or mem-search skill.
</claude-mem-context>