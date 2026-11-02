import SwiftUI
import TranscriberCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                RecorderRow()
                    .tag(SidebarItem.recorder)
            }

            if !model.jobs.isEmpty || !model.pending.isEmpty {
                Section("In Progress") {
                    ForEach(model.jobs) { job in
                        JobRow(job: job)
                    }
                    ForEach(model.pending) { item in
                        PendingRow(item: item)
                    }
                }
            }

            Section("Transcripts") {
                let items = model.visibleTranscripts
                if items.isEmpty {
                    Text(model.searchText.isEmpty ? "No transcripts yet" : "No results")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    TranscriptRow(item: item)
                        .tag(SidebarItem.transcript(item.id))
                        .contextMenu {
                            Button("Copy Text") { Clipboard.copy(item.document.plainText) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                            Divider()
                            Button("Move to Trash", role: .destructive) { model.moveToTrash(item) }
                        }
                }
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search transcripts")
        .safeAreaInset(edge: .bottom) { SidebarFooter() }
    }
}

/// Always at the bottom of the sidebar: who made the app (the name opens their profiles), the version
/// (click it to check for updates) and, when there is one, the update.
struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            UpdateStatus()
            HStack(spacing: 4) {
                Text("Made by")
                Menu {
                    ForEach(Maker.profiles) { profile in
                        Button(profile.title) { openURL(profile.url) }
                    }
                } label: {
                    Text(Maker.name)
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Instagram, LinkedIn and GitHub")
                Spacer(minLength: 4)
                Button("v\(UpdateChecker.currentVersion)") {
                    Task { await model.updates.check(userInitiated: true) }
                }
                .buttonStyle(.borderless)
                .help("Check for updates")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct UpdateStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.updates.state {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .upToDate:
            Label("Transcriber is up to date", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .available(let version):
            Button {
                Task { await model.downloadUpdate() }
            } label: {
                Label("Update to \(version)", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .help("Download Transcriber \(version)")
        case .downloading(let version):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading \(version)…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .downloaded(let version):
            Button {
                model.finishUpdate(version)
            } label: {
                Label("Install \(version)…", systemImage: "arrow.down.app.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RecorderRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.phase == .recording, let start = model.recordingStart {
            HStack {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                Text("Recording")
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Timestamp.format(context.date.timeIntervalSince(start)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } else if case .downloading(let fraction) = model.finalModel {
            Label("Getting ready… \(Int(fraction * 100))%", systemImage: "arrow.down.circle")
        } else {
            Label("New Recording", systemImage: "mic")
        }
    }
}

private struct TranscriptRow: View {
    let item: StoredTranscript

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.document.title)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(Formatting.dateTime(item.document.date))
                Text("·")
                Text(Formatting.shortDuration(item.document.duration))
                if item.document.kind == .draft {
                    Text("Draft")
                        .padding(.horizontal, 5)
                        .background(.orange.opacity(0.2), in: Capsule())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct JobRow: View {
    let job: FinalJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(job.title)
                .lineLimit(1)
            if let progress = job.progress {
                ProgressView(value: progress)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            Text(job.stage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct PendingRow: View {
    @Environment(AppModel.self) private var model
    let item: PendingRecording
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .lineLimit(1)
            Text("\(item.meta.finalFailed ? "Final version failed" : "Recording interrupted") · \(Formatting.shortDuration(item.duration))")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(item.meta.finalFailed ? "Try Again" : "Create Transcript") { model.recover(item) }
                Button("Delete Audio", role: .destructive) { confirmDiscard = true }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        .confirmationDialog("Delete the audio of this recording?", isPresented: $confirmDiscard) {
            Button("Delete Audio", role: .destructive) { model.discard(item) }
        } message: {
            Text("You won't be able to transcribe it anymore.")
        }
    }
}
