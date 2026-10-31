import Speech
import SwiftUI
import TranscriberCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var liveStatus: [DraftLanguage: String] = [:]
    @State private var downloading: DraftLanguage?

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Recording") {
                Picker("Default draft language", selection: $model.draftLanguage) {
                    ForEach(DraftLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
                MicrophonePicker()
            }

            Section("Transcripts") {
                LabeledContent("Folder") {
                    Text(model.transcriptsFolder.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Change…", action: chooseFolder)
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: model.transcriptsFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(model.transcriptsFolder)
                    }
                }
            }

            Section {
                LabeledContent("Final version and Automatic draft (Parakeet)") {
                    FinalModelStatusView()
                }
                ForEach(DraftLanguage.appleLanguages) { language in
                    LabeledContent("Live draft with macOS · \(language.label)") {
                        HStack {
                            Text(liveStatus[language] ?? "…")
                                .foregroundStyle(.secondary)
                            if liveStatus[language] == "Not downloaded" {
                                Button("Download") { download(language) }
                                    .disabled(downloading != nil)
                            }
                        }
                    }
                }
            } header: {
                Text("Models")
            } footer: {
                Text("Everything runs on your Mac: no account, no tokens, and the audio never leaves your computer. The models download only once (Parakeet and the voice detector from Hugging Face, the macOS languages from Apple).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .task { await refreshLiveStatus() }
    }

    private func refreshLiveStatus() async {
        for language in DraftLanguage.appleLanguages {
            liveStatus[language] = switch await LiveTranscriber.assetStatus(for: language) {
            case .installed: "Ready"
            case .downloading: "Downloading…"
            case .supported: "Not downloaded"
            case .unsupported: "Not supported"
            @unknown default: "Unknown"
            }
        }
    }

    private func download(_ language: DraftLanguage) {
        downloading = language
        Task {
            do {
                try await LiveTranscriber.installAssets(for: language) { status in
                    liveStatus[language] = status ?? "Ready"
                }
            } catch {
                model.alert = AppAlert(title: "Download failed", message: error.localizedDescription)
            }
            downloading = nil
            await refreshLiveStatus()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.transcriptsFolder
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            model.transcriptsFolder = url
        }
    }
}
