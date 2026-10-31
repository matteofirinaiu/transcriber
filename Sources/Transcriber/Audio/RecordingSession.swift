import AVFoundation
import TranscriberCore

/// A recording in progress: microphone → temporary WAV, and the same audio to the live draft.
final class RecordingSession: @unchecked Sendable {
    let folder: RecordingFolder
    let meta: RecordingMeta

    private let writer: WavFileWriter
    private let input: AudioInput
    private let lock = NSLock()
    private var samplesWritten = 0
    private var samplesAtLastHeaderUpdate = 0
    private var liveFeed: LiveAudioSink?
    private var stopped = false
    private var reportedWriteError = false
    private var onFailure: (@Sendable (Error) -> Void)?

    init(draftLanguage: String, expectedSpeakers: Int?, input: AudioInput = MicRecorder()) throws {
        self.input = input
        let meta = RecordingMeta(draftLanguage: draftLanguage, expectedSpeakers: expectedSpeakers)
        let folder = try RecordingFolder.create(meta: meta)
        self.meta = meta
        self.folder = folder
        writer = try WavFileWriter(url: folder.audioURL, sampleRate: Int(MicRecorder.targetFormat.sampleRate))
    }

    /// `onLevel` and `onFailure` are called from the audio thread.
    func start(deviceUID: String?, onLevel: @escaping @Sendable (Float) -> Void, onFailure: @escaping @Sendable (Error) -> Void) throws {
        self.onFailure = onFailure
        input.onFailure = onFailure
        try input.start(deviceUID: deviceUID) { [weak self] buffer in
            guard let self else { return }
            self.write(buffer)
            onLevel(Self.level(of: buffer))
        }
    }

    /// Connects (or disconnects) the live draft. Returns the seconds already recorded,
    /// which become the start time of the draft's sentences.
    func attachLiveFeed(_ feed: LiveAudioSink?) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        liveFeed = feed
        return Double(samplesWritten) / MicRecorder.targetFormat.sampleRate
    }

    /// Stops the microphone and closes the file. Returns the recorded duration.
    @discardableResult
    func stop() -> TimeInterval {
        input.stop()
        lock.lock()
        defer { lock.unlock() }
        if !stopped {
            stopped = true
            liveFeed = nil
            try? writer.close()
        }
        return writer.duration
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        var failure: Error?
        do {
            try writer.append(samples)
            samplesWritten += samples.count
            // Header updated every 5 seconds: if the app quits, the audio stays readable.
            if samplesWritten - samplesAtLastHeaderUpdate >= 16_000 * 5 {
                try writer.updateHeader()
                samplesAtLastHeaderUpdate = samplesWritten
            }
        } catch {
            if !reportedWriteError {
                reportedWriteError = true
                failure = error
            }
        }
        let feed = liveFeed
        lock.unlock()

        if let failure { onFailure?(failure) }
        feed?.feed(buffer)
    }

    /// Volume from 0 to 1 for the meter (decibel scale).
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (decibels + 55) / 50))
    }
}
