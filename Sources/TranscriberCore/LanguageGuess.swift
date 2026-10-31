import Foundation
import NaturalLanguage

/// Detects the languages used in a transcript with macOS's NaturalLanguage framework.
public enum LanguageGuess {
    /// Languages covering at least `minimumShare` of the text, most used first.
    public static func dominantLanguages(in texts: [String], minimumShare: Double = 0.1) -> [String] {
        var characters: [String: Int] = [:]
        let recognizer = NLLanguageRecognizer()
        for text in texts where text.count >= 20 {
            recognizer.reset()
            recognizer.processString(text)
            guard let language = recognizer.dominantLanguage, language != .undetermined else { continue }
            characters[language.rawValue, default: 0] += text.count
        }
        let total = characters.values.reduce(0, +)
        guard total > 0 else { return [] }
        return characters
            .filter { Double($0.value) / Double(total) >= minimumShare }
            .sorted { $0.value > $1.value }
            .map(\.key)
    }

    /// "it" → "Italian"
    public static func displayName(_ code: String) -> String {
        let name = Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
