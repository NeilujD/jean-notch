// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JeanNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "JeanNotchCore"),
        .executableTarget(name: "JeanNotch", dependencies: ["JeanNotchCore"]),
        .testTarget(name: "JeanNotchCoreTests", dependencies: ["JeanNotchCore"]),
    ]
)
