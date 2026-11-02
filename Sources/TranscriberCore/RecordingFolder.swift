import Foundation

/// A confirmed sentence of the live draft.
public struct DraftSegment: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    public var timedText: TimedText { TimedText(text: text, start: start, end: end) }
}

public struct RecordingMeta: Codable, Equatable, Sendable {
    public var id: UUID
    public var startDate: Date
    /// "auto": the live draft detects the language. Recordings from before 1.3.0 may say "en" or "it".
    public var draftLanguage: String
    /// The final version failed: the audio stays so it can be retried.
    public var finalFailed: Bool
    /// How many people speak, if given before recording (`nil` = the app counts them).
    public var expectedSpeakers: Int?

    /// `id` also becomes the transcript's id, so a new attempt replaces the saved draft.
    public init(
        id: UUID = UUID(), startDate: Date = Date(), draftLanguage: String = "auto", finalFailed: Bool = false,
        expectedSpeakers: Int? = nil
    ) {
        self.id = id
        self.startDate = startDate.roundedToSeconds
        self.draftLanguage = draftLanguage
        self.finalFailed = finalFailed
        self.expectedSpeakers = expectedSpeakers
    }
}

/// The temporary folder of a recording: audio, metadata and draft.
/// It is deleted as soon as the final version is saved.
public struct RecordingFolder: Equatable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var audioURL: URL { url.appendingPathComponent("audio.wav") }
    public var metaURL: URL { url.appendingPathComponent("meta.json") }
    public var draftURL: URL { url.appendingPathComponent("draft.json") }

    public static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriber/Recordings", isDirectory: true)
    }

    public static func create(meta: RecordingMeta, in base: URL = baseDirectory) throws -> RecordingFolder {
        let folder = RecordingFolder(url: base.appendingPathComponent(meta.id.uuidString, isDirectory: true))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try folder.saveMeta(meta)
        return folder
    }

    /// Recordings left unfinished (the app quit, or the final version failed).
    public static func pending(in base: URL = baseDirectory) -> [(folder: RecordingFolder, meta: RecordingMeta)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url in
            let folder = RecordingFolder(url: url)
            guard let meta = folder.loadMeta(), FileManager.default.fileExists(atPath: folder.audioURL.path) else { return nil }
            return (folder, meta)
        }
        .sorted { $0.meta.startDate < $1.meta.startDate }
    }

    public func saveMeta(_ meta: RecordingMeta) throws {
        try Self.encoder.encode(meta).write(to: metaURL, options: .atomic)
    }

    public func loadMeta() -> RecordingMeta? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? Self.decoder.decode(RecordingMeta.self, from: data)
    }

    public func saveDraft(_ segments: [DraftSegment]) throws {
        try Self.encoder.encode(segments).write(to: draftURL, options: .atomic)
    }

    public func loadDraft() -> [DraftSegment] {
        guard let data = try? Data(contentsOf: draftURL) else { return [] }
        return (try? Self.decoder.decode([DraftSegment].self, from: data)) ?? []
    }

    public func delete() throws {
        try FileManager.default.removeItem(at: url)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
