import SwiftUI
import TranscriberCore
import UniformTypeIdentifiers

struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    let id: UUID

    @State private var title = ""
    @State private var text = ""
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var confirmTrash = false
    @State private var copied = false
    @FocusState private var titleFocused: Bool

    private var item: StoredTranscript? { model.transcript(id: id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .focused($titleFocused)
                    .onSubmit { saveNow() }
                if let item {
                    Text(metadata(item.document))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !item.document.speakers.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                Text("Speakers:")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                ForEach(item.document.speakers, id: \.self) { name in
                                    SpeakerChip(name: name) { newName in renameSpeaker(name, to: newName) }
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            TextEditor(text: $text)
                .font(.system(size: 14))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: copyAll) {
                    Label(copied ? "Copied" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy the title and text to the clipboard")
                Menu {
                    Button("Markdown (.md)…") { export(markdown: true) }
                    Button("Plain Text (.txt)…") { export(markdown: false) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Save a copy of the transcript")
                Button {
                    if let item { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Show the file in the Finder")
                Button(role: .destructive) {
                    confirmTrash = true
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .help("Move to Trash")
            }
        }
        .onAppear(perform: load)
        .onChange(of: text) { scheduleSave() }
        .onChange(of: titleFocused) { _, focused in
            if !focused { saveNow() }
        }
        .onDisappear { saveNow() }
        .confirmationDialog("Move this transcript to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                if let item { model.moveToTrash(item) }
            }
        }
    }

    private func metadata(_ document: TranscriptDocument) -> String {
        var parts = [Formatting.dateTime(document.date), Formatting.shortDuration(document.duration)]
        if document.speakers.count > 1 {
            parts.append("\(document.speakers.count) speakers")
        }
        if !document.languages.isEmpty {
            parts.append(document.languages.map(LanguageGuess.displayName).joined(separator: ", "))
        }
        parts.append(document.kind == .final ? "Final version" : "Live draft")
        return parts.joined(separator: " · ")
    }

    private func load() {
        guard !loaded, let item else { return }
        title = item.document.title
        text = item.document.body
        loaded = true
    }

    private func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { saveNow() }
        }
    }

    private func saveNow() {
        guard loaded else { return }
        saveTask?.cancel()
        model.update(id: id, title: title, body: text)
        if let item, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = item.document.title // empty title: put the previous one back
        }
    }

    private func renameSpeaker(_ old: String, to new: String) {
        saveNow()
        model.renameSpeaker(in: id, from: old, to: new)
        if let body = item?.document.body { text = body }
    }

    private func copyAll() {
        saveNow()
        guard let document = item?.document else { return }
        Clipboard.copy(document.plainText)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func export(markdown: Bool) {
        saveNow()
        guard let item else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.url.deletingPathExtension().lastPathComponent + (markdown ? ".md" : ".txt")
        panel.allowedContentTypes = [markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = markdown ? TranscriptMarkdown.render(item.document) : item.document.plainText
        do {
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            model.alert = AppAlert(title: "Export failed", message: error.localizedDescription)
        }
    }
}

/// A speaker in the transcript: click to rename them throughout the text.
private struct SpeakerChip: View {
    let name: String
    let onRename: (String) -> Void
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Button {
            draft = name
            editing = true
        } label: {
            Label(name, systemImage: "person.fill")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Rename \(name) throughout the transcript")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Rename “\(name)”")
                    .font(.headline)
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                Text("If you pick a name that's already used, the two speakers become one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Rename", action: commit)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 260)
        }
    }

    private func commit() {
        editing = false
        onRename(draft)
    }
}
