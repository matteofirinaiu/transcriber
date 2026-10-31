import AVFoundation
import Speech
import TranscriberCore

enum LiveError: LocalizedError {
    case unavailable
    case unsupported(DraftLanguage)
    case noAudioFormat

    var errorDescription: String? {
        switch self {
        case .unavailable: "macOS speech recognition isn't available on this Mac."
        case .unsupported(let language): "macOS speech recognition doesn't support \(language.label)."
        case .noAudioFormat: "Speech recognition doesn't accept the microphone's audio."
        }
    }
}

/// Live draft. With English or Italian it uses macOS 26's SpeechAnalyzer; with Automatic it uses
/// Parakeet sentence by sentence (see UtteranceTranscriber). Either way, everything happens on the Mac.
@MainActor
final class LiveTranscriber {
    /// A confirmed sentence, with times relative to the start of the recording.
    var onSegment: ((DraftSegment) -> Void)?
    /// The tentative text that is still changing.
    var onVolatile: ((String) -> Void)?
    /// Messages such as the download of the Italian model; `nil` when there's nothing to say.
    var onStatus: ((String?) -> Void)?

    /// An active draft: where the audio goes, and how to close it while waiting for the last sentences.
    private struct Run {
        let sink: LiveAudioSink
        let finish: () async -> Void
    }

    private final class OffsetBox {
        var seconds: TimeInterval = 0
    }

    private let engine: ParakeetEngine
    private var run: Run?

    init(engine: ParakeetEngine) {
        self.engine = engine
    }

    /// Starts the draft, or switches language during a recording. `attach` connects the audio input
    /// to the recording and returns the seconds already recorded, used as the start time.
    func start(language: DraftLanguage, attach: (LiveAudioSink) -> TimeInterval) async throws {
        let newRun: Run
        if let locale = language.appleLocale {
            newRun = try await startApple(language, locale: locale, attach: attach)
        } else {
            newRun = try await startAutomatic(attach: attach)
        }
        let previous = run
        run = newRun
        onStatus?(nil)
        await previous?.finish()
    }

    /// Confirms the last sentence and closes the draft.
    func stop() async {
        guard let current = run else { return }
        run = nil
        await current.finish()
        onVolatile?("")
    }

    private func startApple(_ language: DraftLanguage, locale: Locale, attach: (LiveAudioSink) -> TimeInterval) async throws -> Run {
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        try await Self.installAssets(for: language, transcriber: transcriber) { [weak self] status in
            self?.onStatus?(status)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw LiveError.noAudioFormat
        }
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let feed = AnalyzerFeed(continuation: continuation, format: format)
        let offset = OffsetBox()
        let results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let self else { continue }
                    if result.isFinal {
                        self.onVolatile?("")
                        // With the wrong language the recognizer sometimes returns nothing but commas.
                        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                        let start = result.range.start.seconds
                        let end = result.range.end.seconds
                        self.onSegment?(DraftSegment(
                            start: offset.seconds + (start.isFinite ? start : 0),
                            end: offset.seconds + (end.isFinite ? end : 0),
                            text: text))
                    } else {
                        self.onVolatile?(text)
                    }
                }
            } catch {
                self?.onStatus?("The live draft stopped: \(error.localizedDescription)")
            }
        }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            results.cancel()
            throw error
        }

        offset.seconds = attach(feed)
        return Run(sink: feed) {
            feed.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            await results.value
        }
    }

    private func startAutomatic(attach: (LiveAudioSink) -> TimeInterval) async throws -> Run {
        let models = try await engine.asrModels()
        let vad = try await engine.vadManager()

        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        let feed = SampleFeed(continuation: continuation)
        let offset = attach(feed) // from here on, audio piles up in the stream until the worker starts
        let worker = await UtteranceTranscriber.make(
            models: models, vad: vad, offset: offset, volatileUpdates: true,
            onUtterance: { utterance in
                let segment = DraftSegment(start: utterance.start, end: utterance.end, text: utterance.text)
                await MainActor.run { self.onSegment?(segment) }
            },
            onVolatile: { text in await MainActor.run { self.onVolatile?(text) } })
        let consumer = Task.detached {
            for await samples in stream { await worker.consume(samples) }
            await worker.finish()
        }
        return Run(sink: feed) {
            feed.finish()
            await consumer.value
        }
    }

    // MARK: - macOS speech models

    static func assetStatus(for language: DraftLanguage) async -> AssetInventory.Status {
        guard let locale = language.appleLocale else { return .unsupported }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        return await AssetInventory.status(forModules: [transcriber])
    }

    /// Downloads the language model (from Apple) if it's missing. English is usually already on the Mac.
    static func installAssets(
        for language: DraftLanguage,
        transcriber: SpeechTranscriber? = nil,
        status: @escaping @MainActor (String?) -> Void
    ) async throws {
        guard let locale = language.appleLocale else { return }
        guard SpeechTranscriber.isAvailable else { throw LiveError.unavailable }
        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            throw LiveError.unsupported(language)
        }
        let transcriber = transcriber ?? SpeechTranscriber(locale: locale, preset: .transcription)

        let wanted = locale.identifier(.bcp47)
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == wanted }) {
            if reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
                await AssetInventory.release(reservedLocale: oldest)
            }
            _ = try? await AssetInventory.reserve(locale: locale)
        }

        if await AssetInventory.status(forModules: [transcriber]) == .installed { return }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let progress = request.progress
        let reporter = Task { @MainActor in
            while !Task.isCancelled {
                status("Downloading the \(language.label) speech model from Apple: \(Int(progress.fractionCompleted * 100))%")
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { reporter.cancel() }
        try await request.downloadAndInstall()
        status(nil)
    }
}
