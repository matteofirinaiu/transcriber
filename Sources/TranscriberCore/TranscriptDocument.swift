import CryptoKit
import Foundation

/// A transcript saved as Markdown with a small YAML frontmatter.
public struct TranscriptDocument: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case final
        case draft

        /// Also reads the Italian values written by the first versions ("finale", "bozza").
        init?(frontmatter value: String) {
            switch value {
            case "final", "finale": self = .final
            case "draft", "bozza": self = .draft
            default: return nil
            }
        }
    }

    /// Stays the same even if you rename the transcript (and therefore the file).
    public var id: UUID
    public var title: String
    public var date: Date
    public var duration: TimeInterval
    /// ISO codes of the recognized languages, most used first (e.g. `["en", "it"]`).
    public var languages: [String]
    /// The people who speak, as they appear in the text ("Speaker 1", or the name given).
    public var speakers: [String]
    public var kind: Kind
    /// The `[hh:mm:ss] text` paragraphs, separated by a blank line.
    public var body: String

    public init(
        id: UUID = UUID(), title: String, date: Date, duration: TimeInterval, languages: [String],
        speakers: [String] = [], kind: Kind, body: String
    ) {
        self.id = id
        self.title = title
        // The file stores the date to the second: rounding now means reading it back gives the same value.
        self.date = date.roundedToSeconds
        self.duration = duration
        self.languages = languages
        self.speakers = speakers
        self.kind = kind
        self.body = body
    }

    /// Title and text, without frontmatter: what goes to the clipboard and into the `.txt`.
    public var plainText: String {
        "\(title)\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }
}

extension Date {
    var roundedToSeconds: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}

public enum TranscriptMarkdown {
    public static func render(_ document: TranscriptDocument) -> String {
        var lines = ["---"]
        lines.append("title: \(quoted(document.title))")
        lines.append("date: \(isoFormatter().string(from: document.date))")
        lines.append("duration: \(Timestamp.format(document.duration))")
        if !document.languages.isEmpty {
            lines.append("languages: \(document.languages.joined(separator: ", "))")
        }
        if !document.speakers.isEmpty {
            lines.append("speakers: \(document.speakers.joined(separator: ", "))")
        }
        lines.append("version: \(document.kind.rawValue)")
        lines.append("id: \(document.id.uuidString)")
        lines.append("---")
        lines.append("")
        lines.append("# \(document.title)")
        lines.append("")
        lines.append(document.body.trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Also reads hand-edited files: without frontmatter it uses the `#` title or the fallback one.
    public static func parse(_ text: String, fallbackTitle: String, fallbackDate: Date, fallbackID: UUID = UUID()) -> TranscriptDocument {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var fields: [String: String] = [:]
        var index = 0

        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                fields[key] = unquoted(value)
            }
            index = end + 1
        }

        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
        var headingTitle: String?
        if index < lines.count, lines[index].hasPrefix("# ") {
            headingTitle = String(lines[index].dropFirst(2)).trimmingCharacters(in: .whitespaces)
            index += 1
        }
        let body = index < lines.count
            ? lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        // The first versions wrote the keys in Italian.
        func field(_ key: String, legacy: String) -> String? { fields[key] ?? fields[legacy] }
        func list(_ key: String, legacy: String) -> [String] {
            (field(key, legacy: legacy) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let title = [field("title", legacy: "titolo"), headingTitle].compactMap { $0 }.first { !$0.isEmpty } ?? fallbackTitle
        let date = field("date", legacy: "data").flatMap { isoFormatter().date(from: $0) } ?? fallbackDate
        let duration = field("duration", legacy: "durata").flatMap(Timestamp.parse) ?? 0
        let kind = field("version", legacy: "versione").flatMap(TranscriptDocument.Kind.init(frontmatter:)) ?? .final
        let id = fields["id"].flatMap(UUID.init(uuidString:)) ?? fallbackID

        return TranscriptDocument(
            id: id, title: title, date: date, duration: duration, languages: list("languages", legacy: "lingue"),
            speakers: list("speakers", legacy: "persone"), kind: kind, body: body)
    }

    /// For hand-written files without an `id`: always the same UUID for the same path.
    public static func stableID(for url: URL) -> UUID {
        let digest = Array(SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }

    static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }

    static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func unquoted(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            var result = ""
            var escaping = false
            for character in value.dropFirst().dropLast() {
                if escaping {
                    result.append(character)
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else {
                    result.append(character)
                }
            }
            return result
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }
}
