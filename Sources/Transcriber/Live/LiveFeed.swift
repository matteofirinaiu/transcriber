import AVFoundation

/// Where the recording sends audio for the live draft. Called from the audio thread.
protocol LiveAudioSink: AnyObject, Sendable {
    func feed(_ buffer: AVAudioPCMBuffer)
    func finish()
}

/// Passes the 16 kHz samples to the live draft (Parakeet).
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
