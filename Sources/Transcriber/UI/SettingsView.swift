import SwiftUI
import TranscriberCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updates = model.updates
        Form {
            Section("Recording") {
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
                Toggle("Check for updates automatically", isOn: $updates.automaticChecks)
            } header: {
                Text("Updates")
            } footer: {
                Text("When it opens and once a day, Transcriber asks GitHub for the number of the newest version. Nothing about you or your recordings is sent.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Speech models") {
                    ModelStatus()
                }
            } header: {
                Text("Models")
            } footer: {
                Text("Everything runs on your Mac: no account, no tokens, and the audio never leaves your computer. The speech models download only once, from Hugging Face.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
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

private struct ModelStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.finalModel {
        case .checking:
            Text("Checking…")
                .foregroundStyle(.secondary)
        case .downloading(let fraction):
            HStack {
                ProgressView(value: fraction)
                    .frame(width: 120)
                Text("\(Int(fraction * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed(let message):
            HStack {
                Label("Download failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(message)
                Button("Try Again") { model.downloadModelsIfNeeded() }
            }
        }
    }
}
