import AppKit
import Observation
import TranscriberCore

enum SidebarItem: Hashable {
    case recorder
    case transcript(UUID)
}

enum RecorderPhase: Equatable {
    case idle, starting, recording, stopping
}

enum FinalModelState: Equatable {
    case checking
    case downloading(Double)
    case ready
    case failed(String)
}

/// A final version being prepared.
struct FinalJob: Identifiable, Equatable {
    let id: UUID
    let title: String
    var stage: String
    var progress: Double?
}

/// A recording left unfinished: the app quit during the recording, or the final version failed.
struct PendingRecording: Identifiable, Equatable {
    let folder: RecordingFolder
    let meta: RecordingMeta
    let duration: TimeInterval
    var id: UUID { meta.id }
    var title: String { TranscriptLibrary.defaultTitle(for: meta.startDate) }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var opensMicrophoneSettings = false
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private enum Keys {
        static let draftLanguage = "draftLanguage"
        static let inputDevice = "inputDeviceUID"
        static let folder = "transcriptsFolder"
    }

    // MARK: Settings

    var draftLanguage: DraftLanguage {
        didSet { UserDefaults.standard.set(draftLanguage.rawValue, forKey: Keys.draftLanguage) }
    }
    var inputDeviceUID: String? {
        didSet { UserDefaults.standard.set(inputDeviceUID, forKey: Keys.inputDevice) }
    }
    /// How many people speak in the next recording (`nil` = the app counts them).
    /// Not remembered: it goes back to Automatic after every recording, so an old number can't spoil the next one.
    var expectedSpeakers: Int?
    var transcriptsFolder: URL {
        didSet {
            UserDefaults.standard.set(transcriptsFolder.path, forKey: Keys.folder)
            reloadLibrary()
        }
    }

    // MARK: Library

    private(set) var transcripts: [StoredTranscript] = []
    var selection: SidebarItem? = .recorder
    var searchText = ""
    var alert: AppAlert?

    // MARK: Recording

    private(set) var phase: RecorderPhase = .idle
    private(set) var recordingStart: Date?
    private(set) var level: Float = 0
    private(set) var liveSegments: [DraftSegment] = []
    private(set) var volatileText = ""
    private(set) var liveLanguage: DraftLanguage = .automatic
    private(set) var liveBusy = false
    private(set) var liveStatus: String?

    // MARK: Final version

    private(set) var jobs: [FinalJob] = []
    private(set) var pending: [PendingRecording] = []
    private(set) var finalModel: FinalModelState = .checking

    /// Transcripts folder used instead of the chosen one (automated tests only).
    @ObservationIgnored private var libraryOverride: URL?
    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private let engine: ParakeetEngine
    @ObservationIgnored private let live: LiveTranscriber
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?
    @ObservationIgnored private var draftAutosave: Task<Void, Never>?
    @ObservationIgnored private var jobChain: Task<Void, Never>?
    @ObservationIgnored private var modelDownload: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        draftLanguage = DraftLanguage(rawValue: defaults.string(forKey: Keys.draftLanguage) ?? "") ?? .automatic
        inputDeviceUID = defaults.string(forKey: Keys.inputDevice)
        transcriptsFolder = defaults.string(forKey: Keys.folder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? TranscriptLibrary.defaultFolder
        engine = ParakeetEngine()
        live = LiveTranscriber(engine: engine)

        live.onSegment = { [weak self] segment in self?.liveSegments.append(segment) }
        live.onVolatile = { [weak self] text in self?.volatileText = text }
        live.onStatus = { [weak self] status in self?.liveStatus = status }
    }

    /// Call once at launch.
    func launch() {
        libraryOverride = Autotest.options?.libraryURL
        reloadLibrary()
        scanPending()
        downloadModelsIfNeeded()
        if let options = Autotest.options {
            Task { await Autotest.run(self, options) }
        }
    }

    // MARK: - Library

    var library: TranscriptLibrary { TranscriptLibrary(folder: libraryOverride ?? transcriptsFolder) }

    var visibleTranscripts: [StoredTranscript] { transcripts.filter { $0.matches(searchText) } }

    func transcript(id: UUID) -> StoredTranscript? { transcripts.first { $0.id == id } }

    func reloadLibrary() {
        transcripts = library.loadAll()
    }

    /// Saves the edited title and text; renames the file if the title changed.
    func update(id: UUID, title: String, body: String) {
        guard let item = transcript(id: id) else { return }
        var document = item.document
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty { document.title = cleanTitle }
        document.body = body
        save(document, over: item)
    }

    /// Renames a speaker throughout the transcript. If the name is already used, the two speakers become one.
    func renameSpeaker(in id: UUID, from old: String, to new: String) {
        guard let item = transcript(id: id) else { return }
        let name = SpeakerNames.clean(new)
        guard !name.isEmpty, name != old else { return }
        var document = item.document
        document.body = SpeakerNames.rename(old, to: name, in: document.body)
        document.speakers = SpeakerNames.unique(document.speakers.map { $0 == old ? name : $0 })
        save(document, over: item)
    }

    private func save(_ document: TranscriptDocument, over item: StoredTranscript) {
        guard document != item.document else { return }
        let id = item.id
        do {
            let url = try library.save(document, replacing: item.url)
            if let index = transcripts.firstIndex(where: { $0.id == id }) {
                transcripts[index] = StoredTranscript(url: url, document: document)
            }
        } catch {
            alert = AppAlert(title: "Couldn't save the transcript", message: error.localizedDescription)
        }
    }

    func moveToTrash(_ item: StoredTranscript) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        } catch {
            alert = AppAlert(title: "Couldn't move it to the Trash", message: error.localizedDescription)
        }
        if selection == .transcript(item.id) { selection = .recorder }
        reloadLibrary()
    }

    // MARK: - Recording

    var liveParagraphs: [Paragraph] {
        ParagraphBuilder.sentences.build(liveSegments.map(\.timedText))
    }

    func toggleRecording() async {
        switch phase {
        case .idle: await startRecording()
        case .recording: await stopRecording()
        case .starting, .stopping: break
        }
    }

    func startRecording() async {
        guard phase == .idle else { return }
        phase = .starting
        let input: AudioInput
        if let file = Autotest.options?.injectURL {
            input = FileAudioInput(url: file)
        } else {
            guard await Permissions.requestMicrophone() else {
                phase = .idle
                alert = AppAlert(
                    title: "Transcriber needs the microphone",
                    message: "Allow Transcriber to use the microphone in System Settings → Privacy & Security → Microphone, then try again.",
                    opensMicrophoneSettings: true)
                return
            }
            input = MicRecorder()
        }

        let session: RecordingSession
        do {
            session = try RecordingSession(draftLanguage: draftLanguage.rawValue, expectedSpeakers: expectedSpeakers, input: input)
            try session.start(
                deviceUID: inputDeviceUID,
                onLevel: { [weak self] value in Task { @MainActor in self?.level = value } },
                onFailure: { [weak self] error in Task { @MainActor in self?.microphoneFailed(error) } })
        } catch {
            phase = .idle
            alert = AppAlert(title: "Couldn't start recording", message: error.localizedDescription)
            return
        }

        self.session = session
        recordingStart = session.meta.startDate
        liveSegments = []
        volatileText = ""
        liveStatus = nil
        selection = .recorder
        phase = .recording
        // The Mac doesn't idle-sleep while recording (the screen can still turn off).
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: "Recording audio to transcribe")
        startDraftAutosave(for: session)
        await startLive(draftLanguage, for: session)
    }

    /// Changes the draft's language, even during a recording.
    func switchLiveLanguage(_ language: DraftLanguage) async {
        draftLanguage = language
        guard phase == .recording, let session, language != liveLanguage, !liveBusy else { return }
        await startLive(language, for: session)
    }

    private func startLive(_ requested: DraftLanguage, for session: RecordingSession) async {
        // Automatic uses Parakeet: until the model is downloaded, the draft stays in English.
        let language = requested == .automatic && finalModel != .ready ? .english : requested
        liveBusy = true
        defer { liveBusy = false }
        do {
            try await live.start(language: language) { feed in session.attachLiveFeed(feed) }
            liveLanguage = language
            if language != requested {
                liveStatus = "The Automatic draft will be available once the model finishes downloading. For now the draft is in English."
            }
            // If the recording ended in the meantime, close the recognizer right away.
            if self.session !== session { await live.stop() }
        } catch {
            liveStatus = "Live draft unavailable (\(error.localizedDescription)). Recording continues and you'll still get the final version."
        }
    }

    func stopRecording() async {
        guard phase == .recording, let session else { return }
        phase = .stopping
        draftAutosave?.cancel()
        session.stop()
        await live.stop()
        try? session.folder.saveDraft(liveSegments)
        endSleepActivity()
        self.session = nil
        level = 0
        expectedSpeakers = nil
        phase = .idle
        enqueueFinal(folder: session.folder, meta: session.meta, draft: liveSegments, reveal: true)
    }

    /// Quitting the app during a recording: saves everything, the transcript is made at the next launch.
    func prepareForQuit() {
        guard let session else { return }
        session.stop()
        try? session.folder.saveDraft(liveSegments)
        self.session = nil
        endSleepActivity()
    }

    private func microphoneFailed(_ error: Error) {
        guard phase == .recording else { return }
        alert = AppAlert(
            title: "The recording stopped",
            message: "\(error.localizedDescription)\n\nTranscriber will transcribe what was recorded so far.")
        Task { await stopRecording() }
    }

    private func startDraftAutosave(for session: RecordingSession) {
        draftAutosave?.cancel()
        draftAutosave = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.session === session else { return }
                try? session.folder.saveDraft(self.liveSegments)
            }
        }
    }

    private func endSleepActivity() {
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity) }
        sleepActivity = nil
    }

    // MARK: - Final version

    func downloadModelsIfNeeded() {
        guard modelDownload == nil else { return }
        if engine.isDownloaded {
            finalModel = .ready
            return
        }
        finalModel = .downloading(0)
        modelDownload = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.download { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.finalModel else { return }
                        self.finalModel = .downloading(fraction)
                    }
                }
                self.finalModel = .ready
            } catch {
                self.finalModel = .failed(error.localizedDescription)
            }
            self.modelDownload = nil
        }
    }

    private func enqueueFinal(folder: RecordingFolder, meta: RecordingMeta, draft: [DraftSegment], reveal: Bool) {
        jobs.append(FinalJob(id: meta.id, title: TranscriptLibrary.defaultTitle(for: meta.startDate), stage: "Waiting", progress: nil))
        let previous = jobChain
        jobChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.runFinal(folder: folder, meta: meta, draft: draft, reveal: reveal)
            // Frees the model's memory only inside the queue: a new job waits for this to finish.
            if self.jobs.isEmpty { await self.engine.unload() }
        }
    }

    private func runFinal(folder: RecordingFolder, meta: RecordingMeta, draft: [DraftSegment], reveal: Bool) async {
        let id = meta.id
        let duration = (try? WavFileWriter.repair(url: folder.audioURL)) ?? 0
        defer { jobs.removeAll { $0.id == id } }

        do {
            await modelDownload?.value
            setJob(id, stage: "Preparing the model", progress: nil)
            _ = try await engine.asrModels { [weak self] fraction in
                Task { @MainActor in self?.setJob(id, stage: "Downloading the model", progress: fraction) }
            }
            finalModel = .ready

            setJob(id, stage: "Creating the final version", progress: 0)
            let words = try await engine.transcribe(fileURL: folder.audioURL) { [weak self] fraction in
                Task { @MainActor in self?.setJob(id, stage: "Creating the final version", progress: fraction) }
            }
            var labeled = words
            if !words.isEmpty {
                setJob(id, stage: "Identifying speakers", progress: 0)
                // If speaker separation fails, the transcript still comes out, without names.
                let spans = (try? await engine.diarize(fileURL: folder.audioURL, expectedSpeakers: meta.expectedSpeakers) { [weak self] fraction in
                    Task { @MainActor in self?.setJob(id, stage: "Identifying speakers", progress: fraction) }
                }) ?? []
                labeled = SpeakerAssignment.label(words, with: spans)
            }
            let paragraphs = ParagraphBuilder.words.build(labeled)
            if paragraphs.isEmpty && duration < 5 {
                try? folder.delete() // empty, very short recording: nothing to save
                return
            }

            reloadLibrary()
            let previous = transcript(id: id) // the draft saved by a failed attempt
            let document = TranscriptDocument(
                id: id,
                title: previous?.document.title ?? TranscriptLibrary.defaultTitle(for: meta.startDate),
                date: meta.startDate,
                duration: duration,
                languages: LanguageGuess.dominantLanguages(in: paragraphs.map(\.text)),
                speakers: SpeakerNames.unique(labeled.compactMap(\.speaker)),
                kind: .final,
                body: paragraphs.isEmpty
                    ? "(No speech was recognized in this recording.)"
                    : ParagraphBuilder.render(paragraphs))
            try library.save(document, replacing: previous?.url)
            // The audio is deleted only now, once the transcript is saved.
            try? folder.delete()
            reloadLibrary()
            if reveal, phase == .idle, selection == .recorder || selection == nil || selection == .transcript(id) {
                selection = .transcript(id)
            }
        } catch {
            finalFailed(folder: folder, meta: meta, draft: draft, duration: duration, error: error)
        }
    }

    /// Saves the draft instead of the final version and keeps the audio to try again.
    private func finalFailed(folder: RecordingFolder, meta: RecordingMeta, draft: [DraftSegment], duration: TimeInterval, error: Error) {
        var meta = meta
        meta.finalFailed = true
        try? folder.saveMeta(meta)

        reloadLibrary()
        var savedDraft = transcript(id: meta.id) != nil
        let paragraphs = ParagraphBuilder.sentences.build(draft.map(\.timedText))
        if !savedDraft, !paragraphs.isEmpty {
            let document = TranscriptDocument(
                id: meta.id, title: TranscriptLibrary.defaultTitle(for: meta.startDate), date: meta.startDate,
                duration: duration, languages: LanguageGuess.dominantLanguages(in: paragraphs.map(\.text)),
                kind: .draft, body: ParagraphBuilder.render(paragraphs))
            savedDraft = (try? library.save(document, replacing: nil)) != nil
            reloadLibrary()
        }
        scanPending()
        alert = AppAlert(
            title: "The final version failed",
            message: "\(error.localizedDescription)\n\n"
                + (savedDraft ? "The live draft has been saved. " : "")
                + "The audio stays on this Mac: you can try again from the sidebar.")
    }

    private func setJob(_ id: UUID, stage: String, progress: Double?) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].stage = stage
        jobs[index].progress = progress
    }

    // MARK: - Recordings to recover

    func scanPending() {
        let busy = Set(jobs.map(\.id)).union(session.map { [$0.meta.id] } ?? [])
        pending = RecordingFolder.pending().compactMap { folder, meta in
            guard !busy.contains(meta.id), !Self.isBeingWritten(folder) else { return nil }
            let duration = (try? WavFileWriter.repair(url: folder.audioURL)) ?? 0
            if duration < 1 {
                try? folder.delete() // empty: nothing to recover
                return nil
            }
            return PendingRecording(folder: folder, meta: meta, duration: duration)
        }
    }

    /// Audio written in the last 30 seconds: the recording is in progress in another copy of the app
    /// and must not be touched. If instead the app quit only recently, it will show up at the next check.
    private static func isBeingWritten(_ folder: RecordingFolder) -> Bool {
        guard let modified = try? folder.audioURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return false
        }
        return Date().timeIntervalSince(modified) < 30
    }

    func recover(_ item: PendingRecording) {
        pending.removeAll { $0.id == item.id }
        enqueueFinal(folder: item.folder, meta: item.meta, draft: item.folder.loadDraft(), reveal: true)
    }

    func discard(_ item: PendingRecording) {
        try? item.folder.delete()
        pending.removeAll { $0.id == item.id }
    }
}
