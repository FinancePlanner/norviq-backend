import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Standing-task intent classifier")
struct AIWatchIntentClassifierTests {
    @Test("'watch X and tell me when Y' is a conditional watch, hourly by default")
    func conditionalWatch() throws {
        let intent = try #require(AIWatchIntentClassifier.classify("Watch NVDA and tell me when it drops below 100"))
        #expect(intent.subject == "NVDA")
        #expect(intent.condition == "it drops below 100")
        #expect(intent.title == "Watch NVDA")
        #expect(intent.intervalMinutes == 60)
        #expect(intent.scheduleHuman == "Every hour")
        #expect(intent.confirmationText == "Got it — I'll watch NVDA and ping you when it drops below 100.")
        #expect(intent.spec == "Watch NVDA and tell me when it drops below 100")
    }

    @Test("Pronouns are turned round in the confirmation")
    func secondPerson() throws {
        let intent = try #require(AIWatchIntentClassifier.classify("keep an eye on my grocery spending and let me know if it goes over 400"))
        #expect(intent.confirmationText == "Got it — I'll watch your grocery spending and ping you when it goes over 400.")
    }

    @Test("'every morning check …' is a scheduled report anchored at 8:00")
    func everyMorning() throws {
        let intent = try #require(AIWatchIntentClassifier.classify("Every morning check my budget and tell me what's left"))
        #expect(intent.condition == nil)
        #expect(intent.intervalMinutes == 1440)
        #expect(intent.scheduleHuman == "Every day at 8:00")
        #expect(intent.hour == 8)
        #expect(intent.title == "Check my budget and tell me what's left")
        #expect(intent.confirmationText.hasPrefix("Got it — I'll check your budget and tell you what's left every day at 8:00"))
    }

    @Test("Explicit times, weekdays and hour intervals parse")
    func schedules() throws {
        let daily = try #require(AIWatchIntentClassifier.classify("send me a spending recap every day at 7:30 pm"))
        #expect(daily.scheduleHuman == "Every day at 19:30")
        let weekly = try #require(AIWatchIntentClassifier.classify("every Monday summarise my portfolio"))
        #expect(weekly.scheduleHuman == "Every Monday at 9:00")
        #expect(weekly.weekday == 2)
        #expect(weekly.intervalMinutes == 7 * 1440)
        let hours = try #require(AIWatchIntentClassifier.classify("check my portfolio every 4 hours"))
        #expect(hours.intervalMinutes == 240)
        #expect(hours.scheduleHuman == "Every 4 hours")
    }

    @Test("Nothing runs more often than hourly")
    func minimumInterval() throws {
        let intent = try #require(AIWatchIntentClassifier.classify("check AAPL every 5 minutes"))
        #expect(intent.intervalMinutes == 60)
    }

    @Test("'ping me when …' without a watch verb is a watch")
    func pingMe() throws {
        let intent = try #require(AIWatchIntentClassifier.classify("Ping me when my savings rate drops under 20%"))
        #expect(intent.condition == "my savings rate drops under 20%")
        #expect(intent.confirmationText == "Got it — I'll keep an eye on it and ping you when your savings rate drops under 20%.")
    }

    @Test("Ordinary questions and one-off requests are not standing tasks", arguments: [
        "How much did I spend on groceries?",
        "Tell me if I overspent this month",
        "How much do I spend every day?",
        "What is my portfolio worth?",
        "Add a 12 euro lunch expense",
        "/dd NVDA",
        "watch out",
    ])
    func negatives(text: String) {
        #expect(AIWatchIntentClassifier.classify(text) == nil)
    }

    @Test("The first run lands on the next local anchor")
    func firstRun() throws {
        let intent = try #require(AIWatchIntentClassifier.classify("every morning check my budget"))
        let zone = try #require(TimeZone(identifier: "Europe/Lisbon"))
        // 2026-09-23 10:00 UTC = 11:00 Lisbon, past 8:00 → tomorrow 8:00 Lisbon = 07:00 UTC.
        let now = Date(timeIntervalSince1970: 1_790_157_600)
        let first = intent.firstRunAt(after: now, timeZone: zone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.day, .hour, .minute], from: first)
        #expect(parts.hour == 8)
        #expect(parts.minute == 0)
        #expect(first > now)
        #expect(first.timeIntervalSince(now) < 86400)
    }
}
