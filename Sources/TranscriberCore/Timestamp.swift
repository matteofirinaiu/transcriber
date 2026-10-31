import Foundation

/// Times as `hh:mm:ss`, used both in paragraphs and for the duration.
public enum Timestamp {
    public static func format(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// Accepts `hh:mm:ss` or `mm:ss`.
    public static func parse(_ text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Int($0) }
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let values = parts.compactMap { $0 }
        if values.count == 2 { return TimeInterval(values[0] * 60 + values[1]) }
        return TimeInterval(values[0] * 3600 + values[1] * 60 + values[2])
    }
}
