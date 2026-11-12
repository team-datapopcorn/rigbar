// swift-tools-version:5.10
import PackageDescription
let package = Package(
    name: "Rigbar",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Rigbar", path: "Sources/Rigbar")]
)
