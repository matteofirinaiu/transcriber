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
