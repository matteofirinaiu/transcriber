import AppKit

// `Transcriber --final file.wav` and similar are test commands for the terminal (see CommandLineTool);
// otherwise the app starts.
let arguments = Array(CommandLine.arguments.dropFirst())
if let first = arguments.first, CommandLineTool.commands.contains(first) {
    Task { @MainActor in
        exit(await CommandLineTool.run(arguments))
    }
    dispatchMain()
} else {
    TranscriberApp.main()
}
