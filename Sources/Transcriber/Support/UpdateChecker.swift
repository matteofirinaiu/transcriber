import AppKit
import Observation
import TranscriberCore
import UserNotifications

/// Tells the user when a new version is out on GitHub and downloads it.
///
/// The ".../releases/latest" page redirects to the newest tag (".../releases/tag/v1.2.0"), so one HEAD
/// request is enough. The GitHub API would allow only 60 requests an hour per network, a limit a whole
/// class on the university Wi-Fi could hit. Nothing about the user or their recordings is sent.
@MainActor
@Observable
final class UpdateChecker {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading(String)
        case downloaded(String)
        case failed(String)
    }

    static let latestRelease = URL(string: "https://github.com/matteofirinaiu/transcriber/releases/latest")!

    /// The version of this copy of the app. `--pretend-version 1.0.0` makes it look older, to try updates out.
    static let currentVersion: String = {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--pretend-version"), index + 1 < arguments.count {
            return arguments[index + 1]
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }()

    var state: State = .idle
    var automaticChecks: Bool {
        didSet { UserDefaults.standard.set(automaticChecks, forKey: Keys.automaticChecks) }
    }

    private enum Keys {
        static let automaticChecks = "checkForUpdates"
        static let notifiedVersion = "notifiedUpdateVersion"
    }

    @ObservationIgnored private var schedule: Task<Void, Never>?

    init() {
        automaticChecks = UserDefaults.standard.object(forKey: Keys.automaticChecks) as? Bool ?? true
    }

    /// Checks a few seconds after launch and then once a day, while automatic checks are on.
    func start() {
        schedule?.cancel()
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                guard let self else { return }
                if self.automaticChecks { await self.check(userInitiated: false) }
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    /// Automatic checks stay quiet unless there's an update; a check the user asked for always answers.
    func check(userInitiated: Bool) async {
        switch state {
        case .checking, .downloading: return
        default: break
        }
        let previous = state
        if userInitiated { state = .checking }
        do {
            guard let latest = try await Self.latestVersion(), AppVersion.isNewer(latest, than: Self.currentVersion) else {
                state = userInitiated ? .upToDate : .idle
                if userInitiated { clearAfterAWhile(.upToDate) }
                return
            }
            // An update already downloaded stays ready to install.
            if previous == .downloaded(latest) {
                state = previous
                return
            }
            state = .available(latest)
            await notify(latest)
        } catch {
            state = userInitiated ? .failed("Couldn't check for updates.") : previous
            if userInitiated { clearAfterAWhile(state) }
        }
    }

    /// Downloads the disk image of the new version. A file the app downloads itself doesn't get the
    /// "downloaded from the internet" mark, so the new version opens without "Open Anyway".
    func download() async {
        guard case .available(let version) = state else { return }
        state = .downloading(version)
        do {
            let source = URL(string: "https://github.com/matteofirinaiu/transcriber/releases/download/v\(version)/Transcriber.dmg")!
            let (temporary, response) = try await URLSession.shared.download(from: source)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            // Replaces older downloads. The Caches folder needs no permission, unlike Downloads.
            try? FileManager.default.removeItem(at: Self.downloadsFolder)
            try FileManager.default.createDirectory(at: Self.downloadsFolder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: Self.diskImage(for: version))
            state = .downloaded(version)
        } catch {
            state = .failed("Download failed. Check your connection and try again.")
            clearAfterAWhile(state, then: .available(version))
        }
    }

    /// Mounts the downloaded disk image: Finder shows the new app next to the Applications folder.
    func openDownload(_ version: String) {
        NSWorkspace.shared.open(Self.diskImage(for: version))
    }

    static func latestVersion() async throws -> String? {
        var request = URLRequest(url: latestRelease, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return response.url.flatMap { AppVersion.fromReleaseTag($0.absoluteString) }
    }

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Transcriber", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    static func diskImage(for version: String) -> URL {
        downloadsFolder.appendingPathComponent("Transcriber \(version).dmg")
    }

    /// One macOS notification per new version. Permission is asked the first time an update comes out.
    private func notify(_ version: String) async {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Keys.notifiedVersion) != version else { return }
        defaults.set(version, forKey: Keys.notifiedVersion)
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "Transcriber \(version) is available"
        content.body = "Click Update at the bottom of the Transcriber sidebar to get it."
        try? await center.add(UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil))
    }

    /// Short messages ("up to date", errors) go away by themselves after a few seconds.
    private func clearAfterAWhile(_ shown: State, then next: State = .idle) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.state == shown else { return }
            self.state = next
        }
    }
}
