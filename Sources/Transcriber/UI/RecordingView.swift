import SwiftUI
import TranscriberCore

struct RecordingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .idle, .starting:
            if model.finalModel == .ready {
                IdleRecorder()
            } else {
                ModelSetupView(state: model.finalModel, retry: model.downloadModelsIfNeeded)
            }
        case .recording, .stopping:
            ActiveRecorder()
        }
    }
}

private struct IdleRecorder: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Button {
                Task { await model.startRecording() }
            } label: {
                ZStack {
                    Circle()
                        .fill(.red.gradient)
                        .frame(width: 112, height: 112)
                        .shadow(color: .red.opacity(0.35), radius: 14, y: 6)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.phase == .starting)
            .accessibilityLabel("Start recording")

            VStack(spacing: 6) {
                Text(model.phase == .starting ? "Starting…" : "Record")
                    .font(.title.weight(.semibold))
                Text("A lecture or a meeting. The language is detected by itself.")
                    .foregroundStyle(.secondary)
            }

            MicrophonePicker()
                .frame(width: 320)

            Spacer()

            Text("When you stop, Transcriber writes the final version and tells the voices apart.\nKeep your MacBook open while recording: with the lid closed, the Mac goes to sleep.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Until the speech models are on the Mac, this takes the place of the record button: without them
/// there would be neither the live draft nor the final version.
struct ModelSetupView: View {
    let state: FinalModelState
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            VStack(spacing: 10) {
                Text("Getting Transcriber ready")
                    .font(.largeTitle.weight(.semibold))
                Text("Transcriber is downloading its speech models, about 640 MB. It happens only once: after that, everything works offline.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480)
            }

            switch state {
            case .failed(let message):
                VStack(spacing: 12) {
                    Label("The download stopped: \(message)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 480)
                    Button("Try Again", action: retry)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            case .downloading(let fraction):
                VStack(spacing: 8) {
                    ProgressView(value: fraction)
                        .frame(width: 420)
                    Text("\(Int(fraction * 100))%")
                        .font(.title2.weight(.semibold).monospacedDigit())
                }
            default:
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 420)
            }

            Label("Keep Transcriber open and stay on Wi-Fi. You can record as soon as it's done.", systemImage: "wifi")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(48)
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
                    .frame(width: 140, height: 8)

                Spacer()

                Button {
                    Task { await model.stopRecording() }
                } label: {
                    Label(model.phase == .stopping ? "Finishing…" : "Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
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
