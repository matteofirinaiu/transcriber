import AppKit
import SwiftUI
import TranscriberCore

/// Automated test of the whole app:
///
///     open -W -n build/Transcriber.app --args --autotest 80 --inject audio.wav \
///         --library /tmp/test --report /tmp/test/report.json --snapshots /tmp/test
///
/// Records for N seconds (from the microphone, or from a file with `--inject`), waits for the final
/// version, writes a JSON report and quits. With `--library` the transcripts go to a separate folder,
/// leaving the real one alone; with `--snapshots` it saves two images of the window.
@MainActor
enum Autotest {
    struct Options {
        var seconds: Double
        var injectURL: URL?
        var libraryURL: URL?
        var reportURL: URL
        var snapshotsURL: URL?
    }

    static let options: Options? = {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let seconds = value("--autotest").flatMap(Double.init) else { return nil }
        return Options(
            seconds: seconds,
            injectURL: value("--inject").map { URL(fileURLWithPath: $0) },
            libraryURL: value("--library").map { URL(fileURLWithPath: $0, isDirectory: true) },
            reportURL: URL(fileURLWithPath: value("--report") ?? NSTemporaryDirectory() + "transcriber-autotest.json"),
            snapshotsURL: value("--snapshots").map { URL(fileURLWithPath: $0, isDirectory: true) })
    }()

    private final class Probe {
        var maxLevel: Float = 0
        var alerts: [String] = []
    }

    static func run(_ model: AppModel, _ options: Options) async {
        let started = Date()
        let probe = Probe()
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                probe.maxLevel = max(probe.maxLevel, model.level)
                if let alert = model.alert {
                    probe.alerts.append("\(alert.title): \(alert.message)")
                    model.alert = nil
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        var report: [String: Any] = [:]
        try? await Task.sleep(for: .seconds(1)) // lets the window appear
        if options.snapshotsURL != nil {
            model.showWelcome = true
            try? await Task.sleep(for: .seconds(1))
            snapshot("0-welcome", options, sheet: true)
            model.closeWelcome()
            try? await Task.sleep(for: .seconds(1))
            model.updates.state = .available("9.9.9")
            await snapshot("0-footer-update", options, view: SidebarFooter().environment(model), size: CGSize(width: 280, height: 96))
            model.updates.state = .idle
            await snapshot("0-footer", options, view: SidebarFooter().environment(model), size: CGSize(width: 280, height: 44))
        }
        await model.startRecording()
        report["recordingStarted"] = model.phase == .recording

        try? await Task.sleep(for: .seconds(options.seconds * 0.6))
        snapshot("1-recording", options)
        try? await Task.sleep(for: .seconds(options.seconds * 0.4))

        report["liveDraft"] = ParagraphBuilder.render(model.liveParagraphs)
        report["liveSegments"] = model.liveSegments.count
        await model.stopRecording()
        while !model.jobs.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(1))
        snapshot("2-transcript", options)
        sampler.cancel()

        report["maxLevel"] = probe.maxLevel
        report["alerts"] = probe.alerts
        report["selection"] = String(describing: model.selection)
        report["leftoverRecordings"] = RecordingFolder.pending().count
        report["seconds"] = Date().timeIntervalSince(started)
        report["transcripts"] = model.transcripts.map { item in
            [
                "file": item.url.lastPathComponent,
                "kind": item.document.kind.rawValue,
                "languages": item.document.languages,
                "duration": item.document.duration,
                "markdown": (try? String(contentsOf: item.url, encoding: .utf8)) ?? "",
            ] as [String: Any]
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: options.reportURL)
        }
        NSApp.terminate(nil)
    }

    /// Shows a view on its own in a small window for a moment and takes its picture. The sidebar's glass
    /// background comes out blank in pictures of the main window, and SwiftUI draws nothing off screen.
    private static func snapshot(_ name: String, _ options: Options, view: some View, size: CGSize) async {
        guard let directory = options.snapshotsURL else { return }
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.center()
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(600))
        let frame = host.superview ?? host
        if let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }
        window.close()
    }

    /// Takes a picture of the main window, or of the sheet open on it (no screen recording permission needed).
    private static func snapshot(_ name: String, _ options: Options, sheet: Bool = false) {
        guard let directory = options.snapshotsURL,
              let main = NSApp.windows.first(where: { $0.isVisible && $0.title == "Transcriber" }),
              let window = sheet ? main.attachedSheet : main,
              let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
