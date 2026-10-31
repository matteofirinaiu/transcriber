import SwiftUI

/// Who made the app, with links to their profiles.
enum Maker {
    struct Profile: Identifiable {
        let title: String
        let url: URL
        var id: String { title }
    }

    static let name = "Matteo Firinaiu"
    static let profiles = [
        Profile(title: "Instagram", url: URL(string: "https://www.instagram.com/matteo.firinaiu")!),
        Profile(title: "LinkedIn", url: URL(string: "https://www.linkedin.com/in/matteo-firinaiu/")!),
        Profile(title: "GitHub", url: URL(string: "https://github.com/matteofirinaiu")!),
    ]
}

/// The pop-up shown the first time the app opens.
struct WelcomeView: View {
    let onClose: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Welcome to Transcriber")
                .font(.title2.weight(.semibold))
            Text("Brought to you by \(Maker.name)")
                .font(.headline)
            Text("Free and open source. Your recordings and transcripts never leave your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(Maker.profiles) { profile in
                    Button(profile.title) { openURL(profile.url) }
                }
            }
            .padding(.top, 4)
            Button("Start Transcribing", action: onClose)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .padding(.top, 8)
        }
        .padding(28)
        .frame(width: 380)
    }
}
