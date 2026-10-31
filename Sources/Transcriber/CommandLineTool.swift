import Foundation
import os
import TranscriberCore

/// Terminal commands to try both engines without a microphone:
///
///     Transcriber.app/Contents/MacOS/Transcriber --final audio.wav [--speakers N | --no-speakers] [--words]
///     Transcriber.app/Contents/MacOS/Transcriber --live audio.wav [auto|en|it]
///     Transcriber.app/Contents/MacOS/Transcriber --assets [--download]
@MainActor
enum CommandLineTool {
    enum CLIError: LocalizedError {
        case missingFile

        var errorDescription: String? { "The path of the audio file is missing." }
    }

    nonisolated static let commands: Set<String> = ["--final", "--live", "--assets"]

    static func run(_ arguments: [String]) async -> Int32 {
        do {
            switch arguments.first {
            case "--final":
                let speakers = arguments.firstIndex(of: "--speakers").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
                try await final(path: arguments.dropFirst().first, expectedSpeakers: speakers)
            case "--live":
                try await live(path: arguments.dropFirst().first, language: arguments.dropFirst(2).first)
            case "--assets":
                try await assets(download: arguments.contains("--download"))
            default:
                print("Usage: Transcriber --final file.wav [--speakers N | --no-speakers] [--words] | --live file.wav [auto|en|it] [--segments] | --assets [--download]")
                return 2
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func final(path: String?, expectedSpeakers: Int?) async throws {
        guard let path else { throw CLIError.missingFile }
        let url = URL(fileURLWithPath: path)
        let engine = ParakeetEngine()

        var loadStart = Date()
        let lastPrinted = OSAllocatedUnfairLock(initialState: -10)
        _ = try await engine.asrModels { fraction in
            let percent = Int(fraction * 100)
            let shouldPrint = lastPrinted.withLock { last in
                guard percent / 10 != last / 10 else { return false }
                last = percent
                return true
            }
            if shouldPrint { print("Model: \(percent)%") }
        }
        print(String(format: "Model ready in %.1f s", Date().timeIntervalSince(loadStart)))

        let duration = AudioConversion.duration(of: url)
        loadStart = Date()
        let words = try await engine.transcribe(fileURL: url) { _ in }
        let elapsed = Date().timeIntervalSince(loadStart)
        let diarizeStart = Date()
        let spans = CommandLine.arguments.contains("--no-speakers")
            ? [] : try await engine.diarize(fileURL: url, expectedSpeakers: expectedSpeakers) { _ in }
        let diarizeElapsed = Date().timeIntervalSince(diarizeStart)
        let labeled = SpeakerAssignment.label(words, with: spans)
        let paragraphs = ParagraphBuilder.words.build(labeled)

        print(ParagraphBuilder.render(paragraphs))
        if CommandLine.arguments.contains("--words") {
            for word in labeled {
                print(String(format: "%7.2f %7.2f  %@  %@", word.start, word.end, word.text, word.speaker ?? "-"))
            }
            for span in spans { print(String(format: "voice %@ %7.2f %7.2f", span.speaker, span.start, span.end)) }
        }
        print("---")
        print(String(format: "Audio %.1f s, transcribed in %.1f s (%.0fx real time), %d words",
                     duration, elapsed, duration / max(elapsed, 0.001), words.count))
        print("Languages: \(LanguageGuess.dominantLanguages(in: paragraphs.map(\.text)))")
        print(String(format: "Voices separated in %.1f s: %@ (%d spans)",
                     diarizeElapsed, SpeakerNames.unique(labeled.compactMap(\.speaker)).joined(separator: ", "), spans.count))
    }

    private static func live(path: String?, language: String?) async throws {
        guard let path else { throw CLIError.missingFile }
        let draftLanguage = DraftLanguage(rawValue: language ?? "auto") ?? .automatic
        let transcriber = LiveTranscriber(engine: ParakeetEngine())
        var segments: [DraftSegment] = []
        transcriber.onSegment = { segments.append($0) }
        transcriber.onStatus = { status in if let status { print(status) } }

        let start = Date()
        var feed: LiveAudioSink?
        try await transcriber.start(language: draftLanguage) { newFeed in
            feed = newFeed
            return 0
        }
        for buffer in try AudioConversion.readFile(URL(fileURLWithPath: path)) { feed?.feed(buffer) }
        await transcriber.stop()

        let paragraphs = ParagraphBuilder.sentences.build(segments.map(\.timedText))
        print(ParagraphBuilder.render(paragraphs))
        if CommandLine.arguments.contains("--segments") {
            for segment in segments { print(String(format: "%7.2f %7.2f  %@", segment.start, segment.end, segment.text)) }
        }
        print("---")
        print(String(format: "%@ draft in %.1f s, %d sentences", draftLanguage.label, Date().timeIntervalSince(start), segments.count))
    }

    private static func assets(download: Bool) async throws {
        for language in DraftLanguage.appleLanguages {
            print("\(language.label): \(await LiveTranscriber.assetStatus(for: language))")
            if download {
                try await LiveTranscriber.installAssets(for: language) { status in if let status { print(status) } }
                print("\(language.label): \(await LiveTranscriber.assetStatus(for: language))")
            }
        }
    }
}
