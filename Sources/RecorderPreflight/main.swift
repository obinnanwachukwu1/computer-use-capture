import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

let screenRecordingGranted = CGPreflightScreenCaptureAccess()
let safariWindowCount: Int
if screenRecordingGranted,
   let content = try? await SCShareableContent.excludingDesktopWindows(
       false,
       onScreenWindowsOnly: true
   ) {
    safariWindowCount = content.windows.filter { window in
        window.owningApplication?.bundleIdentifier == "com.apple.Safari"
            && window.frame.width >= 320
            && window.frame.height >= 240
    }.count
} else {
    safariWindowCount = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.Safari"
    ).contains { !$0.isTerminated } ? 1 : 0
}

let result: [String: Any] = [
    "platform": "macOS",
    "permissions": [
        "screenRecording": screenRecordingGranted ? "granted" : "denied",
        "accessibility": AXIsProcessTrusted() ? "granted" : "denied"
    ],
    "targets": [[
        "app": "com.apple.Safari",
        "available": safariWindowCount == 1,
        "windowCount": safariWindowCount,
        "selection": "single-eligible-window-required"
    ]]
]
do {
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("recorder-preflight: \(error)\n".utf8))
    Foundation.exit(1)
}
