import CoreGraphics
import Foundation

/// A loss-minimizing description of the visual change between two frames.
///
/// `MotionField` is deliberately observational. It does not decide whether a
/// change should move the camera. In particular, a viewport-wide lighting or
/// blur change is context, not a geometric subject.
public struct MotionField: Sendable {
    public let beforeTime: Double
    public let afterTime: Double
    public let rasterSize: CGSize
    public let tileSize: Int
    public let photometric: PhotometricMotionContext?
    public let backdrop: BackdropMotionContext?
    public let shifts: [MotionShiftComponent]
    public let structural: [StructuralMotionComponent]

    public init(
        beforeTime: Double,
        afterTime: Double,
        rasterSize: CGSize,
        tileSize: Int,
        photometric: PhotometricMotionContext?,
        backdrop: BackdropMotionContext?,
        shifts: [MotionShiftComponent],
        structural: [StructuralMotionComponent]
    ) {
        self.beforeTime = beforeTime
        self.afterTime = afterTime
        self.rasterSize = rasterSize
        self.tileSize = tileSize
        self.photometric = photometric
        self.backdrop = backdrop
        self.shifts = shifts
        self.structural = structural
    }

    /// Structural evidence eligible to steer attention. When a backdrop
    /// establishes an explicit foreground, residual motion elsewhere remains
    /// observable in `structural` but cannot compete with that foreground.
    public var focusedStructural: [StructuralMotionComponent] {
        guard let focus = backdrop?.focusedBounds else { return structural }
        let overlapping = structural.filter { component in
            let shared = component.normalizedBounds.intersection(focus)
            guard !shared.isNull else { return false }
            let componentArea = component.normalizedBounds.width * component.normalizedBounds.height
            let focusArea = focus.width * focus.height
            let sharedArea = shared.width * shared.height
            return sharedArea / max(0.000_001, min(componentArea, focusArea)) >= 0.25
        }
        guard let dominant = overlapping.max(by: { $0.changedFraction < $1.changedFraction }) else { return [] }
        return [StructuralMotionComponent(
            normalizedBounds: focus,
            changedFraction: min(1, overlapping.reduce(0) { $0 + $1.changedFraction }),
            density: dominant.density,
            energy: overlapping.map(\.energy).max() ?? dominant.energy,
            polarity: dominant.polarity,
            tileIndices: overlapping.flatMap(\.tileIndices).sorted()
        )]
    }

    /// A coherent viewport relocation is scene context, not a local subject.
    /// Large page scrolls often exceed the tile matcher's bounded local search,
    /// so the field also carries the result of whole-raster registration.
    public var viewportTranslation: MotionShiftComponent? {
        shifts.filter { component in
            component.normalizedBounds.width * component.normalizedBounds.height >= 0.70
                && hypot(component.normalizedVector.dx, component.normalizedVector.dy) >= 0.05
                && component.supportFraction >= 0.42
        }.max { $0.confidence < $1.confidence }
    }

    public func framingObservations(at time: Double) -> [VisualMotionObservation] {
        let structure = focusedStructural.map { component in
            VisualMotionObservation(
                time: time,
                normalizedBounds: component.normalizedBounds,
                changedFraction: component.changedFraction,
                magnitude: component.energy,
                kind: .appearance
            )
        }
        let translations = shifts.map { component in
            VisualMotionObservation(
                time: time,
                normalizedBounds: component.normalizedBounds,
                changedFraction: component.supportFraction,
                magnitude: component.confidence,
                kind: .translation
            )
        }
        return structure + translations
    }
}

public enum PhotometricDirection: String, Sendable, Codable {
    case dimming
    case undimming
    case mixed
}

public struct PhotometricMotionContext: Sendable {
    public let coveredFraction: Double
    public let meanGain: Double
    public let meanOffset: Double
    public let meanResidual: Double
    public let direction: PhotometricDirection
    public let tileIndices: [Int]
}

public enum BackdropDirection: String, Sendable, Codable {
    case focusGained
    case focusReleased
    case transformed
}

/// A viewport-spanning, low-frequency transformation such as the dimming and
/// backdrop blur behind a modal. Its geometry is context, never a camera
/// target. `focusedBounds` identifies the residual foreground subject that
/// was not explained by that transformation.
public struct BackdropMotionContext: Sendable {
    public let coveredFraction: Double
    public let explainedChangeFraction: Double
    public let blurRadius: Int
    public let gain: Double
    public let offset: Double
    public let residual: Double
    public let confidence: Double
    public let direction: BackdropDirection
    public let focusedBounds: CGRect?
    public let tileIndices: [Int]
}

public struct MotionShiftComponent: Sendable {
    public let normalizedBounds: CGRect
    public let normalizedVector: CGVector
    public let supportFraction: Double
    public let confidence: Double
    public let density: Double
    public let tileIndices: [Int]
}

public enum StructuralMotionPolarity: String, Sendable, Codable {
    case appear
    case vanish
    case replace
}

public struct StructuralMotionComponent: Sendable {
    public let normalizedBounds: CGRect
    public let changedFraction: Double
    public let density: Double
    public let energy: Double
    public let polarity: StructuralMotionPolarity
    public let tileIndices: [Int]
}

public struct MotionFieldConfiguration: Sendable {
    public var channelThreshold: Int
    public var minimumChangedPixelsPerTile: Int
    public var tileSize: Int
    public var photometricCorrelationThreshold: Double
    public var photometricResidualThreshold: Double
    public var shiftResidualThreshold: Double
    public var shiftImprovementRatio: Double
    public var maximumShift: Int
    public var shiftStep: Int
    public var coherentShiftMinimumCoverage: Double
    public var viewportShiftMinimumSpan: Double
    public var minimumCoherentShiftTiles: Int
    public var photometricSeedCoverage: Double
    public var photometricExpansionResidualThreshold: Double
    public var backdropResidualThreshold: Double
    public var backdropMinimumExplainedChange: Double

    public init(
        channelThreshold: Int = 20,
        minimumChangedPixelsPerTile: Int = 2,
        tileSize: Int = 6,
        photometricCorrelationThreshold: Double = 0.90,
        photometricResidualThreshold: Double = 8,
        shiftResidualThreshold: Double = 12,
        shiftImprovementRatio: Double = 0.62,
        maximumShift: Int = 48,
        shiftStep: Int = 4,
        coherentShiftMinimumCoverage: Double = 0.35,
        viewportShiftMinimumSpan: Double = 0.70,
        minimumCoherentShiftTiles: Int = 6,
        photometricSeedCoverage: Double = 0.04,
        photometricExpansionResidualThreshold: Double = 16,
        backdropResidualThreshold: Double = 15,
        backdropMinimumExplainedChange: Double = 0.25
    ) {
        self.channelThreshold = channelThreshold
        self.minimumChangedPixelsPerTile = minimumChangedPixelsPerTile
        self.tileSize = tileSize
        self.photometricCorrelationThreshold = photometricCorrelationThreshold
        self.photometricResidualThreshold = photometricResidualThreshold
        self.shiftResidualThreshold = shiftResidualThreshold
        self.shiftImprovementRatio = shiftImprovementRatio
        self.maximumShift = maximumShift
        self.shiftStep = shiftStep
        self.coherentShiftMinimumCoverage = coherentShiftMinimumCoverage
        self.viewportShiftMinimumSpan = viewportShiftMinimumSpan
        self.minimumCoherentShiftTiles = minimumCoherentShiftTiles
        self.photometricSeedCoverage = photometricSeedCoverage
        self.photometricExpansionResidualThreshold = photometricExpansionResidualThreshold
        self.backdropResidualThreshold = backdropResidualThreshold
        self.backdropMinimumExplainedChange = backdropMinimumExplainedChange
    }

    /// Returns a tile size with the same normalized width as the reference
    /// analysis grid. This keeps grouping and focus padding invariant when a
    /// caller stores a lower-resolution response raster.
    public static func normalizedTileSize(
        forRasterWidth width: Int,
        referenceWidth: Int = 320,
        referenceTileSize: Int = 6
    ) -> Int {
        guard width > 0, referenceWidth > 0, referenceTileSize > 0 else { return 2 }
        return max(2, Int((Double(width * referenceTileSize) / Double(referenceWidth)).rounded()))
    }
}

public extension SpatialMotion {
    /// Explains every materially changed tile using the simplest model that
    /// fits it: photometric change, coherent shift, or otherwise structural
    /// replacement. Connectivity is applied only after explanation, so noisy
    /// classification cannot determine object topology.
    static func motionField(
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        height: Int,
        beforeTime: Double = 0,
        afterTime: Double = 0,
        configuration: MotionFieldConfiguration = .init()
    ) -> MotionField {
        guard previous.count == current.count,
              current.count == width * height * 4,
              width > 0,
              height > 0
        else {
            return MotionField(
                beforeTime: beforeTime,
                afterTime: afterTime,
                rasterSize: CGSize(width: width, height: height),
                tileSize: configuration.tileSize,
                photometric: nil,
                backdrop: nil,
                shifts: [],
                structural: []
            )
        }

        let tileSize = max(2, configuration.tileSize)
        let columns = Int(ceil(Double(width) / Double(tileSize)))
        let rows = Int(ceil(Double(height) / Double(tileSize)))
        var tiles: [ExplainedTile] = []
        tiles.reserveCapacity(columns * rows)

        for tileY in 0..<rows {
            for tileX in 0..<columns {
                let index = tileY * columns + tileX
                let rect = PixelRect(
                    minX: tileX * tileSize,
                    minY: tileY * tileSize,
                    maxX: min(width, (tileX + 1) * tileSize),
                    maxY: min(height, (tileY + 1) * tileSize)
                )
                let statistics = tileStatistics(
                    previous: previous,
                    current: current,
                    width: width,
                    rect: rect,
                    channelThreshold: configuration.channelThreshold
                )
                guard statistics.changedPixels >= configuration.minimumChangedPixelsPerTile else { continue }

                if statistics.correlation >= configuration.photometricCorrelationThreshold,
                   statistics.affineResidual <= configuration.photometricResidualThreshold {
                    tiles.append(ExplainedTile(
                        index: index,
                        rect: rect,
                        changedPixels: statistics.changedPixels,
                        meanDelta: statistics.meanDelta,
                        energy: statistics.rawEnergy,
                        beforeDetail: statistics.beforeDetail,
                        afterDetail: statistics.afterDetail,
                        explanation: .photometric(
                            gain: statistics.gain,
                            offset: statistics.offset,
                            residual: statistics.affineResidual
                        )
                    ))
                    continue
                }

                tiles.append(ExplainedTile(
                    index: index,
                    rect: rect,
                    changedPixels: statistics.changedPixels,
                    meanDelta: statistics.meanDelta,
                    energy: statistics.rawEnergy,
                    beforeDetail: statistics.beforeDetail,
                    afterDetail: statistics.afterDetail,
                    explanation: .structural
                ))
            }
        }

        let backdropDetection = detectBackdrop(
            tiles: tiles,
            previous: previous,
            current: current,
            width: width,
            height: height,
            configuration: configuration
        )
        if let backdropDetection {
            let indices = backdropDetection.tileIndices
            tiles = tiles.map { tile in
                indices.contains(tile.index)
                    ? tile.replacingExplanation(.backdrop(residual: backdropDetection.residual))
                    : tile
            }
        }
        tiles = expandPhotometricExplanation(
            tiles: tiles,
            previous: previous,
            current: current,
            width: width,
            height: height,
            configuration: configuration
        )
        tiles = classifyResidualShifts(
            tiles: tiles,
            previous: previous,
            current: current,
            width: width,
            height: height,
            tileSize: tileSize,
            configuration: configuration
        )
        tiles = rejectIncoherentShifts(
            tiles: tiles,
            columns: columns,
            width: width,
            height: height,
            minimumTiles: configuration.minimumCoherentShiftTiles
        )
        tiles = reconcileCoherentShift(
            tiles: tiles,
            previous: previous,
            current: current,
            width: width,
            height: height,
            configuration: configuration
        )

        let photometricTiles = tiles.filter { if case .photometric = $0.explanation { true } else { false } }
        let photometric = makePhotometricContext(
            tiles: photometricTiles,
            totalPixels: width * height,
            tileSize: tileSize
        )
        let structural = connectedComponents(
            tiles: tiles.filter { $0.explanation == .structural },
            columns: columns,
            width: width,
            height: height
        ).map { component in
            makeStructuralComponent(component, width: width, height: height)
        }
        var shifts = makeShiftComponents(
            tiles: tiles,
            columns: columns,
            width: width,
            height: height
        )
        if let viewport = detectLargeViewportTranslation(
            previous: previous,
            current: current,
            width: width,
            height: height
        ), !shifts.contains(where: {
            $0.normalizedBounds.width * $0.normalizedBounds.height >= 0.70
                && hypot(
                    $0.normalizedVector.dx - viewport.normalizedVector.dx,
                    $0.normalizedVector.dy - viewport.normalizedVector.dy
                ) < 0.025
        }) {
            shifts.append(viewport)
        }

        let backdrop = backdropDetection.map {
            makeBackdropContext(
                $0,
                structural: structural,
                columns: columns,
                width: width,
                height: height,
                tileSize: tileSize
            )
        }
        return MotionField(
            beforeTime: beforeTime,
            afterTime: afterTime,
            rasterSize: CGSize(width: width, height: height),
            tileSize: tileSize,
            photometric: photometric,
            backdrop: backdrop,
            shifts: shifts,
            structural: structural
        )
    }
}

/// Registers the textured viewport as a whole over large vertical distances.
/// This complements the per-tile motion model: tile search stays bounded for
/// performance, while page-level scrolls retain their global scene meaning.
private func detectLargeViewportTranslation(
    previous: [UInt8],
    current: [UInt8],
    width: Int,
    height: Int
) -> MotionShiftComponent? {
    guard width >= 48, height >= 48 else { return nil }
    let x0 = max(0, Int(Double(width) * 0.08))
    let x1 = min(width, Int(Double(width) * 0.98))
    let y0 = max(0, Int(Double(height) * 0.08))
    let y1 = min(height, Int(Double(height) * 0.95))
    let minimumShift = max(6, Int(Double(height) * 0.05))
    let maximumShift = max(minimumShift, Int(Double(y1 - y0) * 0.52))

    func residual(dy: Int) -> Double {
        let startY = y0 + max(0, -dy)
        let endY = y1 - max(0, dy)
        guard endY > startY else { return .infinity }
        var total = 0.0
        var count = 0
        for currentY in stride(from: startY, to: endY, by: 4) {
            let previousY = currentY + dy
            for x in stride(from: x0, to: x1, by: 4) {
                let before = (previousY * width + x) * 4
                let after = (currentY * width + x) * 4
                total += (
                    abs(Double(previous[before]) - Double(current[after]))
                    + abs(Double(previous[before + 1]) - Double(current[after + 1]))
                    + abs(Double(previous[before + 2]) - Double(current[after + 2]))
                ) / 3
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : .infinity
    }

    let stationary = residual(dy: 0)
    guard stationary >= 6 else { return nil }
    var bestShift = 0
    var bestResidual = Double.infinity
    for magnitude in stride(from: minimumShift, through: maximumShift, by: 4) {
        for dy in [magnitude, -magnitude] {
            let value = residual(dy: dy)
            if value < bestResidual {
                bestResidual = value
                bestShift = dy
            }
        }
    }
    // Text rasterization is sensitive to a one-pixel registration error. Use
    // a sparse coarse search, then refine only around its winner.
    let coarse = bestShift
    for dy in (coarse - 3)...(coarse + 3) where abs(dy) >= minimumShift && abs(dy) <= maximumShift {
        let value = residual(dy: dy)
        if value < bestResidual {
            bestResidual = value
            bestShift = dy
        }
    }
    let overlap = Double(y1 - y0 - abs(bestShift)) / Double(max(1, y1 - y0))
    let improvement = 1 - bestResidual / max(0.001, stationary)
    guard overlap >= 0.42,
          bestResidual <= 12,
          bestResidual <= stationary * 0.62,
          improvement >= 0.38
    else { return nil }
    return MotionShiftComponent(
        normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        normalizedVector: CGVector(dx: 0, dy: Double(bestShift) / Double(height)),
        supportFraction: overlap,
        confidence: min(1, max(0, improvement)),
        density: overlap,
        tileIndices: []
    )
}

private enum TileExplanation: Equatable {
    case photometric(gain: Double, offset: Double, residual: Double)
    case backdrop(residual: Double)
    case shift(dx: Int, dy: Int, confidence: Double)
    case structural
}

private struct ExplainedTile {
    let index: Int
    let rect: PixelRect
    let changedPixels: Int
    let meanDelta: Double
    let energy: Double
    let beforeDetail: Double
    let afterDetail: Double
    let explanation: TileExplanation

    func replacingExplanation(_ explanation: TileExplanation) -> ExplainedTile {
        ExplainedTile(
            index: index,
            rect: rect,
            changedPixels: changedPixels,
            meanDelta: meanDelta,
            energy: energy,
            beforeDetail: beforeDetail,
            afterDetail: afterDetail,
            explanation: explanation
        )
    }
}

private struct PixelRect {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    var width: Int { maxX - minX }
    var height: Int { maxY - minY }
    var area: Int { width * height }

    func expanded(by amount: Int, width: Int, height: Int) -> PixelRect {
        PixelRect(
            minX: max(0, minX - amount),
            minY: max(0, minY - amount),
            maxX: min(width, maxX + amount),
            maxY: min(height, maxY + amount)
        )
    }
}

private struct TileStatistics {
    let changedPixels: Int
    let rawEnergy: Double
    let meanDelta: Double
    let gain: Double
    let offset: Double
    let correlation: Double
    let affineResidual: Double
    let beforeDetail: Double
    let afterDetail: Double
}

private func tileStatistics(
    previous: [UInt8],
    current: [UInt8],
    width: Int,
    rect: PixelRect,
    channelThreshold: Int
) -> TileStatistics {
    var changedPixels = 0
    var rawEnergy = 0.0
    var beforeValues: [Double] = []
    var afterValues: [Double] = []
    beforeValues.reserveCapacity(rect.area)
    afterValues.reserveCapacity(rect.area)

    for y in rect.minY..<rect.maxY {
        for x in rect.minX..<rect.maxX {
            let offset = (y * width + x) * 4
            let redDelta = abs(Int(current[offset]) - Int(previous[offset]))
            let greenDelta = abs(Int(current[offset + 1]) - Int(previous[offset + 1]))
            let blueDelta = abs(Int(current[offset + 2]) - Int(previous[offset + 2]))
            let delta = max(redDelta, greenDelta, blueDelta)
            if delta >= channelThreshold { changedPixels += 1 }
            rawEnergy += Double(delta)
            beforeValues.append(luminance(previous, at: offset))
            afterValues.append(luminance(current, at: offset))
        }
    }

    let count = max(1, beforeValues.count)
    let beforeMean = beforeValues.reduce(0, +) / Double(count)
    let afterMean = afterValues.reduce(0, +) / Double(count)
    var beforeVariance = 0.0
    var afterVariance = 0.0
    var covariance = 0.0
    for index in beforeValues.indices {
        let beforeCentered = beforeValues[index] - beforeMean
        let afterCentered = afterValues[index] - afterMean
        beforeVariance += beforeCentered * beforeCentered
        afterVariance += afterCentered * afterCentered
        covariance += beforeCentered * afterCentered
    }
    let gain = beforeVariance > 0.001 ? covariance / beforeVariance : 0
    let affineOffset = afterMean - gain * beforeMean
    let correlation = beforeVariance > 0.001 && afterVariance > 0.001
        ? covariance / sqrt(beforeVariance * afterVariance)
        : 0
    var residualSquared = 0.0
    for index in beforeValues.indices {
        let predicted = gain * beforeValues[index] + affineOffset
        let residual = afterValues[index] - predicted
        residualSquared += residual * residual
    }

    return TileStatistics(
        changedPixels: changedPixels,
        rawEnergy: rawEnergy / Double(count),
        meanDelta: afterMean - beforeMean,
        gain: gain,
        offset: affineOffset,
        correlation: correlation,
        affineResidual: sqrt(residualSquared / Double(count)),
        beforeDetail: sqrt(beforeVariance / Double(count)),
        afterDetail: sqrt(afterVariance / Double(count))
    )
}

private func luminance(_ pixels: [UInt8], at offset: Int) -> Double {
    0.299 * Double(pixels[offset])
        + 0.587 * Double(pixels[offset + 1])
        + 0.114 * Double(pixels[offset + 2])
}

private struct BackdropDetection {
    let coveredFraction: Double
    let explainedChangeFraction: Double
    let blurRadius: Int
    let gain: Double
    let offset: Double
    let residual: Double
    let confidence: Double
    let direction: BackdropDirection
    /// Mean current-minus-previous luminance over tiles explained by the
    /// backdrop model. Unlike the fitted direction, this remains in forward
    /// timeline order and therefore disambiguates dim-overlay gain/release.
    let temporalMeanDelta: Double
    let tileIndices: Set<Int>
    let tileResiduals: [Int: Double]
    let tileDetails: [Int: Double]
}

private struct AffineFit {
    let gain: Double
    let offset: Double
    let residual: Double
}

/// Finds a viewport-spanning low-frequency relationship before structural
/// grouping. Both temporal directions are evaluated: opening compares a
/// blurred previous frame with the current frame, while closing compares a
/// blurred current frame with the previous frame. This makes focus gain and
/// release symmetric without relying on a dialog-specific animation order.
private func detectBackdrop(
    tiles: [ExplainedTile],
    previous: [UInt8],
    current: [UInt8],
    width: Int,
    height: Int,
    configuration: MotionFieldConfiguration
) -> BackdropDetection? {
    guard tiles.count >= 12 else { return nil }
    let previousPlane = luminancePlane(previous, width: width, height: height)
    let currentPlane = luminancePlane(current, width: width, height: height)
    var best: (score: Double, detection: BackdropDetection)?

    for direction in [BackdropDirection.focusGained, .focusReleased] {
        for radius in 0...4 {
            let source: [Double]
            let target: [Double]
            switch direction {
            case .focusGained:
                source = boxBlur(previousPlane, width: width, height: height, radius: radius)
                target = currentPlane
            case .focusReleased:
                source = boxBlur(currentPlane, width: width, height: height, radius: radius)
                target = previousPlane
            case .transformed:
                continue
            }
            guard let fit = robustAffineFit(source: source, target: target, width: width, height: height) else { continue }
            guard fit.gain >= 0.30, fit.gain <= 2.8, abs(fit.offset) <= 96 else { continue }

            let strength = abs(log(max(0.001, fit.gain))) + abs(fit.offset) / 64 + Double(radius) * 0.12
            guard strength >= 0.10 else { continue }
            var explained = Set<Int>()
            var residuals: [Int: Double] = [:]
            var details: [Int: Double] = [:]
            var explainedArea = 0
            var weightedResidual = 0.0
            var weightedTemporalDelta = 0.0
            let foreground = direction == .focusGained ? currentPlane : previousPlane
            let foregroundLowPass = boxBlur(foreground, width: width, height: height, radius: 1)
            for tile in tiles {
                let residual = tileResidual(
                    source: source,
                    target: target,
                    width: width,
                    rect: tile.rect,
                    gain: fit.gain,
                    offset: fit.offset
                )
                residuals[tile.index] = residual
                details[tile.index] = tileResidual(
                    source: foregroundLowPass,
                    target: foreground,
                    width: width,
                    rect: tile.rect,
                    gain: 1,
                    offset: 0
                )
                guard residual <= configuration.backdropResidualThreshold else { continue }
                explained.insert(tile.index)
                explainedArea += tile.rect.area
                weightedResidual += residual * Double(tile.rect.area)
                weightedTemporalDelta += tile.meanDelta * Double(tile.rect.area)
            }
            let explainedChange = Double(explained.count) / Double(tiles.count)
            guard explainedChange >= configuration.backdropMinimumExplainedChange,
                  let span = tileSpan(indices: explained, tiles: tiles, width: width, height: height),
                  span.width >= 0.65, span.height >= 0.65
            else { continue }
            let coverage = Double(explainedArea) / Double(max(1, width * height))
            let residual = weightedResidual / Double(max(1, explainedArea))
            let confidence = min(0.98, 0.45 + explainedChange * 0.45 + min(0.08, strength * 0.08))
            let detection = BackdropDetection(
                coveredFraction: coverage,
                explainedChangeFraction: explainedChange,
                blurRadius: radius,
                gain: fit.gain,
                offset: fit.offset,
                residual: residual,
                confidence: confidence,
                direction: direction,
                temporalMeanDelta: weightedTemporalDelta / Double(max(1, explainedArea)),
                tileIndices: explained,
                tileResiduals: residuals,
                tileDetails: details
            )
            let score = explainedChange * 2 + coverage - residual / 80 - Double(radius) * 0.005
            if best == nil || score > best!.score { best = (score, detection) }
        }
    }
    return best?.detection
}

private func luminancePlane(_ pixels: [UInt8], width: Int, height: Int) -> [Double] {
    (0..<(width * height)).map { luminance(pixels, at: $0 * 4) }
}

private func boxBlur(_ values: [Double], width: Int, height: Int, radius: Int) -> [Double] {
    guard radius > 0 else { return values }
    let integralWidth = width + 1
    var integral = [Double](repeating: 0, count: (width + 1) * (height + 1))
    for y in 0..<height {
        var row = 0.0
        for x in 0..<width {
            row += values[y * width + x]
            integral[(y + 1) * integralWidth + x + 1] = integral[y * integralWidth + x + 1] + row
        }
    }
    var result = [Double](repeating: 0, count: values.count)
    for y in 0..<height {
        let y0 = max(0, y - radius), y1 = min(height, y + radius + 1)
        for x in 0..<width {
            let x0 = max(0, x - radius), x1 = min(width, x + radius + 1)
            let sum = integral[y1 * integralWidth + x1]
                - integral[y0 * integralWidth + x1]
                - integral[y1 * integralWidth + x0]
                + integral[y0 * integralWidth + x0]
            result[y * width + x] = sum / Double((x1 - x0) * (y1 - y0))
        }
    }
    return result
}

private func robustAffineFit(
    source: [Double],
    target: [Double],
    width: Int,
    height: Int
) -> AffineFit? {
    var samples: [Int] = []
    for y in Swift.stride(from: 0, to: height, by: 4) {
        for x in Swift.stride(from: 0, to: width, by: 4) {
            samples.append(y * width + x)
        }
    }
    func fit(_ indices: [Int]) -> AffineFit? {
        guard indices.count >= 20 else { return nil }
        let sourceMean = indices.reduce(0.0) { $0 + source[$1] } / Double(indices.count)
        let targetMean = indices.reduce(0.0) { $0 + target[$1] } / Double(indices.count)
        var covariance = 0.0, variance = 0.0
        for index in indices {
            covariance += (source[index] - sourceMean) * (target[index] - targetMean)
            variance += (source[index] - sourceMean) * (source[index] - sourceMean)
        }
        guard variance > 1 else { return nil }
        let gain = covariance / variance
        let offset = targetMean - gain * sourceMean
        let residual = sqrt(indices.reduce(0.0) { partial, index in
            let delta = target[index] - (gain * source[index] + offset)
            return partial + delta * delta
        } / Double(indices.count))
        return AffineFit(gain: gain, offset: offset, residual: residual)
    }
    guard samples.count >= 40 else { return nil }

    // A flat foreground can be a large minority of the frame. Residual
    // trimming may incorrectly converge onto that foreground because it has
    // very low variance. Instead, evaluate deterministic two-point hypotheses
    // and retain the model supported by the most samples across the frame.
    var hypotheses: [AffineFit] = []
    if let ordinary = fit(samples) { hypotheses.append(ordinary) }
    var state: UInt64 = 0x9E3779B97F4A7C15
    let hypothesisCount = min(180, samples.count)
    for _ in 0..<hypothesisCount {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let first = samples[Int(state % UInt64(samples.count))]
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let second = samples[Int(state % UInt64(samples.count))]
        let sourceDelta = source[second] - source[first]
        guard abs(sourceDelta) >= 8 else { continue }
        let gain = (target[second] - target[first]) / sourceDelta
        guard gain >= 0.20, gain <= 3.2 else { continue }
        hypotheses.append(AffineFit(
            gain: gain,
            offset: target[first] - gain * source[first],
            residual: .infinity
        ))
    }

    var bestIndices: [Int] = []
    var bestMeanResidual = Double.infinity
    for hypothesis in hypotheses {
        var inliers: [Int] = []
        var residual = 0.0
        for index in samples {
            let error = abs(target[index] - (hypothesis.gain * source[index] + hypothesis.offset))
            if error <= 10 {
                inliers.append(index)
                residual += error
            }
        }
        let meanResidual = residual / Double(max(1, inliers.count))
        if inliers.count > bestIndices.count || (inliers.count == bestIndices.count && meanResidual < bestMeanResidual) {
            bestIndices = inliers
            bestMeanResidual = meanResidual
        }
    }
    guard bestIndices.count >= max(20, samples.count / 5),
          var refined = fit(bestIndices)
    else { return nil }
    for _ in 0..<2 {
        let threshold = min(16, max(5, refined.residual * 2.5 + 2))
        let inliers = samples.filter {
            abs(target[$0] - (refined.gain * source[$0] + refined.offset)) <= threshold
        }
        guard let next = fit(inliers) else { break }
        refined = next
    }
    return refined
}

private func tileResidual(
    source: [Double],
    target: [Double],
    width: Int,
    rect: PixelRect,
    gain: Double,
    offset: Double
) -> Double {
    var squared = 0.0, samples = 0
    for y in Swift.stride(from: rect.minY, to: rect.maxY, by: 2) {
        for x in Swift.stride(from: rect.minX, to: rect.maxX, by: 2) {
            let index = y * width + x
            let delta = target[index] - (gain * source[index] + offset)
            squared += delta * delta
            samples += 1
        }
    }
    return sqrt(squared / Double(max(1, samples)))
}

private func tileSpan(
    indices: Set<Int>,
    tiles: [ExplainedTile],
    width: Int,
    height: Int
) -> CGRect? {
    let selected = tiles.filter { indices.contains($0.index) }
    guard !selected.isEmpty else { return nil }
    let minX = selected.map(\.rect.minX).min() ?? 0
    let minY = selected.map(\.rect.minY).min() ?? 0
    let maxX = selected.map(\.rect.maxX).max() ?? minX
    let maxY = selected.map(\.rect.maxY).max() ?? minY
    return CGRect(
        x: Double(minX) / Double(width),
        y: Double(minY) / Double(height),
        width: Double(maxX - minX) / Double(width),
        height: Double(maxY - minY) / Double(height)
    )
}

private func makeBackdropContext(
    _ detection: BackdropDetection,
    structural: [StructuralMotionComponent],
    columns: Int,
    width: Int,
    height: Int,
    tileSize: Int
) -> BackdropMotionContext {
    let strongResidual = 18.0
    let active = Set(structural.flatMap(\.tileIndices).filter {
        detection.tileResiduals[$0, default: 0] >= strongResidual
            && detection.tileDetails[$0, default: 0] >= 2.5
    })
    // Connect nearby sharp foreground features (text, borders, controls)
    // without admitting the blurred residuals between them.
    var expanded = active
    for index in active {
        let x = index % columns, y = index / columns
        for offsetY in -1...1 {
            for offsetX in -1...1 {
                let nx = x + offsetX, ny = y + offsetY
                guard nx >= 0, ny >= 0 else { continue }
                expanded.insert(ny * columns + nx)
            }
        }
    }
    let regions = indexComponents(expanded, columns: columns)
    let focusRegion = regions.filter { $0.count >= 4 }.max { lhs, rhs in
        let lhsBounds = indexBounds(lhs, columns: columns, width: width, height: height, tileSize: tileSize)
        let rhsBounds = indexBounds(rhs, columns: columns, width: width, height: height, tileSize: tileSize)
        let lhsDensity = Double(lhs.count * tileSize * tileSize) / Double(max(1, Int(lhsBounds.width * CGFloat(width) * lhsBounds.height * CGFloat(height))))
        let rhsDensity = Double(rhs.count * tileSize * tileSize) / Double(max(1, Int(rhsBounds.width * CGFloat(width) * rhsBounds.height * CGFloat(height))))
        return Double(lhs.count) * (0.5 + lhsDensity) < Double(rhs.count) * (0.5 + rhsDensity)
    }
    let focus = focusRegion.map {
        indexBounds($0, columns: columns, width: width, height: height, tileSize: tileSize)
            .insetBy(dx: -CGFloat(tileSize) / CGFloat(width), dy: -CGFloat(tileSize) / CGFloat(height))
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    // A multi-pixel blur is temporally asymmetric and identifies which frame
    // contains the foreground. Radius-zero/one affine fits are nearly
    // symmetric. For an actual dim overlay the forward backdrop delta is the
    // stable temporal cue: the backdrop darkens on focus gain and brightens on
    // release. Structural polarity is only a fallback for neutral transforms,
    // because a plain foreground may legitimately erase textured old content.
    let direction: BackdropDirection = if detection.blurRadius >= 2 {
        detection.direction
    } else if detection.temporalMeanDelta <= -1.5 {
        .focusGained
    } else if detection.temporalMeanDelta >= 1.5 {
        .focusReleased
    } else if let focus {
        backdropDirection(from: structural, inside: focus) ?? detection.direction
    } else {
        detection.direction
    }
    return BackdropMotionContext(
        coveredFraction: detection.coveredFraction,
        explainedChangeFraction: detection.explainedChangeFraction,
        blurRadius: detection.blurRadius,
        gain: detection.gain,
        offset: detection.offset,
        residual: detection.residual,
        confidence: detection.confidence,
        direction: direction,
        focusedBounds: focus,
        tileIndices: detection.tileIndices.sorted()
    )
}

private func backdropDirection(
    from structural: [StructuralMotionComponent],
    inside focus: CGRect
) -> BackdropDirection? {
    var appearance = 0.0, disappearance = 0.0
    for component in structural {
        let intersection = component.normalizedBounds.intersection(focus)
        guard !intersection.isNull else { continue }
        let componentArea = component.normalizedBounds.width * component.normalizedBounds.height
        let overlap = componentArea > 0
            ? Double(intersection.width * intersection.height / componentArea)
            : 0
        guard overlap >= 0.25 else { continue }
        let weight = component.changedFraction * overlap
        switch component.polarity {
        case .appear: appearance += weight
        case .vanish: disappearance += weight
        case .replace: break
        }
    }
    if appearance > disappearance * 1.15, appearance > 0.002 { return .focusGained }
    if disappearance > appearance * 1.15, disappearance > 0.002 { return .focusReleased }
    return nil
}

private func indexComponents(_ indices: Set<Int>, columns: Int) -> [[Int]] {
    var remaining = indices
    var result: [[Int]] = []
    while let seed = remaining.first {
        remaining.remove(seed)
        var queue = [seed], cursor = 0, component: [Int] = []
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            component.append(index)
            let x = index % columns, y = index / columns
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 {
                let neighbor = ny * columns + nx
                if remaining.remove(neighbor) != nil { queue.append(neighbor) }
            }
        }
        result.append(component)
    }
    return result
}

private func indexBounds(
    _ indices: [Int],
    columns: Int,
    width: Int,
    height: Int,
    tileSize: Int
) -> CGRect {
    let xs = indices.map { $0 % columns }, ys = indices.map { $0 / columns }
    let minX = (xs.min() ?? 0) * tileSize
    let minY = (ys.min() ?? 0) * tileSize
    let maxX = min(width, ((xs.max() ?? 0) + 1) * tileSize)
    let maxY = min(height, ((ys.max() ?? 0) + 1) * tileSize)
    return CGRect(
        x: CGFloat(minX) / CGFloat(width),
        y: CGFloat(minY) / CGFloat(height),
        width: CGFloat(maxX - minX) / CGFloat(width),
        height: CGFloat(maxY - minY) / CGFloat(height)
    )
}

/// Correlation is undefined for flat tiles. Once textured tiles establish a
/// frame-wide affine luminance model, reuse that same model to explain flat
/// regions instead of calling every solid background tile new structure.
private func expandPhotometricExplanation(
    tiles: [ExplainedTile],
    previous: [UInt8],
    current: [UInt8],
    width: Int,
    height: Int,
    configuration: MotionFieldConfiguration
) -> [ExplainedTile] {
    let seeds = tiles.filter { if case .photometric = $0.explanation { true } else { false } }
    guard let model = makePhotometricContext(
        tiles: seeds,
        totalPixels: width * height,
        tileSize: configuration.tileSize
    ), model.coveredFraction >= configuration.photometricSeedCoverage else { return tiles }

    return tiles.map { tile in
        if case .photometric = tile.explanation { return tile }
        if case .backdrop = tile.explanation { return tile }
        var squared = 0.0
        var samples = 0
        for y in Swift.stride(from: tile.rect.minY, to: tile.rect.maxY, by: 2) {
            for x in Swift.stride(from: tile.rect.minX, to: tile.rect.maxX, by: 2) {
                let offset = (y * width + x) * 4
                let predicted = model.meanGain * luminance(previous, at: offset) + model.meanOffset
                let residual = luminance(current, at: offset) - predicted
                squared += residual * residual
                samples += 1
            }
        }
        let residual = sqrt(squared / Double(max(1, samples)))
        guard residual <= configuration.photometricExpansionResidualThreshold else { return tile }
        return tile.replacingExplanation(.photometric(
            gain: model.meanGain,
            offset: model.meanOffset,
            residual: residual
        ))
    }
}

private func classifyResidualShifts(
    tiles: [ExplainedTile],
    previous: [UInt8],
    current: [UInt8],
    width: Int,
    height: Int,
    tileSize: Int,
    configuration: MotionFieldConfiguration
) -> [ExplainedTile] {
    tiles.map { tile in
        guard tile.explanation == .structural else { return tile }
        let context = tile.rect.expanded(by: tileSize, width: width, height: height)
        guard let match = bestShift(
            previous: previous,
            current: current,
            width: width,
            height: height,
            rect: context,
            maximumShift: configuration.maximumShift,
            step: configuration.shiftStep
        ), match.residual <= configuration.shiftResidualThreshold,
           match.residual <= match.stationaryResidual * configuration.shiftImprovementRatio
        else { return tile }
        return tile.replacingExplanation(.shift(
            dx: match.dx,
            dy: match.dy,
            confidence: match.confidence
        ))
    }
}

/// A single tile can often find an accidental match elsewhere in a repeated
/// interface. Translation is therefore a field property: retain it only when
/// a connected neighborhood supports the same vector. Uncorroborated matches
/// remain visible as structural change rather than disappearing as motion.
private func rejectIncoherentShifts(
    tiles: [ExplainedTile],
    columns: Int,
    width: Int,
    height: Int,
    minimumTiles: Int
) -> [ExplainedTile] {
    var buckets: [ShiftBucket: [ExplainedTile]] = [:]
    for tile in tiles {
        guard case let .shift(dx, dy, _) = tile.explanation else { continue }
        buckets[ShiftBucket(dx: dx, dy: dy), default: []].append(tile)
    }
    var retained = Set<Int>()
    for (bucket, bucketTiles) in buckets {
        for component in connectedComponents(
            tiles: bucketTiles,
            columns: columns,
            width: width,
            height: height
        ) where component.count >= minimumTiles {
            let minX = component.map(\.rect.minX).min() ?? 0
            let minY = component.map(\.rect.minY).min() ?? 0
            let maxX = component.map(\.rect.maxX).max() ?? minX
            let maxY = component.map(\.rect.maxY).max() ?? minY
            let tileWidth = component.first?.rect.width ?? 1
            let tileHeight = component.first?.rect.height ?? 1
            guard maxX - minX >= max(tileWidth * 2, abs(bucket.dx)),
                  maxY - minY >= max(tileHeight * 2, abs(bucket.dy))
            else { continue }
            retained.formUnion(component.map(\.index))
        }
    }
    return tiles.map { tile in
        guard case .shift = tile.explanation, !retained.contains(tile.index) else { return tile }
        return tile.replacingExplanation(.structural)
    }
}

private struct ShiftMatch {
    let dx: Int
    let dy: Int
    let residual: Double
    let stationaryResidual: Double
    let confidence: Double
}

private struct DominantShift {
    let dx: Int
    let dy: Int
    let confidence: Double
    let isViewportWide: Bool
}

/// A coherent translation is estimated before residual structure is grouped.
/// This avoids turning the newly exposed L-shaped edge of a scroll into a
/// screen-sized structural bounding box. Interior tiles are never claimed by
/// the shift solely because it is dominant: they still have to fit the model.
private func reconcileCoherentShift(
    tiles: [ExplainedTile],
    previous: [UInt8],
    current: [UInt8],
    width: Int,
    height: Int,
    configuration: MotionFieldConfiguration
) -> [ExplainedTile] {
    guard let dominant = dominantShift(
        in: tiles,
        width: width,
        height: height,
        minimumCoverage: configuration.coherentShiftMinimumCoverage,
        minimumViewportSpan: configuration.viewportShiftMinimumSpan
    ) else { return tiles }

    return tiles.map { tile in
        if case let .shift(dx, dy, _) = tile.explanation,
           dx == dominant.dx, dy == dominant.dy {
            return tile
        }

        if let match = fixedShift(
            previous: previous,
            current: current,
            width: width,
            height: height,
            rect: tile.rect,
            dx: dominant.dx,
            dy: dominant.dy
        ) {
            guard match.residual <= configuration.shiftResidualThreshold,
                  match.residual <= match.stationaryResidual * configuration.shiftImprovementRatio
            else { return tile }
            return tile.replacingExplanation(.shift(
                dx: dominant.dx,
                dy: dominant.dy,
                confidence: max(dominant.confidence, match.confidence)
            ))
        }

        // A viewport translation has no source pixels for its entering edge.
        // Those tiles are part of the translation model, not an independent
        // screen-sized subject. Local translations do not receive this rule.
        guard dominant.isViewportWide,
              liesInExposedEdge(
                tile.rect,
                width: width,
                height: height,
                dx: dominant.dx,
                dy: dominant.dy
              )
        else { return tile }
        return tile.replacingExplanation(.shift(
            dx: dominant.dx,
            dy: dominant.dy,
            confidence: dominant.confidence * 0.75
        ))
    }
}

private func dominantShift(
    in tiles: [ExplainedTile],
    width: Int,
    height: Int,
    minimumCoverage: Double,
    minimumViewportSpan: Double
) -> DominantShift? {
    var buckets: [ShiftBucket: [ExplainedTile]] = [:]
    for tile in tiles {
        guard case let .shift(dx, dy, _) = tile.explanation else { continue }
        buckets[ShiftBucket(dx: dx, dy: dy), default: []].append(tile)
    }
    guard let winner = buckets.max(by: { lhs, rhs in
        lhs.value.reduce(0) { $0 + $1.rect.area } < rhs.value.reduce(0) { $0 + $1.rect.area }
    }) else { return nil }

    let coveredArea = winner.value.reduce(0) { $0 + $1.rect.area }
    let coverage = Double(coveredArea) / Double(max(1, width * height))
    guard coverage >= minimumCoverage else { return nil }
    let minX = winner.value.map(\.rect.minX).min() ?? 0
    let minY = winner.value.map(\.rect.minY).min() ?? 0
    let maxX = winner.value.map(\.rect.maxX).max() ?? minX
    let maxY = winner.value.map(\.rect.maxY).max() ?? minY
    let spanX = Double(maxX - minX) / Double(width)
    let spanY = Double(maxY - minY) / Double(height)
    let confidence = winner.value.compactMap { tile -> Double? in
        if case let .shift(_, _, confidence) = tile.explanation { confidence } else { nil }
    }.reduce(0, +) / Double(max(1, winner.value.count))
    return DominantShift(
        dx: winner.key.dx,
        dy: winner.key.dy,
        confidence: confidence,
        isViewportWide: spanX >= minimumViewportSpan && spanY >= minimumViewportSpan
    )
}

private func fixedShift(
    previous: [UInt8],
    current: [UInt8],
    width: Int,
    height: Int,
    rect: PixelRect,
    dx: Int,
    dy: Int
) -> ShiftMatch? {
    guard rect.minX + dx >= 0,
          rect.minY + dy >= 0,
          rect.maxX + dx <= width,
          rect.maxY + dy <= height
    else { return nil }

    func residual(offsetX: Int, offsetY: Int) -> Double {
        var squared = 0.0
        var samples = 0
        for y in Swift.stride(from: rect.minY, to: rect.maxY, by: 2) {
            for x in Swift.stride(from: rect.minX, to: rect.maxX, by: 2) {
                let currentOffset = (y * width + x) * 4
                let previousOffset = ((y + offsetY) * width + x + offsetX) * 4
                let delta = luminance(current, at: currentOffset) - luminance(previous, at: previousOffset)
                squared += delta * delta
                samples += 1
            }
        }
        return sqrt(squared / Double(max(1, samples)))
    }

    let stationary = residual(offsetX: 0, offsetY: 0)
    let shifted = residual(offsetX: dx, offsetY: dy)
    return ShiftMatch(
        dx: dx,
        dy: dy,
        residual: shifted,
        stationaryResidual: stationary,
        confidence: max(0, 1 - shifted / max(0.001, stationary))
    )
}

private func liesInExposedEdge(
    _ rect: PixelRect,
    width: Int,
    height: Int,
    dx: Int,
    dy: Int
) -> Bool {
    let horizontal = dx > 0
        ? rect.maxX > width - dx
        : dx < 0 ? rect.minX < -dx : false
    let vertical = dy > 0
        ? rect.maxY > height - dy
        : dy < 0 ? rect.minY < -dy : false
    return horizontal || vertical
}

private func bestShift(
    previous: [UInt8],
    current: [UInt8],
    width: Int,
    height: Int,
    rect: PixelRect,
    maximumShift: Int,
    step: Int
) -> ShiftMatch? {
    func score(dx: Int, dy: Int) -> Double? {
        guard rect.minX + dx >= 0,
              rect.minY + dy >= 0,
              rect.maxX + dx <= width,
              rect.maxY + dy <= height
        else { return nil }
        var squared = 0.0
        var samples = 0
        for y in stride(from: rect.minY, to: rect.maxY, by: 2) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 2) {
                let currentOffset = (y * width + x) * 4
                let previousOffset = ((y + dy) * width + x + dx) * 4
                let delta = luminance(current, at: currentOffset) - luminance(previous, at: previousOffset)
                squared += delta * delta
                samples += 1
            }
        }
        return samples > 0 ? sqrt(squared / Double(samples)) : nil
    }

    guard let stationary = score(dx: 0, dy: 0), stationary >= 3 else { return nil }
    var bestResidual = stationary
    var bestDX = 0
    var bestDY = 0
    let searchStep = max(1, step)
    for dy in Swift.stride(from: -maximumShift, through: maximumShift, by: searchStep) {
        for dx in Swift.stride(from: -maximumShift, through: maximumShift, by: searchStep) {
            if dx == 0, dy == 0 { continue }
            guard let candidate = score(dx: dx, dy: dy), candidate < bestResidual else { continue }
            bestResidual = candidate
            bestDX = dx
            bestDY = dy
        }
    }
    guard bestDX != 0 || bestDY != 0 else { return nil }
    let improvement = max(0, 1 - bestResidual / stationary)
    return ShiftMatch(
        dx: bestDX,
        dy: bestDY,
        residual: bestResidual,
        stationaryResidual: stationary,
        confidence: improvement
    )
}

private func makePhotometricContext(
    tiles: [ExplainedTile],
    totalPixels: Int,
    tileSize: Int
) -> PhotometricMotionContext? {
    guard !tiles.isEmpty else { return nil }
    var coveredPixels = 0
    var weightedGain = 0.0
    var weightedOffset = 0.0
    var weightedResidual = 0.0
    var weightedDelta = 0.0
    var weight = 0.0
    var indices: [Int] = []
    for tile in tiles {
        guard case let .photometric(gain, offset, residual) = tile.explanation else { continue }
        let pixels = tile.rect.area
        let tileWeight = Double(pixels)
        coveredPixels += pixels
        weight += tileWeight
        weightedGain += gain * tileWeight
        weightedOffset += offset * tileWeight
        weightedResidual += residual * tileWeight
        weightedDelta += tile.meanDelta * tileWeight
        indices.append(tile.index)
    }
    guard weight > 0 else { return nil }
    let meanDelta = weightedDelta / weight
    let direction: PhotometricDirection
    if meanDelta < -2 { direction = .dimming }
    else if meanDelta > 2 { direction = .undimming }
    else { direction = .mixed }
    return PhotometricMotionContext(
        coveredFraction: Double(coveredPixels) / Double(max(1, totalPixels)),
        meanGain: weightedGain / weight,
        meanOffset: weightedOffset / weight,
        meanResidual: weightedResidual / weight,
        direction: direction,
        tileIndices: indices.sorted()
    )
}

private func connectedComponents(
    tiles: [ExplainedTile],
    columns: Int,
    width _: Int,
    height _: Int
) -> [[ExplainedTile]] {
    var remaining = Dictionary(uniqueKeysWithValues: tiles.map { ($0.index, $0) })
    var result: [[ExplainedTile]] = []
    while let seed = remaining.keys.min() {
        var queue = [seed]
        var cursor = 0
        var component: [ExplainedTile] = []
        guard let seedTile = remaining.removeValue(forKey: seed) else { continue }
        var queuedTiles = [seed: seedTile]
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            guard let tile = queuedTiles.removeValue(forKey: index) else { continue }
            component.append(tile)
            let x = index % columns
            let y = index / columns
            for offsetY in -1...1 {
                for offsetX in -1...1 where offsetX != 0 || offsetY != 0 {
                    let nx = x + offsetX
                    let ny = y + offsetY
                    guard nx >= 0, ny >= 0 else { continue }
                    let neighbor = ny * columns + nx
                    if let neighborTile = remaining.removeValue(forKey: neighbor) {
                        queuedTiles[neighbor] = neighborTile
                        queue.append(neighbor)
                    }
                }
            }
        }
        if !component.isEmpty { result.append(component) }
    }
    return result
}

private func makeStructuralComponent(
    _ tiles: [ExplainedTile],
    width: Int,
    height: Int
) -> StructuralMotionComponent {
    let minX = tiles.map(\.rect.minX).min() ?? 0
    let minY = tiles.map(\.rect.minY).min() ?? 0
    let maxX = tiles.map(\.rect.maxX).max() ?? minX
    let maxY = tiles.map(\.rect.maxY).max() ?? minY
    let boxArea = max(1, (maxX - minX) * (maxY - minY))
    let coveredArea = tiles.reduce(0) { $0 + $1.rect.area }
    let changedPixels = tiles.reduce(0) { $0 + $1.changedPixels }
    let energyWeight = Double(max(1, coveredArea))
    let energy = tiles.reduce(0.0) { $0 + $1.energy * Double($1.rect.area) } / energyWeight
    let beforeDetail = tiles.reduce(0.0) { $0 + $1.beforeDetail * Double($1.rect.area) } / energyWeight
    let afterDetail = tiles.reduce(0.0) { $0 + $1.afterDetail * Double($1.rect.area) } / energyWeight
    let polarity: StructuralMotionPolarity
    if afterDetail > beforeDetail * 1.25 + 2 { polarity = .appear }
    else if beforeDetail > afterDetail * 1.25 + 2 { polarity = .vanish }
    else { polarity = .replace }
    return StructuralMotionComponent(
        normalizedBounds: CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX) / CGFloat(width),
            height: CGFloat(maxY - minY) / CGFloat(height)
        ),
        changedFraction: Double(changedPixels) / Double(max(1, width * height)),
        density: Double(coveredArea) / Double(boxArea),
        energy: min(1, energy / 80),
        polarity: polarity,
        tileIndices: tiles.map(\.index).sorted()
    )
}

private func makeShiftComponents(
    tiles: [ExplainedTile],
    columns: Int,
    width: Int,
    height: Int
) -> [MotionShiftComponent] {
    let shifted = tiles.filter { if case .shift = $0.explanation { true } else { false } }
    var buckets: [ShiftBucket: [ExplainedTile]] = [:]
    for tile in shifted {
        guard case let .shift(dx, dy, _) = tile.explanation else { continue }
        buckets[ShiftBucket(dx: dx, dy: dy), default: []].append(tile)
    }
    var result: [MotionShiftComponent] = []
    for (bucket, bucketTiles) in buckets {
        for component in connectedComponents(
            tiles: bucketTiles,
            columns: columns,
            width: width,
            height: height
        ) {
            let minX = component.map(\.rect.minX).min() ?? 0
            let minY = component.map(\.rect.minY).min() ?? 0
            let maxX = component.map(\.rect.maxX).max() ?? minX
            let maxY = component.map(\.rect.maxY).max() ?? minY
            let boxArea = max(1, (maxX - minX) * (maxY - minY))
            let coveredArea = component.reduce(0) { $0 + $1.rect.area }
            let confidence = component.compactMap { tile -> Double? in
                if case let .shift(_, _, confidence) = tile.explanation { confidence } else { nil }
            }.reduce(0, +) / Double(max(1, component.count))
            result.append(MotionShiftComponent(
                normalizedBounds: CGRect(
                    x: CGFloat(minX) / CGFloat(width),
                    y: CGFloat(minY) / CGFloat(height),
                    width: CGFloat(maxX - minX) / CGFloat(width),
                    height: CGFloat(maxY - minY) / CGFloat(height)
                ),
                normalizedVector: CGVector(
                    dx: CGFloat(bucket.dx) / CGFloat(width),
                    dy: CGFloat(bucket.dy) / CGFloat(height)
                ),
                supportFraction: Double(coveredArea) / Double(max(1, width * height)),
                confidence: confidence,
                density: Double(coveredArea) / Double(boxArea),
                tileIndices: component.map(\.index).sorted()
            ))
        }
    }
    return result.sorted { lhs, rhs in
        if lhs.supportFraction != rhs.supportFraction { return lhs.supportFraction > rhs.supportFraction }
        if lhs.normalizedBounds.minY != rhs.normalizedBounds.minY { return lhs.normalizedBounds.minY < rhs.normalizedBounds.minY }
        return lhs.normalizedBounds.minX < rhs.normalizedBounds.minX
    }
}

private struct ShiftBucket: Hashable {
    let dx: Int
    let dy: Int
}
