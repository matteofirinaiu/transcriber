import AVFoundation
import CoreAudio

enum MicError: LocalizedError {
    case noInputDevice
    case unsupportedFormat
    case deviceSelectionFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone available."
        case .unsupportedFormat: "The microphone's audio format isn't supported."
        case .deviceSelectionFailed(let status): "Can't use the selected microphone (error \(status))."
        }
    }
}

enum AudioConversion {
    /// Converts a buffer with a converter that keeps its state from one call to the next.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// Reads an audio file and splits it into 16 kHz mono buffers, as the microphone would.
    static func readFile(_ url: URL) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: MicRecorder.targetFormat) else {
            throw MicError.unsupportedFormat
        }
        var buffers: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096) else { break }
            try file.read(into: input, frameCount: 4_096)
            if input.frameLength == 0 { break }
            if let output = convert(input, with: converter, to: MicRecorder.targetFormat) {
                buffers.append(output)
            }
        }
        return buffers
    }

    static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

/// Where a recording's audio comes from: the microphone, or a file in automated tests.
protocol AudioInput: AnyObject {
    var onFailure: ((Error) -> Void)? { get set }
    /// `handler` receives 16 kHz mono buffers on a background thread.
    func start(deviceUID: String?, handler: @escaping (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

/// Automated tests only: plays a file as if it came from the microphone, in real time.
final class FileAudioInput: AudioInput, @unchecked Sendable {
    var onFailure: ((Error) -> Void)?
    private let url: URL
    private let stopped = NSLock()
    private var isStopped = false

    init(url: URL) {
        self.url = url
    }

    func start(deviceUID: String?, handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let buffers = try AudioConversion.readFile(url)
        Thread.detachNewThread { [self] in
            for buffer in buffers {
                stopped.lock()
                let done = isStopped
                stopped.unlock()
                if done { return }
                handler(buffer)
                Thread.sleep(forTimeInterval: Double(buffer.frameLength) / buffer.format.sampleRate)
            }
        }
    }

    func stop() {
        stopped.lock()
        isStopped = true
        stopped.unlock()
    }
}

/// Captures the microphone with AVAudioEngine and delivers 16 kHz mono buffers (Float32),
/// the format used by both the draft and the final version.
final class MicRecorder: AudioInput, @unchecked Sendable {
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Called if the microphone stops and can't be restarted.
    var onFailure: ((Error) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var handler: ((AVAudioPCMBuffer) -> Void)?
    private var deviceUID: String?
    private var configurationObserver: NSObjectProtocol?

    /// `handler` is called from the audio thread.
    func start(deviceUID: String?, handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.handler = handler
        self.deviceUID = deviceUID
        try startEngine()
        // Microphone unplugged or changed: AVAudioEngine stops, so restart it on the default one.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        handler = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func startEngine() throws {
        let input = engine.inputNode
        if let uid = deviceUID, let id = AudioDevices.deviceID(forUID: uid) {
            try select(id, on: input)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicError.noInputDevice }
        guard let converter = AVAudioConverter(from: format, to: Self.targetFormat) else { throw MicError.unsupportedFormat }
        converter.downmix = true
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            self?.deliver(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func restartAfterConfigurationChange() {
        guard handler != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let uid = deviceUID, AudioDevices.deviceID(forUID: uid) == nil { deviceUID = nil }
        do {
            try startEngine()
        } catch {
            onFailure?(error)
        }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let handler,
              let converted = AudioConversion.convert(buffer, with: converter, to: Self.targetFormat)
        else { return }
        handler(converted)
    }

    private func select(_ device: AudioDeviceID, on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { throw MicError.noInputDevice }
        var device = device
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw MicError.deviceSelectionFailed(status) }
    }
}
