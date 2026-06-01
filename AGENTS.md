<claude-mem-context>
# Memory Context

# [StockPlanBackend] recent context, 2026-05-29 4:50pm GMT+1

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision 🚨security_alert 🔐security_note
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 50 obs (16,659t read) | 461,428t work | 96% savings

### May 5, 2026
S15 Fix CI failure: Redis fatal crash during Swift tests + ExportService compiler warnings in StockPlanBackend (May 5 at 11:13 PM)
S14 StockPlanBackend Builds Clean — All Warnings Eliminated (May 5 at 11:13 PM)
S46 Test - minimal user input with no specific task (May 5 at 11:14 PM)
### May 9, 2026
S47 Add tier-based access control to Crypto endpoints in StockPlanBackend — clarifying which user tiers should have access (May 9 at 12:48 PM)
S48 Add pro-tier entitlement gating to all Crypto endpoints in StockPlanBackend Swift/Vapor backend (May 9 at 12:49 PM)
S54 Crypto feature billing gate tests added for both backend and iOS — full test suite verification (May 9 at 12:53 PM)
428 12:57p 🟣 Added BillingFeature.crypto Case to EntitlementResolver.swift
430 " 🟣 EntitlementResolver.swift Fully Updated: .crypto Added to All Three Switch Statements
432 " 🔵 BillingContextService.swift Has BillingFeatureDescriptor.all Array Missing .crypto
433 " 🟣 BillingContextService.swift Updated: .crypto Added to BillingFeatureDescriptor.all
437 12:58p 🟣 CryptoController.swift: All 11 Endpoints Now Gated with requireCryptoEntitlement()
440 12:59p ✅ Backend swift build Passes Clean After Crypto Gating Changes
443 " 🔵 CryptoHomeView.swift: Full Structure — 4-Segment NavigationStack, No Pro Gate
446 1:00p 🔵 iOS BillingManager DI Pattern: @InjectedObservable and Existing ProGateView Usage Sites
448 " 🟣 CryptoHomeView.swift: @InjectedObservable BillingManager Added
450 1:01p 🔵 ProGateView Used Inline Within Scrollable Content in ExpensesPlannerScreen
451 " 🟣 CryptoHomeView.swift: Pro/Locked Split Body with ProGateView for Free Users
453 " 🔵 iOS App SPM Dependency Stack Including Factory 2.5.3 and StockPlanShared 0.9.45
455 1:02p 🔵 iOS Project Schemes: financeplan (main), Norviqa TestFlight Dev, RevenueCatUI
461 1:05p 🔵 financeplan iOS App Build Succeeded for iOS Simulator
462 1:06p 🔵 financeplan iOS Build Confirmed Succeeded with "** BUILD SUCCEEDED **"
473 1:22p 🔵 BillingDTOs.swift Location in FinanceShared Package
474 " 🔵 Test Files Using AppEnvironmentManager and AuthSessionManagerMock
476 1:23p 🔵 Full Shape of BillingContextResponse, BillingSubscriptionDTO, and BillingFeatureDTO
479 1:24p 🟣 CryptoBillingGateTests.swift Created for Crypto Feature Gating
480 " 🔵 CryptoAssetResponse Shape in FinanceShared
481 " 🔵 Crypto API Endpoint Definitions in CryptoEndpoints.swift
484 1:28p 🟣 iOS Crypto Feature Tests Passing — CryptoBillingGate and CryptoViewModel
506 5:41p ⚖️ iOS Share Extension Should Collect Social Media Metadata
508 " 🔵 iOS Sharing Spread Across Six Files in StockPlanIOSApp
511 5:42p 🔵 Sharing Architecture Is Entirely Text-Based With No Rich Metadata
521 5:43p 🔵 Backend Has No Sharing Routes or OG Metadata Endpoints
523 " 🔵 App Is Named "Norviqa" — Key URLs and Constants Identified
525 " ⚖️ Backend Will Add /share OG Routes via SharingController
527 5:44p ⚖️ Three-Task Plan for Social Share Metadata Feature
529 " 🔵 Backend Routes Use Vapor Collection Pattern Under /v1 Prefix
533 " 🟣 SharingController Implemented — Backend OG/Twitter Card HTML Routes
534 " 🟣 SharingController Registered in Backend Routes
538 5:45p 🟣 Backend Builds Successfully With SharingController
541 " 🟣 SharingTests.swift Created — Five Tests Covering OG Metadata, Sanitization, Auth, and XSS
546 5:47p 🔴 Symbol Sanitizer Strips Tags But Keeps Inner Text — Test Failure on XSS Input
547 " 🔴 sanitizeSymbol Fixed — filter Replaced With prefix to Truncate at First Invalid Character
550 " 🟣 All 5 SharingTests Pass — Backend Share Routes Fully Verified
564 5:50p 🟣 shareBaseUrl Constant Added to iOS Constants.swift
566 " 🟣 ShareURLBuilder Created in iOS Utilities
568 " 🔵 Remaining Three ShareLink Call Sites Identified Before iOS Update
572 " 🟣 StockDetailsScreen ShareLinks Updated — URL + SharePreview Added to All Four Stock Share Options
574 5:51p 🟣 PortfolioAllocationScreen and UserProfileView ShareLinks Updated With URL and SharePreview
576 " 🟣 OnboardingValueRevealScreen ShareLink Updated — Final iOS Call Site Wired
578 5:52p 🔵 ChartExporter Shares UIImage via UIActivityViewController — Excluded From URL/Metadata Update
580 " 🟣 LPLinkMetadataActivityItemSource Added for UIKit Share Sheet Rich Previews
582 " 🟣 ChartExporter Now Uses LPLinkMetadataActivityItemSource for Rich Share Previews
583 " 🟣 ShareURLBuilderTests Created — Six XCTest Cases Covering URL Construction and Sanitization
586 " 🔴 ShareURLBuilder Needs @MainActor — Static Methods Are Main Actor Isolated
588 5:53p 🔴 ShareURLBuilderTests Annotated @MainActor to Fix Actor Isolation Build Error
594 5:54p 🟣 All iOS ShareURLBuilderTests Pass — Social Share Metadata Feature Complete
S60 Add social media metadata to iOS sharing so shared links produce rich previews on X, iMessage, Discord, etc. (May 9 at 5:54 PM)
**Completed**: **Backend (StockPlanBackend):**
    - Created Sources/StockPlanBackend/Sharing/SharingController.swift — GET /share/stock/:symbol and GET /share/app returning HTML with og:type, og:title, og:description, og:url, og:image, og:site_name, twitter:card, twitter:title, twitter:description, twitter:image, Apple App Links meta, meta-refresh redirect to App Store
    - SharingHTMLRenderer with XSS-safe HTML entity escaping (&amp; &lt; &gt; &quot; &#39;)
    - Symbol sanitized via prefix-truncation (alphanumerics + . and -)
    - Cache-Control: public, max-age=300 on all responses
    - Env vars: SHARE_PUBLIC_BASE_URL, SHARE_OG_IMAGE_URL, SHARE_APP_STORE_URL (all with safe fallbacks)
    - Registered SharingController in routes.swift at app root (outside /v1, no auth)
    - Created Tests/StockPlanBackendTests/SharingTests.swift — 5 tests: OG metadata, symbol sanitization/XSS, app landing, public access, HTML escaping — all pass
    - Fixed sanitizeSymbol bug: filter → prefix (caught by stockShareSanitizesSymbol test)
    - swift build: clean, Build complete (35s)

    **iOS (StockPlanIOSApp):**
    - Added Constants.Norviq.shareBaseUrl = https://www.norviqaapp.com
    - Created Utilities/ShareURLBuilder.swift — stock(symbol:baseURL:) and app(baseURL:) with identical prefix-truncation sanitization
    - Created Utilities/LPLinkMetadataActivityItemSource.swift — UIActivityItemSource vending LPLinkMetadata for UIKit share flows (supports UIImage and URL items)
    - Updated StockDetailsScreen.shareMenu: 4 ShareLinks now share ShareURLBuilder.stock(symbol:) URL with SharePreview (doc.text, quote.bubble, chart.line.uptrend.xyaxis, scope SF Symbols); body text moved to message: parameter
    - Updated PortfolioAllocationScreen: ShareLink now uses ShareURLBuilder.app() + SharePreview(chart.pie.fill)
    - Updated UserProfileView: replaced hardcoded wrong App Store ID URL with ShareURLBuilder.app() + SharePreview; removed fragile if let URL guard
    - Updated OnboardingValueRevealScreen: plain text summary moved to message:, item: is now ShareURLBuilder.app() + SharePreview
    - Updated ChartExporter.ShareableChartView: image share now wrapped in LPLinkMetadataActivityItemSource(title:, item: image, icon: image)
    - Created financeplanTests/ShareURLBuilderTests.swift — 6 XCTest cases (uppercase, dot/dash, XSS truncation, empty symbol, app URL, default base URL); added @MainActor to fix actor isolation build error
    - All 6 ShareURLBuilderTests pass on iPhone 16 simulator; no regressions in 8 existing tests

**Next Steps**: All 5 planned tasks (10–14) are completed. The feature is fully implemented and tested but not yet committed. The natural next step is a git commit across both repositories (StockPlanBackend and StockPlanIOSApp), and adding the three new SHARE_* env vars to production deployment configuration (.env.production / deployment secrets).


Access 461k tokens of past work via get_observations([IDs]) or mem-search skill.
</claude-mem-context>