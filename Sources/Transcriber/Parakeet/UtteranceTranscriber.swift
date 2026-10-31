import FluidAudio
import Foundation
import TranscriberCore

/// Sentence-by-sentence transcription: the voice detector (Silero) cuts the audio at pauses and Parakeet
/// transcribes each piece, detecting its language, so it follows English and Italian by itself.
/// Used by both the "Automatic" live draft and the final version.
///
/// Two Parakeet pitfalls drive the choices below:
/// - beyond 15 seconds FluidAudio splits the audio into fixed windows and can lose sentences at the cuts,
///   so no piece is longer than that;
/// - if the language changes within a piece (English after Italian), Parakeet can silently drop the
///   second language. That's why pieces also close at short pauses and, if a stretch of speech in a
///   piece ends up without words, that stretch is transcribed again on its own.
actor UtteranceTranscriber {
    /// A confirmed sentence with its words. Times start from the beginning of the recording.
    struct Utterance: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let words: [TimedText]
    }

    typealias UtteranceHandler = @Sendable (Utterance) async -> Void
    typealias VolatileHandler = @Sendable (String) async -> Void

    private static let rate = VadManager.sampleRate
    /// How often the tentative text updates while someone is speaking.
    private static let volatileEvery = rate * 3 / 2
    /// A piece without pauses longer than this is confirmed halfway, between two words.
    private static let longUtterance = rate * 12
    /// The last seconds of a long piece stay tentative: words there can still change.
    private static let unstableTail: TimeInterval = 3
    /// Audio kept aside, because the detector reports the start of speech slightly late.
    private static let history = rate
    /// A stretch of speech without words at least this long is transcribed again on its own.
    private static let minimumGap: TimeInterval = 1

    /// Lower thresholds than the default (0.85): in a room, people far from the Mac come through quieter.
    /// The detector works in 256 ms blocks: with 0.25 s of required silence, a pause of about half a
    /// second is enough to close the piece, so whoever answers usually ends up in a piece of their own.
    private static let segmentation = VadSegmentationConfig(
        minSilenceDuration: 0.25, speechPadding: 0.3, negativeThreshold: 0.35, negativeThresholdOffset: 0.15)

    private let asr: AsrManager
    private let vad: VadManager
    private let decoderLayers: Int
    /// Seconds already recorded when this transcription started.
    private let offset: TimeInterval
    /// Only the live draft shows tentative text while someone speaks.
    private let volatileUpdates: Bool
    private let onUtterance: UtteranceHandler
    private let onVolatile: VolatileHandler

    private var vadState: VadStreamState
    private var unanalyzed: [Float] = []
    /// `audio[0]` is sample number `audioStart` from the beginning of this transcription.
    private var audio: [Float] = []
    private var audioStart = 0
    private var analyzed = 0
    /// Speech probability of each analyzed block, with the sample the block starts at.
    private var speechProbabilities: [(start: Int, value: Float)] = []
    private var utteranceStart: Int?
    private var lastVolatile = 0

    private init(
        asr: AsrManager, vad: VadManager, decoderLayers: Int, vadState: VadStreamState, offset: TimeInterval,
        volatileUpdates: Bool, onUtterance: @escaping UtteranceHandler, onVolatile: @escaping VolatileHandler
    ) {
        self.asr = asr
        self.vad = vad
        self.decoderLayers = decoderLayers
        self.vadState = vadState
        self.offset = offset
        self.volatileUpdates = volatileUpdates
        self.onUtterance = onUtterance
        self.onVolatile = onVolatile
    }

    static func make(
        models: AsrModels, vad: VadManager, offset: TimeInterval = 0, volatileUpdates: Bool,
        onUtterance: @escaping UtteranceHandler, onVolatile: @escaping VolatileHandler = { _ in }
    ) async -> UtteranceTranscriber {
        let asr = AsrManager(config: .default, models: models)
        return UtteranceTranscriber(
            asr: asr, vad: vad, decoderLayers: await asr.decoderLayerCount, vadState: await vad.makeStreamState(),
            offset: offset, volatileUpdates: volatileUpdates, onUtterance: onUtterance, onVolatile: onVolatile)
    }

    func consume(_ samples: [Float]) async {
        audio.append(contentsOf: samples)
        unanalyzed.append(contentsOf: samples)
        while unanalyzed.count >= VadManager.chunkSize {
            let chunk = Array(unanalyzed.prefix(VadManager.chunkSize))
            unanalyzed.removeFirst(VadManager.chunkSize)
            await analyze(chunk)
        }
    }

    /// End of the audio: confirms the current piece.
    func finish() async {
        if let start = utteranceStart {
            utteranceStart = nil
            await commit(from: start, to: audioStart + audio.count)
        }
        await onVolatile("")
    }

    // MARK: - Pieces

    private func analyze(_ chunk: [Float]) async {
        let chunkStart = analyzed
        analyzed += chunk.count
        guard let result = try? await vad.processStreamingChunk(chunk, state: vadState, config: Self.segmentation) else {
            vadState.processedSamples += chunk.count
            speechProbabilities.append((chunkStart, 0))
            return
        }
        vadState = result.state
        speechProbabilities.append((chunkStart, result.probability))

        if let event = result.event {
            if event.isStart, utteranceStart == nil {
                utteranceStart = max(event.sampleIndex, audioStart)
                lastVolatile = analyzed
            } else if event.isEnd, let start = utteranceStart {
                utteranceStart = nil
                await commit(from: start, to: max(event.sampleIndex, start))
                await onVolatile("")
            }
        }

        guard let start = utteranceStart else {
            trim(keepingFrom: analyzed - Self.history)
            return
        }
        if analyzed - start >= Self.longUtterance {
            await commitStablePart(from: start)
        } else if volatileUpdates, analyzed - lastVolatile >= Self.volatileEvery {
            lastVolatile = analyzed
            if let result = await transcribe(from: start, to: analyzed) {
                await onVolatile(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private func commit(from start: Int, to end: Int) async {
        guard let words = await recognize(from: start, to: end) else { return }
        await emit(absolute(words, from: start), from: start, to: end)
    }

    /// Long piece without pauses: confirms everything except the last seconds, cutting between two words.
    private func commitStablePart(from start: Int) async {
        let end = analyzed
        lastVolatile = analyzed
        guard let words = await recognize(from: start, to: end) else {
            utteranceStart = end
            return
        }
        let duration = Double(end - start) / Double(Self.rate)
        guard let cut = DraftCut.index(in: words, before: duration - Self.unstableTail) else {
            // Nothing can be cut safely: confirm what's there and start again from here.
            await emit(absolute(words, from: start), from: start, to: end)
            utteranceStart = end
            return
        }
        let nextWordStart = cut + 1 < words.count ? words[cut + 1].start - 0.15 : words[cut].end
        let resume = start + Int(max(words[cut].end, nextWordStart) * Double(Self.rate))
        await emit(absolute(Array(words[...cut]), from: start), from: start, to: resume)
        utteranceStart = resume
        trim(keepingFrom: resume - Self.rate / 4)
    }

    private func emit(_ words: [TimedText], from start: Int, to end: Int) async {
        let text = words.map(\.text).joined(separator: " ")
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        let rate = Double(Self.rate)
        await onUtterance(Utterance(
            start: offset + Double(start) / rate, end: offset + Double(end) / rate, text: text, words: words))
    }

    // MARK: - Recognition

    /// The words of a piece, with times from the start of the piece. Stretches of speech left without
    /// words (usually a language switch) are transcribed again on their own and their words put back in.
    private func recognize(from start: Int, to end: Int) async -> [TimedText]? {
        guard let result = await transcribe(from: start, to: end) else { return nil }
        let rate = Double(Self.rate)
        var words = Self.words(in: result)
        if words.isEmpty {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { words = [TimedText(text: text, start: 0, end: Double(end - start) / rate)] }
        }

        for gap in Self.gaps(between: words, duration: Double(end - start) / rate)
        where isSpeech(from: start + Int(gap.start * rate), to: start + Int(gap.end * rate)) {
            let gapStart = max(start, start + Int((gap.start - 0.15) * rate))
            let gapEnd = min(end, start + Int((gap.end + 0.15) * rate))
            guard let filled = await transcribe(from: gapStart, to: gapEnd) else { continue }
            let shift = Double(gapStart - start) / rate
            words += Self.words(in: filled)
                .map { TimedText(text: $0.text, start: $0.start + shift, end: $0.end + shift) }
                .filter { $0.start >= gap.start - 0.3 && $0.start < gap.end }
        }
        return words.sorted { $0.start < $1.start }
    }

    /// The stretches of at least `minimumGap` seconds without words, including at the start and end of the piece.
    private static func gaps(between words: [TimedText], duration: TimeInterval) -> [(start: TimeInterval, end: TimeInterval)] {
        var gaps: [(start: TimeInterval, end: TimeInterval)] = []
        var cursor: TimeInterval = 0
        for word in words {
            if word.start - cursor >= minimumGap { gaps.append((cursor, word.start)) }
            cursor = max(cursor, min(word.end, word.start + 0.8))
        }
        if duration - cursor >= minimumGap { gaps.append((cursor, duration)) }
        return gaps
    }

    /// The detector heard speech in at least half of the blocks of this stretch.
    private func isSpeech(from start: Int, to end: Int) -> Bool {
        let blocks = speechProbabilities.filter { $0.start + VadManager.chunkSize > start && $0.start < end }
        guard !blocks.isEmpty else { return false }
        return Double(blocks.filter { $0.value >= 0.5 }.count) >= Double(blocks.count) * 0.5
    }

    private static func words(in result: ASRResult) -> [TimedText] {
        buildWordTimings(from: result.tokenTimings ?? []).map { TimedText(text: $0.word, start: $0.startTime, end: $0.endTime) }
    }

    private func transcribe(from start: Int, to end: Int) async -> ASRResult? {
        let lower = max(start - audioStart, 0)
        let upper = min(end - audioStart, audio.count)
        guard upper - lower >= Self.rate / 4 else { return nil }
        var samples = Array(audio[lower..<upper])
        // Parakeet wants at least one second of audio: pad with silence.
        if samples.count < Self.rate {
            samples += [Float](repeating: 0, count: Self.rate - samples.count)
        }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        return try? await asr.transcribe(samples, decoderState: &state)
    }

    /// Word times from the start of the recording, instead of from the start of the piece.
    private func absolute(_ words: [TimedText], from start: Int) -> [TimedText] {
        let base = offset + Double(start) / Double(Self.rate)
        return words.map { TimedText(text: $0.text, start: base + $0.start, end: base + $0.end) }
    }

    /// Frees audio that's no longer needed, in blocks so memory isn't moved at every piece.
    private func trim(keepingFrom sample: Int) {
        let drop = min(sample - audioStart, audio.count)
        guard drop > Self.rate * 10 else { return }
        audio.removeFirst(drop)
        audioStart += drop
        speechProbabilities.removeAll { $0.start + VadManager.chunkSize <= audioStart }
    }
}
