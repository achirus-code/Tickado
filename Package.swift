// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Tickado",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Tickado", path: "Sources/Tickado")
    ]
)
