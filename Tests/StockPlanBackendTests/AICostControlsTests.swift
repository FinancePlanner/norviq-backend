import Foundation
@testable import StockPlanBackend
import Testing

@Suite("AICostControls", .serialized)
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
}
