import AVFoundation
import FluidAudio
import Foundation
import os
import TranscriberCore

/// FluidAudio models on the Neural Engine: Parakeet writes the final version and the "Automatic" live draft
/// (it detects the language by itself), and speaker separation tells who speaks in the final version.
actor ParakeetEngine {
    /// Parakeet Ultra: same architecture and languages as Parakeet TDT v3, more accurate.
    static let version: AsrModelVersion = .ultra

    private var models: AsrModels?
    private var loading: Task<AsrModels, Error>?
    private var vad: VadManager?

    /// Parakeet, the voice detector and speaker separation are already on the Mac.
    nonisolated var isDownloaded: Bool {
        let files = FileManager.default
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: Self.version), version: Self.version)
            && files.fileExists(atPath: MLModelConfigurationUtils.defaultModelsDirectory(for: .vad).path)
            && files.fileExists(atPath: MLModelConfigurationUtils.defaultModelsDirectory(for: .diarizer).path)
    }

    /// Downloads Parakeet (about 600 MB), the voice detector and speaker separation (a few MB)
    /// from Hugging Face, no account needed.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await AsrModels.download(version: Self.version, progressHandler: { progress($0.fractionCompleted * 0.97) })
        _ = try await vadManager()
        try await OfflineDiarizerManager().prepareModels()
        progress(1)
    }

    func asrModels(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> AsrModels {
        if let models { return models }
        if let loading { return try await loading.value }
        let task = Task {
            try await AsrModels.downloadAndLoad(version: Self.version, progressHandler: { progress($0.fractionCompleted) })
        }
        loading = task
        defer { loading = nil }
        let loaded = try await task.value
        models = loaded
        return loaded
    }

    func vadManager() async throws -> VadManager {
        if let vad { return vad }
        let loaded = try await VadManager()
        vad = loaded
        return loaded
    }

    /// Frees the memory. Whoever is still using the models (for example a running draft)
    /// keeps them until it's done.
    func unload() {
        models = nil
        vad = nil
    }

    /// Who speaks and when, over the whole file. Without `expectedSpeakers` (only the `--speakers` test
    /// option and recordings from before 1.3.0 have it), the model counts the people itself.
    func diarize(fileURL: URL, expectedSpeakers: Int?, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeakerSpan] {
        var config = OfflineDiarizerConfig.default
        config.clustering.numSpeakers = expectedSpeakers
        let diarizer = OfflineDiarizerManager(config: config)
        try await diarizer.prepareModels()
        let result = try await diarizer.process(fileURL) { done, total in
            progress(Double(done) / Double(max(total, 1)))
        }
        return result.segments.map {
            SpeakerSpan(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }

    /// Final version: the words of the whole file with their times. Cuts the audio at pauses and
    /// transcribes sentence by sentence; without the voice detector, it transcribes the whole file in windows.
    func transcribe(fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedText] {
        let models = try await asrModels()
        guard let vad = try? await vadManager() else {
            return try await transcribeWholeFile(fileURL, models: models, progress: progress)
        }

        let collected = OSAllocatedUnfairLock(initialState: [TimedText]())
        let transcriber = await UtteranceTranscriber.make(models: models, vad: vad, volatileUpdates: false) { utterance in
            collected.withLock { $0 += utterance.words }
        }
        let file = try AVAudioFile(forReading: fileURL)
        let target = MicRecorder.targetFormat
        let format = file.processingFormat
        let converter = format.sampleRate == target.sampleRate && format.channelCount == 1 && format.commonFormat == .pcmFormatFloat32
            ? nil : AVAudioConverter(from: format, to: target)
        let total = max(Double(file.length), 1)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000) else { break }
            try file.read(into: buffer, frameCount: 16_000)
            guard buffer.frameLength > 0 else { break }
            let samples = converter.flatMap { AudioConversion.convert(buffer, with: $0, to: target) } ?? buffer
            guard let channel = samples.floatChannelData?[0] else { continue }
            await transcriber.consume(Array(UnsafeBufferPointer(start: channel, count: Int(samples.frameLength))))
            progress(Double(file.framePosition) / total)
        }
        await transcriber.finish()
        progress(1)
        return collected.withLock { $0 }
    }

    /// FluidAudio's method for long files: fixed windows of about 15 seconds.
    /// It can lose a sentence that straddles two windows, which is why it's only the fallback.
    private func transcribeWholeFile(_ fileURL: URL, models: AsrModels, progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedText] {
        let manager = AsrManager(config: .default, models: models)
        let stream = await manager.transcriptionProgressStream
        let progressTask = Task {
            do {
                for try await value in stream { progress(value) }
            } catch {}
        }
        defer { progressTask.cancel() }

        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(fileURL, decoderState: &state)
        progress(1)

        let words = buildWordTimings(from: result.tokenTimings ?? [])
        if words.isEmpty {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [TimedText(text: text, start: 0, end: result.duration)]
        }
        return words.map { TimedText(text: $0.word, start: $0.startTime, end: $0.endTime) }
    }
}
