// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentRecorderSpike",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "capture-app", targets: ["CaptureSafari"]),
        .executable(name: "export-macos-cursor", targets: ["ExportMacOSCursor"]),
        .executable(name: "inspect-focused-element", targets: ["InspectFocusedElement"]),
        .executable(name: "native-compose", targets: ["NativeCompose"]),
        .executable(name: "recorder-preflight", targets: ["RecorderPreflight"]),
    ],
    targets: [
        .executableTarget(name: "CaptureSafari"),
        .executableTarget(name: "ExportMacOSCursor"),
        .executableTarget(name: "InspectFocusedElement"),
        .target(name: "NativeDirector"),
        .executableTarget(name: "NativeCompose", dependencies: ["NativeDirector"]),
        .executableTarget(name: "RecorderPreflight"),
        .testTarget(name: "NativeDirectorTests", dependencies: ["NativeDirector"]),
    ]
)
