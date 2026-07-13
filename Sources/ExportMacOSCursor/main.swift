import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: export-macos-cursor <output.png>\n", stderr)
    exit(2)
}

// Initializing AppKit is required for NSCursor to resolve its system artwork and hotspot.
_ = NSApplication.shared
let cursor = NSCursor.arrow
let image = cursor.image
// NSCursor.arrow ships genuine 1x, 2x, 5x, and 10x representations. Export
// the 10x artwork so the compositor always downsamples—even with a 3x cursor,
// camera zoom, rotation, and temporal motion sampling—instead of magnifying a
// small raster.
let backingScale: CGFloat = 10
let pixelsWide = Int(ceil(image.size.width * backingScale))
let pixelsHigh = Int(ceil(image.size.height * backingScale))
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelsWide,
    pixelsHigh: pixelsHigh,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Could not allocate cursor bitmap\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create cursor graphics context\n", stderr)
    exit(1)
}
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: backingScale, y: backingScale)
image.draw(
    in: NSRect(origin: .zero, size: image.size),
    from: .zero,
    operation: .copy,
    fraction: 1
)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode cursor PNG\n", stderr)
    exit(1)
}

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(
    at: destination.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: destination, options: .atomic)

let scaleX = CGFloat(bitmap.pixelsWide) / image.size.width
let scaleY = CGFloat(bitmap.pixelsHigh) / image.size.height
let hotspotX = cursor.hotSpot.x * scaleX
let hotspotY = cursor.hotSpot.y * scaleY
let metadata: [String: Any] = [
    "pixelWidth": bitmap.pixelsWide,
    "pixelHeight": bitmap.pixelsHigh,
    "logicalWidth": image.size.width,
    "logicalHeight": image.size.height,
    "hotspotX": cursor.hotSpot.x,
    "hotspotY": cursor.hotSpot.y,
]
let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
try metadataData.write(to: URL(fileURLWithPath: destination.path + ".json"), options: .atomic)
print(
    "CURSOR_EXPORTED width=\(bitmap.pixelsWide) height=\(bitmap.pixelsHigh) " +
    "logicalWidth=\(image.size.width) logicalHeight=\(image.size.height) " +
    "hotspotX=\(hotspotX) hotspotY=\(hotspotY) output=\(destination.path)"
)
