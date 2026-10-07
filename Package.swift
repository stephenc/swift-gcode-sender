// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GCodeSender",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GCodeSender", targets: ["GCodeSender"]),
        .library(name: "GCodeKit", targets: ["GCodeKit"])
    ],
    targets: [
        .target(name: "GCodeKit"),
        .executableTarget(
            name: "GCodeSender",
            dependencies: ["GCodeKit"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(name: "GCodeKitTests", dependencies: ["GCodeKit"])
    ],
    swiftLanguageModes: [.v5]
)
