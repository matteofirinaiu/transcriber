import SwiftUI
import TranscriberCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 360)
        } detail: {
            switch model.selection {
            case .transcript(let id) where model.transcript(id: id) != nil:
                TranscriptView(id: id)
                    .id(id)
            default:
                RecordingView()
            }
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { alert in
            if alert.opensMicrophoneSettings {
                Button("Open System Settings") { Permissions.openMicrophoneSettings() }
            }
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .sheet(isPresented: Binding(get: { model.showWelcome }, set: { if !$0 { model.closeWelcome() } })) {
            WelcomeView(onClose: model.closeWelcome)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reloadLibrary() // files changed or deleted in the Finder
            model.scanPending()
        }
    }
}
