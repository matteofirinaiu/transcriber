import SwiftUI
import TranscriberCore

struct RecordingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .idle, .starting:
            IdleRecorder()
        case .recording, .stopping:
            ActiveRecorder()
        }
    }
}

private struct IdleRecorder: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 22) {
            Spacer()
            Button {
                Task { await model.startRecording() }
            } label: {
                ZStack {
                    Circle()
                        .fill(.red.gradient)
                        .frame(width: 96, height: 96)
                        .shadow(color: .red.opacity(0.3), radius: 10, y: 4)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.phase == .starting)
            .accessibilityLabel("Start recording")

            Text(model.phase == .starting ? "Starting…" : "Record")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 12) {
                Picker("Live draft language", selection: $model.draftLanguage) {
                    ForEach(DraftLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Speakers", selection: $model.expectedSpeakers) {
                    Text("Automatic").tag(Int?.none)
                    ForEach(2...8, id: \.self) { count in
                        Text("\(count)").tag(Optional(count))
                    }
                }
                .help("If you know how many people will speak, choose it: telling the voices apart gets more accurate.")
                MicrophonePicker()
            }
            .frame(width: 420)

            FinalModelStatusView()
                .font(.callout)

            Text("Record a lecture or a meeting. With Automatic, the live draft detects the language by itself. When you stop, the final version also tells the voices apart: Speaker 1, Speaker 2…\nKeep your MacBook open while recording: with the lid closed, the Mac goes to sleep.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ActiveRecorder: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, isActive: model.phase == .recording)
                    .font(.title2)
                if let start = model.recordingStart {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Timestamp.format(context.date.timeIntervalSince(start)))
                            .font(.title2.weight(.semibold).monospacedDigit())
                    }
                }
                LevelMeter(level: model.level)
                    .frame(width: 110, height: 8)

                Spacer()

                Picker("Draft language", selection: Binding(
                    get: { model.liveLanguage },
                    set: { language in Task { await model.switchLiveLanguage(language) } }
                )) {
                    ForEach(DraftLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 290)
                .disabled(model.liveBusy || model.phase != .recording)
                .help("Language of the live draft. Automatic detects it by itself; the final version always does.")

                Button {
                    Task { await model.stopRecording() }
                } label: {
                    Label(model.phase == .stopping ? "Finishing…" : "Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.phase != .recording)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            if let status = model.liveStatus {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
            Divider()
            LiveTranscriptView()
        }
    }
}

private struct LiveTranscriptView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let paragraphs = model.liveParagraphs
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if paragraphs.isEmpty && model.volatileText.isEmpty {
                        Text("The text will appear here as people speak. It's a draft: when you stop, you get the final, more accurate version.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        ParagraphLine(paragraph: paragraph)
                    }
                    if !model.volatileText.isEmpty {
                        Text(model.volatileText)
                            .foregroundStyle(.secondary)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("end")
                }
                .font(.system(size: 15))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .onChange(of: model.liveSegments.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.volatileText) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

private struct ParagraphLine: View {
    let paragraph: Paragraph

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Timestamp.format(paragraph.start))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(paragraph.text)
        }
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > 0.9 ? Color.orange : Color.green)
                    .frame(width: proxy.size.width * CGFloat(level))
            }
        }
        .animation(.linear(duration: 0.1), value: level)
        .accessibilityLabel("Microphone level")
    }
}

struct MicrophonePicker: View {
    @Environment(AppModel.self) private var model
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        @Bindable var model = model
        Picker("Microphone", selection: $model.inputDeviceUID) {
            Text("System default").tag(String?.none)
            ForEach(devices) { device in
                Text(device.name).tag(Optional(device.uid))
            }
        }
        .onAppear { devices = AudioDevices.inputDevices() }
    }
}

struct FinalModelStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.finalModel {
        case .checking:
            Text("Checking the transcription model…")
                .foregroundStyle(.secondary)
        case .downloading(let fraction):
            HStack {
                ProgressView(value: fraction)
                    .frame(width: 120)
                Text("Downloading the transcription model (only once): \(Int(fraction * 100))%")
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Transcription model ready", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed(let message):
            HStack {
                Label("Model download failed: \(message)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Try Again") { model.downloadModelsIfNeeded() }
            }
        }
    }
}
