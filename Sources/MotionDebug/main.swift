import CoreGraphics
import Foundation
import ImageIO
import NativeDirector
import UniformTypeIdentifiers

struct Raster {
    let width: Int
    let height: Int
    var pixels: [UInt8]
}

enum MotionDebugError: Error, CustomStringConvertible {
    case usage
    case decode(String)
    case sizeMismatch
    case write(String)

    var description: String {
        switch self {
        case .usage:
            "usage: motion-debug <before.png> <after.png> <output-prefix>"
        case let .decode(path):
            "could not decode \(path)"
        case .sizeMismatch:
            "before and after images must have the same dimensions"
        case let .write(path):
            "could not write \(path)"
        }
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 3 else { throw MotionDebugError.usage }
    let beforeURL = URL(fileURLWithPath: arguments[0])
    let afterURL = URL(fileURLWithPath: arguments[1])
    let outputPrefix = URL(fileURLWithPath: arguments[2])
    let before = try loadRaster(beforeURL, maximumWidth: 320)
    var after = try loadRaster(afterURL, maximumWidth: 320)
    guard before.width == after.width, before.height == after.height else {
        throw MotionDebugError.sizeMismatch
    }

    let field = SpatialMotion.motionField(
        previous: before.pixels,
        current: after.pixels,
        width: before.width,
        height: before.height
    )
    for shift in field.shifts {
        drawOutline(shift.normalizedBounds, color: (24, 132, 255), raster: &after)
    }
    for structural in field.structural {
        drawOutline(structural.normalizedBounds, color: (255, 46, 70), raster: &after)
    }
    if let focus = field.backdrop?.focusedBounds {
        drawOutline(focus, color: (42, 245, 177), raster: &after)
    }

    let overlayURL = outputPrefix.appendingPathExtension("overlay.png")
    let reportURL = outputPrefix.appendingPathExtension("motion.json")
    try writePNG(after, to: overlayURL)
    try writeReport(field, to: reportURL)
    print("motion-debug overlay=\(overlayURL.path) report=\(reportURL.path)")
} catch {
    FileHandle.standardError.write(Data("motion-debug: \(error)\n".utf8))
    exit(1)
}

func loadRaster(_ url: URL, maximumWidth: Int) throws -> Raster {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw MotionDebugError.decode(url.path) }
    let scale = min(1, Double(maximumWidth) / Double(image.width))
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw MotionDebugError.decode(url.path) }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return Raster(width: width, height: height, pixels: pixels)
}

func drawOutline(
    _ normalized: CGRect,
    color: (UInt8, UInt8, UInt8),
    raster: inout Raster
) {
    let x0 = max(0, min(raster.width - 1, Int(normalized.minX * CGFloat(raster.width))))
    let y0 = max(0, min(raster.height - 1, Int(normalized.minY * CGFloat(raster.height))))
    let x1 = max(x0, min(raster.width - 1, Int(normalized.maxX * CGFloat(raster.width)) - 1))
    let y1 = max(y0, min(raster.height - 1, Int(normalized.maxY * CGFloat(raster.height)) - 1))
    for inset in 0..<2 {
        for x in max(0, x0 - inset)...min(raster.width - 1, x1 + inset) {
            setPixel(x: x, y: max(0, y0 - inset), color: color, raster: &raster)
            setPixel(x: x, y: min(raster.height - 1, y1 + inset), color: color, raster: &raster)
        }
        for y in max(0, y0 - inset)...min(raster.height - 1, y1 + inset) {
            setPixel(x: max(0, x0 - inset), y: y, color: color, raster: &raster)
            setPixel(x: min(raster.width - 1, x1 + inset), y: y, color: color, raster: &raster)
        }
    }
}

func setPixel(
    x: Int,
    y: Int,
    color: (UInt8, UInt8, UInt8),
    raster: inout Raster
) {
    let offset = (y * raster.width + x) * 4
    raster.pixels[offset] = color.0
    raster.pixels[offset + 1] = color.1
    raster.pixels[offset + 2] = color.2
    raster.pixels[offset + 3] = 255
}

func writePNG(_ raster: Raster, to url: URL) throws {
    let data = Data(raster.pixels)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(
            width: raster.width,
            height: raster.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: raster.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
          )
    else { throw MotionDebugError.write(url.path) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw MotionDebugError.write(url.path) }
}

func writeReport(_ field: MotionField, to url: URL) throws {
    func rect(_ value: CGRect) -> [String: Double] {
        ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
    }
    var report: [String: Any] = [
        "version": 1,
        "raster": ["width": field.rasterSize.width, "height": field.rasterSize.height],
        "tileSize": field.tileSize,
        "shifts": field.shifts.map {
            [
                "bounds": rect($0.normalizedBounds),
                "vector": ["dx": $0.normalizedVector.dx, "dy": $0.normalizedVector.dy],
                "supportFraction": $0.supportFraction,
                "confidence": $0.confidence,
                "density": $0.density
            ] as [String: Any]
        },
        "structural": field.structural.map {
            [
                "bounds": rect($0.normalizedBounds),
                "changedFraction": $0.changedFraction,
                "density": $0.density,
                "energy": $0.energy,
                "polarity": $0.polarity.rawValue
            ] as [String: Any]
        }
    ]
    if let photometric = field.photometric {
        report["photometric"] = [
            "coveredFraction": photometric.coveredFraction,
            "gain": photometric.meanGain,
            "offset": photometric.meanOffset,
            "residual": photometric.meanResidual,
            "direction": photometric.direction.rawValue
        ] as [String: Any]
    }
    if let backdrop = field.backdrop {
        var context: [String: Any] = [
            "coveredFraction": backdrop.coveredFraction,
            "explainedChangeFraction": backdrop.explainedChangeFraction,
            "blurRadius": backdrop.blurRadius,
            "gain": backdrop.gain,
            "offset": backdrop.offset,
            "residual": backdrop.residual,
            "confidence": backdrop.confidence,
            "direction": backdrop.direction.rawValue
        ]
        if let focus = backdrop.focusedBounds { context["focusedBounds"] = rect(focus) }
        report["backdrop"] = context
    }
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}
