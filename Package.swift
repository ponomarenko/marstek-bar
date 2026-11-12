// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MarstekBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MarstekBar", path: "Sources/MarstekBar")
    ]
)
