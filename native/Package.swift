// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sidebar",
    platforms: [.macOS("15.0")],
    targets: [.executableTarget(name: "Sidebar", path: "Sources/Sidebar")]
)
