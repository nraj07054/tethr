// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dogen",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Dogen", path: "Sources/Dogen")
    ]
)
