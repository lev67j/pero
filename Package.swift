// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pero",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Pero", path: "Sources/Pero")
    ]
)
