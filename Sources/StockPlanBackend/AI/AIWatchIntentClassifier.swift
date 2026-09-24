import Foundation

/// Recognises a request for a standing task in a chat message.
///
/// Two shapes, after Lumina's `JobIntentClassifier` idea but deterministic:
///
/// - **Conditional watch** — "watch NVDA and tell me when it drops below 100",
///   "ping me when my budget goes over 80%". Runs on a schedule, reports only
///   when the condition holds, then switches itself off.
/// - **Scheduled report** — "every morning check my budget", "each Monday
///   summarise my portfolio". Reports on every run.
///
/// Deliberately narrow and model-free: a false positive costs the user a
/// "Not now" tap, but a missed one only means the turn is answered normally,
/// so ambiguous text stays with the model. "Tell me if I overspent" is a
/// question about now and does not match; "ping/notify/alert me when" does.
enum AIWatchIntentClassifier {
    struct Intent: Equatable, Sendable {
        /// Card title, e.g. "Watch NVDA".
        let title: String
        /// What is watched, in the user's words ("NVDA").
        let subject: String
        /// When to report, for conditional watches ("it drops below 100").
        let condition: String?
        let scheduleHuman: String
        let intervalMinutes: Int
        /// Local time of day the task is anchored to, when the user gave one.
        let hour: Int?
        let minute: Int?
        /// 1 = Sunday … 7 = Saturday (Foundation's numbering), for weekly tasks.
        let weekday: Int?
        /// What the job asks the model on each run: the user's own request.
        let spec: String

        var isConditional: Bool {
            condition != nil
        }

        /// "Got it — I'll watch X and ping you when Y".
        var confirmationText: String {
            if let condition, condition == subject {
                return "Got it — I'll keep an eye on it and ping you when \(AIWatchIntentClassifier.secondPerson(condition))."
            }
            if let condition {
                return "Got it — I'll watch \(AIWatchIntentClassifier.secondPerson(subject)) and ping you when \(AIWatchIntentClassifier.secondPerson(condition))."
            }
            let task = AIWatchIntentClassifier.secondPerson(AIWatchIntentClassifier.lowercasedFirst(title))
            return "Got it — I'll \(task) \(AIWatchIntentClassifier.lowercasedFirst(scheduleHuman)) and ping you here."
        }

        /// One line for the pending action's `summary`.
        var summary: String {
            "\(title) · \(scheduleHuman)"
        }

        /// The first run: the next local anchor if one was given, else one
        /// interval from now.
        func firstRunAt(after now: Date, timeZone: TimeZone) -> Date {
            guard let hour else { return now.addingTimeInterval(TimeInterval(intervalMinutes * 60)) }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            var components = DateComponents()
            components.hour = hour
            components.minute = minute ?? 0
            components.second = 0
            if let weekday {
                components.weekday = weekday
            }
            return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
                ?? now.addingTimeInterval(TimeInterval(intervalMinutes * 60))
        }
    }

    /// A model call per run is not free, so nothing runs more often than this.
    static let minimumIntervalMinutes = 60
    static let defaultWatchIntervalMinutes = 60

    static func classify(_ raw: String) -> Intent? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8, text.count <= 500, !text.hasPrefix("/") else { return nil }
        let lower = text.lowercased()
        let schedule = parseSchedule(lower)

        // Conditional: "watch|monitor|keep an eye on|track X and tell|ping|notify|alert|let me (know) when|if Y"
        let watchPattern = #"\b(?:watch|monitor|keep an eye on|keep watching|track)\s+(.+?)\s+(?:and|&)\s+(?:tell|ping|notify|alert|message|text|let)\s+me\s+(?:know\s+)?(?:when|if|once|as soon as)\s+(.+)"#
        if let match = captures(watchPattern, in: text), match.count == 2 {
            let subject = clean(match[0])
            let condition = clean(stripSchedulePhrases(match[1]))
            guard !subject.isEmpty, !condition.isEmpty else { return nil }
            return conditional(subject: subject, condition: condition, schedule: schedule, spec: text)
        }

        // Conditional without a watch verb: only the unmistakably future verbs.
        let pingPattern = #"^(?:please\s+|can you\s+|could you\s+)?(?:ping|notify|alert)\s+me\s+(?:when|if|once|as soon as)\s+(.+)"#
        if let match = captures(pingPattern, in: text), let first = match.first {
            let condition = clean(stripSchedulePhrases(first))
            guard !condition.isEmpty else { return nil }
            return conditional(subject: condition, condition: condition, schedule: schedule, spec: text)
        }

        // Scheduled report: a recurring schedule plus something to do.
        guard let schedule, schedule.explicit else { return nil }
        let verbs = #"\b(?:check|tell|send|give|summari[sz]e|remind|review|report|update|show|ping|let me know|look at|brief|recap)\b"#
        guard lower.range(of: verbs, options: .regularExpression) != nil else { return nil }
        // Questions about a recurring amount ("how much do I spend every day?")
        // are questions, not tasks.
        let questionOpeners = ["how ", "what ", "why ", "when ", "which ", "who ", "is ", "are ", "do ", "does ", "did "]
        guard !questionOpeners.contains(where: { lower.hasPrefix($0) }) else { return nil }

        let task = clean(stripSchedulePhrases(text))
        guard !task.isEmpty else { return nil }
        return Intent(
            title: String(capitalizedFirst(task).prefix(80)),
            subject: task,
            condition: nil,
            scheduleHuman: schedule.human,
            intervalMinutes: schedule.intervalMinutes,
            hour: schedule.hour,
            minute: schedule.minute,
            weekday: schedule.weekday,
            spec: text
        )
    }

    private static func conditional(subject: String, condition: String, schedule: Schedule?, spec: String) -> Intent {
        let schedule = schedule ?? Schedule(
            intervalMinutes: defaultWatchIntervalMinutes, human: "Every hour",
            hour: nil, minute: nil, weekday: nil, explicit: false
        )
        return Intent(
            title: String((subject == condition ? "Ping me when \(condition)" : "Watch \(subject)").prefix(80)),
            subject: subject,
            condition: condition,
            scheduleHuman: schedule.human,
            intervalMinutes: schedule.intervalMinutes,
            hour: schedule.hour,
            minute: schedule.minute,
            weekday: schedule.weekday,
            spec: spec
        )
    }

    // MARK: - Schedule

    struct Schedule: Equatable {
        let intervalMinutes: Int
        let human: String
        let hour: Int?
        let minute: Int?
        let weekday: Int?
        /// False for the default a bare watch gets.
        let explicit: Bool
    }

    static func parseSchedule(_ lower: String) -> Schedule? {
        if let m = captures(#"every\s+(\d{1,3})\s*(?:min|minute)"#, in: lower), let n = Int(m[0]), n > 0 {
            let minutes = max(minimumIntervalMinutes, n)
            return .init(intervalMinutes: minutes, human: hoursHuman(minutes), hour: nil, minute: nil, weekday: nil, explicit: true)
        }
        if let m = captures(#"every\s+(\d{1,2})\s*(?:h|hr|hrs|hour|hours)\b"#, in: lower), let n = Int(m[0]), n > 0 {
            return .init(intervalMinutes: n * 60, human: hoursHuman(n * 60), hour: nil, minute: nil, weekday: nil, explicit: true)
        }
        if lower.contains("hourly") || lower.range(of: #"\b(?:every|each)\s+hour\b"#, options: .regularExpression) != nil {
            return .init(intervalMinutes: 60, human: "Every hour", hour: nil, minute: nil, weekday: nil, explicit: true)
        }

        let time = parseTimeOfDay(lower)
        let weekdays: [(String, Int, String)] = [
            ("sunday", 1, "Sunday"), ("monday", 2, "Monday"), ("tuesday", 3, "Tuesday"),
            ("wednesday", 4, "Wednesday"), ("thursday", 5, "Thursday"), ("friday", 6, "Friday"),
            ("saturday", 7, "Saturday"),
        ]
        for (name, number, display) in weekdays
            where lower.range(of: #"\b(?:every|each|on)\s+"# + name, options: .regularExpression) != nil
        {
            let t = time ?? (9, 0)
            return .init(intervalMinutes: 7 * 1440, human: "Every \(display) at \(clock(t.0, t.1))",
                         hour: t.0, minute: t.1, weekday: number, explicit: true)
        }
        if lower.range(of: #"\b(?:every|each)\s+week\b|\bweekly\b"#, options: .regularExpression) != nil {
            let t = time ?? (9, 0)
            return .init(intervalMinutes: 7 * 1440, human: "Every week at \(clock(t.0, t.1))",
                         hour: t.0, minute: t.1, weekday: 2, explicit: true)
        }

        let dayParts: [(String, (Int, Int))] = [("morning", (8, 0)), ("evening", (18, 0)), ("night", (21, 0)), ("afternoon", (14, 0))]
        for (part, anchor) in dayParts
            where lower.range(of: #"\b(?:every|each)\s+"# + part, options: .regularExpression) != nil
        {
            let t = time ?? anchor
            return .init(intervalMinutes: 1440, human: "Every day at \(clock(t.0, t.1))",
                         hour: t.0, minute: t.1, weekday: nil, explicit: true)
        }
        if lower.range(of: #"\b(?:every|each)\s+day\b|\bdaily\b|\bevery\s+weekday\b"#, options: .regularExpression) != nil {
            let t = time ?? (9, 0)
            return .init(intervalMinutes: 1440, human: "Every day at \(clock(t.0, t.1))",
                         hour: t.0, minute: t.1, weekday: nil, explicit: true)
        }
        return nil
    }

    /// "at 7", "at 7am", "at 7:30 pm", "at 19:00".
    static func parseTimeOfDay(_ lower: String) -> (Int, Int)? {
        guard let m = captures(#"\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?"#, in: lower, allowEmpty: true),
              var hour = Int(m[0])
        else { return nil }
        let minute = m.count > 1 ? Int(m[1]) ?? 0 : 0
        let meridiem = m.count > 2 ? m[2] : ""
        if meridiem.hasPrefix("p"), hour < 12 {
            hour += 12
        }
        if meridiem.hasPrefix("a"), hour == 12 {
            hour = 0
        }
        guard (0 ..< 24).contains(hour), (0 ..< 60).contains(minute) else { return nil }
        return (hour, minute)
    }

    private static func hoursHuman(_ minutes: Int) -> String {
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? "Every hour" : "Every \(hours) hours"
        }
        return "Every \(minutes) minutes"
    }

    private static func clock(_ hour: Int, _ minute: Int) -> String {
        String(format: "%d:%02d", hour, minute)
    }

    // MARK: - Text

    private static func stripSchedulePhrases(_ text: String) -> String {
        let patterns = [
            #"\b(?:every|each)\s+\d{1,3}\s*(?:min|minute|minutes|h|hr|hrs|hour|hours)\b"#,
            #"\b(?:every|each)\s+(?:morning|evening|night|afternoon|day|weekday|week|hour|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
            #"\bon\s+(?:mondays?|tuesdays?|wednesdays?|thursdays?|fridays?|saturdays?|sundays?)\b"#,
            #"\b(?:daily|weekly|hourly)\b"#,
            #"\bat\s+\d{1,2}(?::\d{2})?\s*(?:am|pm|a\.m\.|p\.m\.)?"#,
            #"^(?:please|can you|could you|would you)\s+"#,
        ]
        var result = text
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    private static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, ".!?,;:".contains(last) {
            result.removeLast()
        }
        if result.lowercased().hasPrefix("and ") {
            result.removeFirst(4)
        }
        if result.hasPrefix(", ") {
            result.removeFirst(2)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The user's words, turned round for the assistant's reply.
    static func secondPerson(_ text: String) -> String {
        let swaps = ["my": "your", "me": "you", "i": "you", "i'm": "you're", "mine": "yours", "myself": "yourself"]
        return text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let lower = word.lowercased()
            if let swap = swaps[lower] {
                return swap
            }
            return String(word)
        }.joined(separator: " ")
    }

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // Keep tickers and acronyms ("NVDA") as written.
        let firstWord = text.prefix { $0 != " " }
        if firstWord.count > 1, firstWord == firstWord.uppercased() {
            return text
        }
        return first.lowercased() + text.dropFirst()
    }

    private static func captures(_ pattern: String, in text: String, allowEmpty: Bool = false) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        var result: [String] = []
        for index in 1 ..< match.numberOfRanges {
            if let range = Range(match.range(at: index), in: text) {
                result.append(String(text[range]))
            } else if allowEmpty {
                result.append("")
            }
        }
        return result.isEmpty ? nil : result
    }
}
