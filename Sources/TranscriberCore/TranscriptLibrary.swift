import Foundation

public struct StoredTranscript: Identifiable, Equatable, Sendable {
    public var url: URL
    public var document: TranscriptDocument
    public var id: UUID { document.id }

    public init(url: URL, document: TranscriptDocument) {
        self.url = url
        self.document = document
    }

    /// Case- and accent-insensitive search in title and text.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return document.title.localizedStandardContains(query) || document.body.localizedStandardContains(query)
    }
}

/// The transcripts folder: one `.md` file per recording.
public struct TranscriptLibrary: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// `~/Documents/Transcriber`: named after the app rather than "Transcripts", a name often used for other documents.
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriber", isDirectory: true)
    }

    /// "Recording 30 Oct 2026, 15:30": month in letters and 24-hour time, so 10/30 and 30/10 can't be confused.
    public static func defaultTitle(for date: Date) -> String {
        "Recording \(formatted(date, "d MMM yyyy, HH:mm"))"
    }

    public func loadAll() -> [StoredTranscript] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { try? load($0) }
            .sorted { $0.document.date > $1.document.date }
    }

    public func load(_ url: URL) throws -> StoredTranscript {
        let text = try String(contentsOf: url, encoding: .utf8)
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let document = TranscriptMarkdown.parse(
            text, fallbackTitle: url.deletingPathExtension().lastPathComponent, fallbackDate: created,
            fallbackID: TranscriptMarkdown.stableID(for: url))
        return StoredTranscript(url: url, document: document)
    }

    /// Saves the document. If the title changed, the file is renamed.
    @discardableResult
    public func save(_ document: TranscriptDocument, replacing existing: URL?) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let desired = fileName(for: document)
        let target: URL
        if let existing, existing.lastPathComponent == desired {
            target = existing
        } else {
            target = uniqueURL(for: desired)
        }
        try Data(TranscriptMarkdown.render(document).utf8).write(to: target, options: .atomic)
        if let existing, existing != target, FileManager.default.fileExists(atPath: existing.path) {
            try? FileManager.default.removeItem(at: existing)
        }
        return target
    }

    /// "2026-10-30 15.30 Recording.md", or "2026-10-30 15.30 Budget Q4.md" if you renamed it.
    public func fileName(for document: TranscriptDocument) -> String {
        let prefix = Self.formatted(document.date, "yyyy-MM-dd HH.mm")
        let title = document.title == Self.defaultTitle(for: document.date) ? "Recording" : Self.sanitized(document.title)
        return "\(prefix) \(title.isEmpty ? "Recording" : title).md"
    }

    func uniqueURL(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter).md")
            counter += 1
        }
        return candidate
    }

    static func sanitized(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return String(cleaned.prefix(80))
    }

    static func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
