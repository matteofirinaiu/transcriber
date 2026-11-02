import AVFoundation
import TranscriberCore

/// Live draft: the voice detector cuts the audio at pauses and Parakeet transcribes each sentence,
/// detecting its language (see UtteranceTranscriber). Everything happens on the Mac.
@MainActor
final class LiveTranscriber {
    /// A confirmed sentence, with times relative to the start of the recording.
    var onSegment: ((DraftSegment) -> Void)?
    /// The tentative text that is still changing.
    var onVolatile: ((String) -> Void)?

    /// The running draft: where the audio goes, and how to close it while waiting for the last sentences.
    private struct Run {
        let sink: LiveAudioSink
        let finish: () async -> Void
    }

    private let engine: ParakeetEngine
    private var run: Run?

    init(engine: ParakeetEngine) {
        self.engine = engine
    }

    /// Starts the draft. `attach` connects the audio input to the recording and returns the seconds
    /// already recorded, used as the start time.
    func start(attach: (LiveAudioSink) -> TimeInterval) async throws {
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
        let previous = run
        run = Run(sink: feed) {
            feed.finish()
            await consumer.value
        }
        await previous?.finish()
    }

    /// Confirms the last sentence and closes the draft.
    func stop() async {
        guard let current = run else { return }
        run = nil
        await current.finish()
        onVolatile?("")
    }
}
