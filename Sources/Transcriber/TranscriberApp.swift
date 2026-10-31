import AppKit
import SwiftUI

struct TranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Transcriber", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1_000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(model.phase == .recording ? "Stop Recording" : "New Recording") {
                    Task { await model.toggleRecording() }
                }
                .keyboardShortcut("r")
                .disabled(model.phase == .starting || model.phase == .stopping)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: model.phase == .recording ? "record.circle" : "waveform")
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.launch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.phase == .recording || !model.jobs.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = model.phase == .recording ? "A recording is in progress" : "A transcript is still being created"
        alert.informativeText = "If you quit now, the audio stays saved on this Mac and you can create the transcript the next time you open Transcriber."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.prepareForQuit()
        return .terminateNow
    }
}
