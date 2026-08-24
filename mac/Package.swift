// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tethr",
    // Spelled as a string rather than .v26: the enum case needs
    // swift-tools-version 6.2, which would also flip the package to the
    // Swift 6 language mode and its stricter concurrency checking — a much
    // bigger change than the floor this is raising.
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Tethr",
            path: "Sources/Tethr",
            resources: [.process("Resources")]
        )
    ]
)
