import AVFoundation
import Speech

/// Language of the live draft. With Automatic the draft uses Parakeet and detects the language by itself;
/// with English or Italian it uses macOS speech recognition. The final version always detects it by itself.
enum DraftLanguage: String, CaseIterable, Identifiable {
    case automatic = "auto"
    case english = "en"
    case italian = "it"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .english: "English"
        case .italian: "Italian"
        }
    }

    /// Language of Apple's recognizer; `nil` for Automatic.
    var appleLocale: Locale? {
        switch self {
        case .automatic: nil
        case .english: Locale(identifier: "en-US")
        case .italian: Locale(identifier: "it-IT")
        }
    }

    static let appleLanguages: [DraftLanguage] = [.english, .italian]
}

/// Where the recording sends audio for the live draft. Called from the audio thread.
protocol LiveAudioSink: AnyObject, Sendable {
    func feed(_ buffer: AVAudioPCMBuffer)
    func finish()
}

/// Passes the audio to Apple's recognizer, in the format it prefers.
final class AnalyzerFeed: LiveAudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?
    private let needsConversion: Bool

    init(continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
        self.continuation = continuation
        self.format = format
        let source = MicRecorder.targetFormat
        needsConversion = format.sampleRate != source.sampleRate
            || format.channelCount != source.channelCount
            || format.commonFormat != source.commonFormat
        converter = needsConversion ? AVAudioConverter(from: source, to: format) : nil
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        if !needsConversion {
            continuation.yield(AnalyzerInput(buffer: buffer))
        } else if let converter, let converted = AudioConversion.convert(buffer, with: converter, to: format) {
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        continuation?.finish()
        continuation = nil
    }
}

/// Passes the 16 kHz samples to the automatic draft (Parakeet).
final class SampleFeed: LiveAudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<[Float]>.Continuation?

    init(continuation: AsyncStream<[Float]>.Continuation) {
        self.continuation = continuation
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        lock.lock()
        defer { lock.unlock() }
        continuation?.yield(samples)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        continuation?.finish()
        continuation = nil
    }
}
