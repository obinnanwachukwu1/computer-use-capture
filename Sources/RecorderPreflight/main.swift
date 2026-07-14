import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

let requestedBundleIdentifier = CommandLine.arguments.dropFirst().first
let screenRecordingGranted = CGPreflightScreenCaptureAccess()
var windowCounts: [String: Int] = [:]

if screenRecordingGranted,
   let content = try? await SCShareableContent.excludingDesktopWindows(
       false,
       onScreenWindowsOnly: true
   ) {
    for window in content.windows where window.frame.width >= 320 && window.frame.height >= 240 {
        guard let bundleIdentifier = window.owningApplication?.bundleIdentifier,
              !bundleIdentifier.isEmpty else { continue }
        if requestedBundleIdentifier == nil || requestedBundleIdentifier == bundleIdentifier {
            windowCounts[bundleIdentifier, default: 0] += 1
        }
    }
} else if let requestedBundleIdentifier {
    let isRunning = NSRunningApplication.runningApplications(
        withBundleIdentifier: requestedBundleIdentifier
    ).contains { !$0.isTerminated }
    windowCounts[requestedBundleIdentifier] = isRunning ? 1 : 0
}

if let requestedBundleIdentifier, windowCounts[requestedBundleIdentifier] == nil {
    windowCounts[requestedBundleIdentifier] = 0
}

let targets: [[String: Any]] = windowCounts.keys.sorted().map { bundleIdentifier in
    let count = windowCounts[bundleIdentifier, default: 0]
    return [
        "app": bundleIdentifier,
        "available": count == 1,
        "windowCount": count,
        "selection": "single-eligible-window-required"
    ]
}

let result: [String: Any] = [
    "platform": "macOS",
    "permissions": [
        "screenRecording": screenRecordingGranted ? "granted" : "denied",
        "accessibility": AXIsProcessTrusted() ? "granted" : "denied"
    ],
    "targets": targets
]
do {
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("recorder-preflight: \(error)\n".utf8))
    Foundation.exit(1)
}
