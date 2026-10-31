// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Transcriber", targets: ["Transcriber"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.0"),
    ],
    targets: [
        // Pure logic (file format, paragraphs, search): no dependencies, easy to test.
        .target(
            name: "TranscriberCore",
            path: "Sources/TranscriberCore"
        ),
        .executableTarget(
            name: "Transcriber",
            dependencies: [
                "TranscriberCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Transcriber",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TranscriberTests",
            dependencies: ["TranscriberCore"],
            path: "Tests/TranscriberTests"
        ),
    ]
)
