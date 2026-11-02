import SwiftUI

/// The menu of the menu bar icon.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch model.phase {
        case .recording:
            Button("Stop Recording") { Task { await model.stopRecording() } }
        case .idle where model.canStartRecording:
            Button("Start Recording") {
                showMainWindow()
                Task { await model.startRecording() }
            }
        case .idle:
            Text("Downloading the speech models…")
        case .starting, .stopping:
            Text("One moment…")
        }
        if !model.jobs.isEmpty {
            Text("Preparing the final version…")
        }
        Divider()
        Button("Open Transcriber", action: showMainWindow)
        SettingsLink {
            Text("Settings…")
        }
        Divider()
        Button("Quit Transcriber") { NSApp.terminate(nil) }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
