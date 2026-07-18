// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ComputerUseCapture",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "capture-app", targets: ["CaptureSafari"]),
        .executable(name: "export-macos-cursor", targets: ["ExportMacOSCursor"]),
        .executable(name: "inspect-focused-element", targets: ["InspectFocusedElement"]),
        .executable(name: "motion-debug", targets: ["MotionDebug"]),
        .executable(name: "motion-field-video", targets: ["MotionFieldVideo"]),
        .executable(name: "native-compose", targets: ["NativeCompose"]),
        .executable(name: "recorder-preflight", targets: ["RecorderPreflight"]),
    ],
    targets: [
        .target(name: "CaptureTruth"),
        .executableTarget(name: "CaptureSafari", dependencies: ["CaptureTruth"]),
        .executableTarget(name: "ExportMacOSCursor"),
        .executableTarget(name: "InspectFocusedElement"),
        .executableTarget(name: "MotionDebug", dependencies: ["NativeDirector"]),
        .executableTarget(name: "MotionFieldVideo", dependencies: ["NativeDirector"]),
        .target(name: "NativeDirector"),
        .executableTarget(name: "NativeCompose", dependencies: ["CaptureTruth", "NativeDirector"]),
        .executableTarget(name: "RecorderPreflight"),
        .testTarget(name: "NativeDirectorTests", dependencies: ["NativeDirector"]),
        .testTarget(name: "CaptureTruthTests", dependencies: ["CaptureTruth"]),
    ]
)
