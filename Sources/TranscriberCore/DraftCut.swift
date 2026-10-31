import Foundation

/// Where to cut a very long stretch of speech without splitting a word.
public enum DraftCut {
    /// Index of the last word to confirm: it must end within `limit` seconds and, when possible,
    /// close a sentence (full stop, question mark...) in the last `sentenceWindow` seconds.
    public static func index(in words: [TimedText], before limit: TimeInterval, sentenceWindow: TimeInterval = 8) -> Int? {
        guard let last = words.lastIndex(where: { $0.end <= limit }) else { return nil }
        let sentenceEnd = words[...last].lastIndex {
            ParagraphBuilder.endsSentence($0.text) && $0.end >= limit - sentenceWindow
        }
        return sentenceEnd ?? last
    }
}
