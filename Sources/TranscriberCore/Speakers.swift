import Foundation

/// A stretch in which a given voice speaks, as returned by speaker separation.
public struct SpeakerSpan: Equatable, Sendable {
    public var speaker: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// Joins the words of the transcript with the separated voices.
public enum SpeakerAssignment {
    /// Labels each word with who says it, calling people "Speaker 1", "Speaker 2"…
    /// in the order they first speak. If only one voice is heard, no labels.
    public static func label(_ words: [TimedText], with spans: [SpeakerSpan], namePrefix: String = "Speaker") -> [TimedText] {
        guard !words.isEmpty, !spans.isEmpty else { return words }

        var voices = words.map { voice(for: $0, in: spans) }
        // Words outside every voice take the voice of the word before (or, at the start, of the word after).
        for index in voices.indices.dropFirst() where voices[index] == nil { voices[index] = voices[index - 1] }
        for index in voices.indices.reversed().dropFirst() where voices[index] == nil { voices[index] = voices[index + 1] }
        // A single, very short word between two words of the same person is almost always noise.
        if voices.count >= 3 {
            for index in 1..<(voices.count - 1)
            where voices[index] != voices[index - 1] && voices[index - 1] == voices[index + 1]
                && words[index].end - words[index].start < 0.6 {
                voices[index] = voices[index - 1]
            }
        }

        voices = snapChangesToBoundaries(voices, words: words)

        var names: [String: String] = [:]
        for case let voice? in voices where names[voice] == nil {
            names[voice] = "\(namePrefix) \(names.count + 1)"
        }
        guard names.count > 1 else { return words }
        return zip(words, voices).map { word, voice in
            var labeled = word
            labeled.speaker = voice.flatMap { names[$0] }
            return labeled
        }
    }

    /// The speaker almost always changes at a pause or at the end of a sentence, while speaker separation
    /// gets the boundaries wrong by up to a second. A change in the middle of a sentence, without a pause,
    /// moves to the nearest boundary within `limit` seconds; changes already at a pause or after a full stop stay.
    static func snapChangesToBoundaries(_ voices: [String?], words: [TimedText], limit: TimeInterval = 1.5) -> [String?] {
        var voices = voices
        /// (Effective) end of the word before boundary `index`.
        func boundaryTime(_ index: Int) -> TimeInterval {
            let previous = words[index - 1]
            return min(previous.end, previous.start + 0.8)
        }
        /// There is a natural boundary between word `index - 1` and word `index`.
        func isBoundary(_ index: Int) -> Bool {
            guard index > 0, index < words.count else { return true }
            return words[index].start - boundaryTime(index) >= 0.3 || ParagraphBuilder.endsSentence(words[index - 1].text)
        }

        var index = 1
        while index < voices.count {
            defer { index += 1 }
            guard voices[index] != voices[index - 1], !isBoundary(index) else { continue }
            let change = words[index].start
            let before = voices[index - 1]
            let after = voices[index]

            var forward: Int?
            var candidate = index + 1
            while candidate < words.count, boundaryTime(candidate) - change <= limit, voices[candidate - 1] == after {
                if isBoundary(candidate) {
                    forward = candidate
                    break
                }
                candidate += 1
            }
            var backward: Int?
            candidate = index - 1
            while candidate > 0, change - boundaryTime(candidate) <= limit, voices[candidate] == before {
                if isBoundary(candidate) {
                    backward = candidate
                    break
                }
                candidate -= 1
            }

            switch (forward, backward) {
            case let (forward?, backward?) where change - boundaryTime(backward) < boundaryTime(forward) - change:
                for moved in backward..<index { voices[moved] = after }
            case let (forward?, _):
                for moved in index..<forward { voices[moved] = before }
                index = forward - 1
            case let (nil, backward?):
                for moved in backward..<index { voices[moved] = after }
            case (nil, nil):
                break
            }
        }
        return voices
    }

    /// The voice that covers the word the most. As for paragraphs, a word lasts at most 0.8 s:
    /// Parakeet stretches the last word before a pause, which would otherwise spill onto the next speaker.
    static func voice(for word: TimedText, in spans: [SpeakerSpan]) -> String? {
        let start = word.start
        let end = min(word.end, word.start + 0.8)
        var best: (speaker: String, overlap: TimeInterval)?
        for span in spans {
            let overlap = min(end, span.end) - max(start, span.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (span.speaker, overlap) }
        }
        if let best { return best.speaker }

        let middle = (start + end) / 2
        func distance(_ span: SpeakerSpan) -> TimeInterval {
            middle < span.start ? span.start - middle : max(0, middle - span.end)
        }
        guard let nearest = spans.min(by: { distance($0) < distance($1) }), distance(nearest) <= 1 else { return nil }
        return nearest.speaker
    }
}

/// Speaker names in the text: "[00:01:12] Speaker 1: …".
public enum SpeakerNames {
    /// Removes the characters that would confuse the file (commas, colons, line breaks, square brackets).
    public static func clean(_ name: String) -> String {
        let pieces = name.components(separatedBy: CharacterSet(charactersIn: ",:[]\n\r\t"))
        let collapsed = pieces.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(40))
    }

    /// Renames a speaker at the start of each of their paragraphs.
    public static func rename(_ old: String, to new: String, in body: String) -> String {
        let oldPrefix = " \(old): "
        return body.components(separatedBy: "\n").map { line in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return line }
            let rest = line[line.index(after: close)...]
            guard rest.hasPrefix(oldPrefix) else { return line }
            return String(line[...close]) + " \(new): " + rest.dropFirst(oldPrefix.count)
        }
        .joined(separator: "\n")
    }

    /// Without duplicates, in the original order (giving two speakers the same name merges them).
    public static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}
