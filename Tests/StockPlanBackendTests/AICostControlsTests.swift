import Foundation
@testable import StockPlanBackend
import Testing

@Suite("AICostControls", .serialized, .databaseLocked)
struct AICostControlsTests {
    @Test("AI_ENABLED defaults to true and accepts common falsy values")
    func enabledParsing() {
        defer {
            unsetenv("AI_ENABLED")
        }
        unsetenv("AI_ENABLED")
        #expect(AICostControls.isEnabled == true)

        setenv("AI_ENABLED", "false", 1)
        #expect(AICostControls.isEnabled == false)

        setenv("AI_ENABLED", "0", 1)
        #expect(AICostControls.isEnabled == false)

        setenv("AI_ENABLED", "true", 1)
        #expect(AICostControls.isEnabled == true)

        unsetenv("AI_ENABLED")
        #expect(AICostControls.isEnabled == true)
    }

    @Test("AI_PROACTIVE_TIPS_ENABLED respects global kill switch")
    func tipsKillSwitch() {
        defer {
            unsetenv("AI_ENABLED")
            unsetenv("AI_PROACTIVE_TIPS_ENABLED")
        }
        setenv("AI_ENABLED", "false", 1)
        setenv("AI_PROACTIVE_TIPS_ENABLED", "true", 1)
        #expect(AICostControls.proactiveTipsEnabled == false)

        setenv("AI_ENABLED", "true", 1)
        setenv("AI_PROACTIVE_TIPS_ENABLED", "off", 1)
        #expect(AICostControls.proactiveTipsEnabled == false)

        setenv("AI_PROACTIVE_TIPS_ENABLED", "true", 1)
        #expect(AICostControls.proactiveTipsEnabled == true)
    }

    @Test("Daily and free monthly limits parse with sane floors")
    func limitParsing() {
        defer {
            unsetenv("AI_DAILY_LIMIT")
            unsetenv("AI_FREE_MONTHLY_LIMIT")
        }
        unsetenv("AI_DAILY_LIMIT")
        unsetenv("AI_FREE_MONTHLY_LIMIT")
        #expect(AICostControls.dailyLimit == 50)
        #expect(AICostControls.freeMonthlyLimit == 5)

        setenv("AI_DAILY_LIMIT", "20", 1)
        setenv("AI_FREE_MONTHLY_LIMIT", "3", 1)
        #expect(AICostControls.dailyLimit == 20)
        #expect(AICostControls.freeMonthlyLimit == 3)

        setenv("AI_DAILY_LIMIT", "0", 1)
        setenv("AI_FREE_MONTHLY_LIMIT", "-1", 1)
        #expect(AICostControls.dailyLimit == 1)
        #expect(AICostControls.freeMonthlyLimit == 0)
    }

    @Test("The view-summary allowance is separate from the shared daily limit")
    func viewSummaryLimitIsIndependent() {
        defer {
            unsetenv("AI_DAILY_LIMIT")
            unsetenv("AI_VIEW_SUMMARY_DAILY_LIMIT")
        }
        unsetenv("AI_DAILY_LIMIT")
        unsetenv("AI_VIEW_SUMMARY_DAILY_LIMIT")
        #expect(AICostControls.viewSummaryDailyLimit == 25)

        // Turning one down must not move the other: the point of the split is
        // that summaries cannot starve the assistant.
        setenv("AI_DAILY_LIMIT", "1", 1)
        #expect(AICostControls.viewSummaryDailyLimit == 25)

        setenv("AI_VIEW_SUMMARY_DAILY_LIMIT", "4", 1)
        #expect(AICostControls.viewSummaryDailyLimit == 4)
        #expect(AICostControls.dailyLimit == 1)

        setenv("AI_VIEW_SUMMARY_DAILY_LIMIT", "0", 1)
        #expect(AICostControls.viewSummaryDailyLimit == 1, "floor of one, as elsewhere")
    }

    @Test("The two allowances count in different Redis buckets")
    func bucketsAreDistinct() {
        #expect(AICostControls.viewSummaryBucket != AIDailyCap.defaultBucket)
    }

    @Test("The usage month is the UTC month, not the machine's local month")
    func usageMonthStartIsUTC() throws {
        let formatter = ISO8601DateFormatter()
        // Already September in any zone east of UTC, still August in UTC.
        let instant = try #require(formatter.date(from: "2026-08-31T23:30:00Z"))

        #expect(AICostControls.usageMonthStart(for: instant)
            == formatter.date(from: "2026-08-01T00:00:00Z")!)
    }

    @Test("Two instants in one UTC month share a usage month, across a local day boundary")
    func usageMonthStartIsStableWithinAMonth() throws {
        let formatter = ISO8601DateFormatter()
        let early = try #require(formatter.date(from: "2026-09-01T00:30:00Z"))
        let late = try #require(formatter.date(from: "2026-09-30T23:30:00Z"))

        #expect(AICostControls.usageMonthStart(for: early) == AICostControls.usageMonthStart(for: late))
    }
}
