import os

/// Diagnostic intervals only: state publication is not a rendered frame, and
/// handler entry is not the original input event. See docs/PERFORMANCE_BASELINE.md.
/// No account IDs, amounts, search text, paths or error descriptions are logged.
enum LedgerPerformance {
    private static let signposter = OSSignposter(subsystem: "app.vince.ledger", category: "Performance")

    enum Outcome: String {
        case completed
        case threw
        case notApplied
    }

    struct Interval {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState?
    }

    static func begin(_ name: StaticString) -> Interval {
        guard signposter.isEnabled else { return Interval(name: name, state: nil) }
        return Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()))
    }

    /// Each begun interval must be ended exactly once, preferably with defer.
    static func end(_ interval: Interval, outcome: Outcome = .completed) {
        guard let state = interval.state else { return }
        signposter.endInterval(interval.name, state, "outcome=\(outcome.rawValue, privacy: .public)")
    }

    static func measure<Value>(_ name: StaticString, _ work: () throws -> Value) rethrows -> Value {
        let interval = begin(name)
        var outcome = Outcome.threw
        defer { end(interval, outcome: outcome) }
        let value = try work()
        outcome = .completed
        return value
    }
}
