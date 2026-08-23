// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tethr",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tethr",
            path: "Sources/Tethr",
            resources: [.process("Resources")]
        )
    ]
)
