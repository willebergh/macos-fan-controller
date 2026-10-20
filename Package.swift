// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FanControl",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FanControl", targets: ["FanControl"])],
    targets: [
        .target(name: "SMCBridge", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "FanControl", dependencies: ["SMCBridge"],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]),
        .testTarget(name: "FanControlTests", dependencies: ["FanControl"])
    ]
)
