import Foundation

/// A piece of text with its interval in the audio: a word (final version)
/// or a sentence (live draft).
public struct TimedText: Equatable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    /// Who says it ("Speaker 1"), if the voices were separated.
    public var speaker: String?

    public init(text: String, start: TimeInterval, end: TimeInterval, speaker: String? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

public struct Paragraph: Equatable, Sendable {
    public var start: TimeInterval
    public var text: String
    public var speaker: String?

    public init(start: TimeInterval, text: String, speaker: String? = nil) {
        self.start = start
        self.text = text
        self.speaker = speaker
    }

    /// "[00:01:12] text", or "[00:01:12] Speaker 1: text".
    public var rendered: String {
        let stamp = "[\(Timestamp.format(start))]"
        guard let speaker else { return "\(stamp) \(text)" }
        return "\(stamp) \(speaker): \(text)"
    }
}

/// Groups words or sentences into paragraphs: a new one starts when the speaker changes, after a
/// long pause, or at the end of a sentence once the paragraph is already long.
public struct ParagraphBuilder: Sendable {
    /// Silence that always starts a new paragraph.
    public var pauseThreshold: TimeInterval
    /// Past this duration, break at the next end of sentence.
    public var softMaxDuration: TimeInterval
    /// Past this duration, break anyway.
    public var hardMaxDuration: TimeInterval
    /// Parakeet stretches the last word before a silence well into the pause:
    /// when measuring pauses, a word lasts at most this long.
    public var unitDurationCap: TimeInterval?

    public init(
        pauseThreshold: TimeInterval = 1.6, softMaxDuration: TimeInterval = 40, hardMaxDuration: TimeInterval = 90,
        unitDurationCap: TimeInterval? = nil
    ) {
        self.pauseThreshold = pauseThreshold
        self.softMaxDuration = softMaxDuration
        self.hardMaxDuration = hardMaxDuration
        self.unitDurationCap = unitDurationCap
    }

    /// For the words of the final version.
    public static let words = ParagraphBuilder(pauseThreshold: 1.4, unitDurationCap: 0.8)
    /// For the sentences of the live draft.
    public static let sentences = ParagraphBuilder()

    public func build(_ units: [TimedText]) -> [Paragraph] {
        var paragraphs: [Paragraph] = []
        var words: [String] = []
        var paragraphStart: TimeInterval = 0
        var paragraphSpeaker: String?
        var lastEnd: TimeInterval = 0

        func flush() {
            guard !words.isEmpty else { return }
            paragraphs.append(Paragraph(start: paragraphStart, text: words.joined(separator: " "), speaker: paragraphSpeaker))
            words.removeAll()
        }

        for unit in units {
            let text = unit.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if let previous = words.last {
                let gap = unit.start - lastEnd
                let length = unit.start - paragraphStart
                let breakHere = unit.speaker != paragraphSpeaker
                    || gap >= pauseThreshold
                    || (length >= softMaxDuration && Self.endsSentence(previous))
                    || length >= hardMaxDuration
                if breakHere { flush() }
            }
            if words.isEmpty {
                paragraphStart = unit.start
                paragraphSpeaker = unit.speaker
            }
            words.append(text)
            let end = unitDurationCap.map { min(unit.end, unit.start + $0) } ?? unit.end
            lastEnd = max(lastEnd, end)
        }
        flush()
        return paragraphs
    }

    public static func render(_ paragraphs: [Paragraph]) -> String {
        paragraphs.map(\.rendered).joined(separator: "\n\n")
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'»”)")).last else { return false }
        return ".?!…".contains(last)
    }
}
