import AppKit
import ApplicationServices
import Foundation

guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else {
    fputs("usage: inspect-focused-element <bundle-id> [--watch]\n", stderr)
    exit(2)
}

guard AXIsProcessTrusted() else {
    fputs("Accessibility permission is not granted\n", stderr)
    exit(1)
}

let bundleIdentifier = CommandLine.arguments[1]
let watchesChanges = CommandLine.arguments.dropFirst(2).contains("--watch")
guard let application = NSRunningApplication.runningApplications(
    withBundleIdentifier: bundleIdentifier
).first else {
    fputs("Application is not running: \(bundleIdentifier)\n", stderr)
    exit(1)
}

let appElement = AXUIElementCreateApplication(application.processIdentifier)

let identityAttributes: [(attribute: String, key: String)] = [
    (kAXRoleAttribute, "role"),
    (kAXSubroleAttribute, "subrole"),
    (kAXRoleDescriptionAttribute, "roleDescription"),
    (kAXTitleAttribute, "title"),
    (kAXDescriptionAttribute, "description"),
    (kAXHelpAttribute, "help"),
    (kAXValueAttribute, "value"),
    (kAXValueDescriptionAttribute, "valueDescription"),
    (kAXIdentifierAttribute, "identifier"),
    ("AXDOMIdentifier", "domIdentifier"),
    (kAXURLAttribute, "url"),
    (kAXPlaceholderValueAttribute, "placeholderValue"),
    (kAXEnabledAttribute, "enabled"),
    (kAXFocusedAttribute, "focused"),
    (kAXSelectedAttribute, "selected"),
]

if watchesChanges {
    let stopState = StopState()
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    interruptSource.setEventHandler { stopState.stop() }
    terminationSource.setEventHandler { stopState.stop() }
    interruptSource.resume()
    terminationSource.resume()

    var previousSignature: String?
    while !stopState.isStopped {
        var output = accessibilitySnapshot(
            appElement: appElement,
            bundleIdentifier: bundleIdentifier,
            pid: application.processIdentifier
        )
        let signatureData = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        let signature = String(decoding: signatureData, as: UTF8.self)
        if signature != previousSignature {
            output["observedAt"] = isoTimestamp()
            writeJSONLine(output)
            previousSignature = signature
        }
        // A complete indexed AX snapshot is intentionally sampled at a low
        // rate. It is passive telemetry, and UI structure changes much less
        // frequently than captured video frames.
        Thread.sleep(forTimeInterval: 0.5)
    }
    interruptSource.cancel()
    terminationSource.cancel()
} else {
    var output = accessibilitySnapshot(
        appElement: appElement,
        bundleIdentifier: bundleIdentifier,
        pid: application.processIdentifier
    )
    output["observedAt"] = isoTimestamp()
    let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

final class StopState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool { lock.withLock { stopped } }
    func stop() { lock.withLock { stopped = true } }
}

func focusedElementSnapshot(
    appElement: AXUIElement,
    bundleIdentifier: String,
    pid: pid_t
) -> [String: Any]? {
    guard let focused = copyElementAttribute(appElement, kAXFocusedUIElementAttribute) else {
        return nil
    }
    var output: [String: Any] = ["bundleIdentifier": bundleIdentifier, "pid": pid]
    output["focused"] = true
    output.merge(copyIdentityAttributes(focused)) { _, new in new }

    if let position = copyPointAttribute(focused, kAXPositionAttribute),
       let size = copySizeAttribute(focused, kAXSizeAttribute) {
        output["bounds"] = boundsDictionary(position: position, size: size)
    }
    if let window = copyElementAttribute(focused, kAXWindowAttribute),
       let position = copyPointAttribute(window, kAXPositionAttribute),
       let size = copySizeAttribute(window, kAXSizeAttribute) {
        output["windowBounds"] = boundsDictionary(position: position, size: size)
    }
    return output
}

func accessibilitySnapshot(
    appElement: AXUIElement,
    bundleIdentifier: String,
    pid: pid_t
) -> [String: Any] {
    var output = focusedElementSnapshot(
        appElement: appElement,
        bundleIdentifier: bundleIdentifier,
        pid: pid
    ) ?? [
        "bundleIdentifier": bundleIdentifier,
        "pid": pid,
        "focused": false,
    ]

    var indexedElements: [[String: Any]] = []
    var nextIndex = 0
    var visited = Set<CFHashCode>()
    collectIndexedElements(
        appElement,
        index: &nextIndex,
        visited: &visited,
        output: &indexedElements,
        isApplicationRoot: true
    )
    output["elements"] = indexedElements
    if output["windowBounds"] == nil,
       let window = indexedElements.first(where: { $0["role"] as? String == "AXWindow" }),
       let bounds = window["bounds"] {
        output["windowBounds"] = bounds
    }
    return output
}

func collectIndexedElements(
    _ element: AXUIElement,
    index: inout Int,
    visited: inout Set<CFHashCode>,
    output: inout [[String: Any]],
    isApplicationRoot: Bool = false
) {
    let identity = CFHash(element)
    guard visited.insert(identity).inserted else { return }

    // Computer Use numbers the application's visible descendants, not the
    // synthetic AXApplication root itself. Preserve that same DFS index while
    // only serializing nodes that have useful geometry.
    let currentIndex: Int?
    if isApplicationRoot {
        currentIndex = nil
    } else {
        currentIndex = index
        index += 1
    }

    if let currentIndex,
       let position = copyPointAttribute(element, kAXPositionAttribute),
       let size = copySizeAttribute(element, kAXSizeAttribute),
       size.width > 0, size.height > 0 {
        var item: [String: Any] = [
            "index": currentIndex,
            "bounds": boundsDictionary(position: position, size: size),
        ]
        item.merge(copyIdentityAttributes(element)) { _, new in new }
        output.append(item)
    }

    for child in copyElementArrayAttribute(element, kAXChildrenAttribute) {
        collectIndexedElements(child, index: &index, visited: &visited, output: &output)
    }
}

func writeJSONLine(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
        return
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func isoTimestamp() -> String {
    ISO8601DateFormatter.string(
        from: Date(),
        timeZone: TimeZone(secondsFromGMT: 0)!,
        formatOptions: [.withInternetDateTime, .withFractionalSeconds]
    )
}

func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value,
          CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
}

func copyElementArrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let values = value as? [Any]
    else { return [] }
    return values.compactMap { value in
        guard CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
    }
}

func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value as? String
}

func copyIdentityAttributes(_ element: AXUIElement) -> [String: Any] {
    var copied: CFArray?
    let names = identityAttributes.map(\.attribute) as CFArray
    let options = AXCopyMultipleAttributeOptions(rawValue: 0)
    guard AXUIElementCopyMultipleAttributeValues(element, names, options, &copied) == .success,
          let values = copied as? [Any]
    else { return [:] }

    var result: [String: Any] = [:]
    for (descriptor, rawValue) in zip(identityAttributes, values) {
        if let value = jsonScalar(rawValue) { result[descriptor.key] = value }
    }
    return result
}

func jsonScalar(_ value: Any) -> Any? {
    if value is NSNull { return nil }
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value }
    if let value = value as? URL { return value.absoluteString }
    if let value = value as? NSURL { return value.absoluteString }
    return nil
}

func copyPointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value,
          CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    let axValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
}

func copySizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value,
          CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    let axValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgSize else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
}

func boundsDictionary(position: CGPoint, size: CGSize) -> [String: CGFloat] {
    [
        "x": position.x,
        "y": position.y,
        "width": size.width,
        "height": size.height,
    ]
}
