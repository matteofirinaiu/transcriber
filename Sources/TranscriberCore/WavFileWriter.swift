import Foundation

/// Writes a 16-bit mono PCM WAV one piece at a time.
///
/// The header is updated often, and `repair(url:)` rebuilds it from the file size:
/// if the app quits in the middle of a recording, the audio stays readable.
public final class WavFileWriter {
    public static let headerSize = 44

    public let url: URL
    public let sampleRate: Int
    public private(set) var dataBytes = 0
    private let handle: FileHandle

    public init(url: URL, sampleRate: Int = 16_000) throws {
        self.url = url
        self.sampleRate = sampleRate
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(sampleRate: sampleRate, dataBytes: 0)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    public var duration: TimeInterval { Double(dataBytes / 2) / Double(sampleRate) }

    /// Float32 samples in [-1, 1].
    public func append(_ samples: UnsafeBufferPointer<Float>) throws {
        guard !samples.isEmpty else { return }
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let output = raw.bindMemory(to: Int16.self)
            for (index, sample) in samples.enumerated() {
                let clipped = max(-1, min(1, sample.isFinite ? sample : 0))
                output[index] = Int16(clipped * Float(Int16.max)).littleEndian
            }
        }
        try handle.write(contentsOf: data)
        dataBytes += data.count
    }

    public func updateHeader() throws {
        try Self.patchHeader(handle, dataBytes: dataBytes)
        try handle.seekToEnd()
    }

    public func close() throws {
        try updateHeader()
        try handle.synchronize()
        try handle.close()
    }

    /// Fixes the header of a file that was left open and returns its duration in seconds.
    @discardableResult
    public static func repair(url: URL) throws -> TimeInterval {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        guard size >= headerSize else { return 0 }
        let dataBytes = (size - headerSize) & ~1
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 24)
        let rateBytes = try handle.read(upToCount: 4) ?? Data()
        let sampleRate = rateBytes.count == 4 ? Int(rateBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }) : 16_000
        try patchHeader(handle, dataBytes: dataBytes)
        if size != headerSize + dataBytes { try handle.truncate(atOffset: UInt64(headerSize + dataBytes)) }
        return Double(dataBytes / 2) / Double(max(sampleRate, 1))
    }

    static func header(sampleRate: Int, dataBytes: Int) -> Data {
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(36 + dataBytes); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate * 2); append16(2); append16(16)
        append("data"); append32(dataBytes)
        return data
    }

    static func patchHeader(_ handle: FileHandle, dataBytes: Int) throws {
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: withUnsafeBytes(of: UInt32(36 + dataBytes).littleEndian) { Data($0) })
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: withUnsafeBytes(of: UInt32(dataBytes).littleEndian) { Data($0) })
    }
}
