import CoreGraphics
import Foundation

public enum MotionFocusTransition: String, Sendable, Equatable, Codable {
    case gained
    case held
    case updated
    case released
    case invalidated
    case reset
}

public enum MotionFocusIntent: Sendable, Equatable {
    case automatic
    case dismissal
}

/// Maintains the foreground layer established by a dim/blur transition across
/// later action-relative frame pairs. The tracker emits camera evidence, not
/// pointer evidence: factual pointer and Accessibility targets remain separate
/// and may expand the director decision beyond the active focus.
public struct MotionFocusTracker: Sendable {
    public private(set) var activeFocus: CGRect?
    public private(set) var lastTransition: MotionFocusTransition?

    public init(activeFocus: CGRect? = nil) {
        self.activeFocus = activeFocus
        self.lastTransition = nil
    }

    public mutating func observations(
        for field: MotionField,
        at time: Double,
        intent: MotionFocusIntent = .automatic,
        forceReset: Bool = false
    ) -> [VisualMotionObservation] {
        lastTransition = nil
        if intent == .dismissal {
            if let current = activeFocus {
                activeFocus = nil
                lastTransition = .released
                return [focusObservation(bounds: current, field: field, time: time, transition: .released)]
            }
            // A factual dismissal must never bootstrap a new foreground when
            // raw opening/closing polarity is visually ambiguous. Preserve
            // ordinary structural evidence, but do not enter focus state.
            return field.framingObservations(at: time)
        }
        if forceReset, activeFocus != nil {
            activeFocus = nil
            lastTransition = .reset
        } else if isFullFrameReplacement(field), activeFocus != nil {
            activeFocus = nil
            lastTransition = .invalidated
        }

        if let backdrop = field.backdrop {
            switch backdrop.direction {
            case .focusGained:
                if let focus = backdrop.focusedBounds {
                    activeFocus = focus
                    lastTransition = .gained
                }
            case .focusReleased:
                if let closingFocus = activeFocus {
                    activeFocus = nil
                    lastTransition = .released
                    return [focusObservation(bounds: closingFocus, field: field, time: time, transition: .released)]
                }
                // A release is impossible without an active foreground. Raw
                // pixel polarity is symmetric for many dim-only transitions,
                // so the first observed focused subject establishes state.
                if let focus = backdrop.focusedBounds {
                    activeFocus = focus
                    lastTransition = .gained
                }
            case .transformed:
                if activeFocus == nil, let focus = backdrop.focusedBounds {
                    activeFocus = focus
                    lastTransition = .gained
                }
            }
        }

        if let current = activeFocus {
            let updated = updatedFocus(current, from: field)
            activeFocus = updated
            if lastTransition == nil {
                lastTransition = updated == current ? .held : .updated
            }
            return [focusObservation(
                bounds: activeFocus ?? current,
                field: field,
                time: time,
                transition: lastTransition
            )]
        }
        return field.framingObservations(at: time)
    }

    public mutating func reset() {
        lastTransition = activeFocus == nil ? nil : .reset
        activeFocus = nil
    }

    private func focusObservation(
        bounds: CGRect,
        field: MotionField,
        time: Double,
        transition: MotionFocusTransition?
    ) -> VisualMotionObservation {
        let relevant = field.structural.filter {
            overlapRatio($0.normalizedBounds, bounds) >= 0.15
        }
        return VisualMotionObservation(
            time: time,
            normalizedBounds: bounds,
            changedFraction: max(0.002, relevant.reduce(0) { $0 + $1.changedFraction }),
            magnitude: max(0.55, relevant.map(\.energy).max() ?? 0),
            kind: .focus,
            focusTransition: transition
        )
    }

    private func updatedFocus(_ current: CGRect, from field: MotionField) -> CGRect {
        let currentArea = current.width * current.height
        guard currentArea > 0,
              let candidate = field.structural.filter({ component in
                  let area = component.normalizedBounds.width * component.normalizedBounds.height
                  return area >= currentArea * 0.50
                      && area <= currentArea * 4.00
                      && component.density >= 0.20
                      && overlapRatio(component.normalizedBounds, current) >= 0.45
                      && extendsBeyond(component.normalizedBounds, current, tolerance: 0.015)
              }).max(by: { $0.changedFraction < $1.changedFraction })
        else { return current }
        return candidate.normalizedBounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func isFullFrameReplacement(_ field: MotionField) -> Bool {
        guard field.backdrop == nil else { return false }
        return field.structural.contains { component in
            let area = component.normalizedBounds.width * component.normalizedBounds.height
            return area >= 0.78 && component.changedFraction >= 0.18 && component.density >= 0.35
        }
    }
}

private func extendsBeyond(_ candidate: CGRect, _ current: CGRect, tolerance: CGFloat) -> Bool {
    candidate.minX < current.minX - tolerance
        || candidate.minY < current.minY - tolerance
        || candidate.maxX > current.maxX + tolerance
        || candidate.maxY > current.maxY + tolerance
}

private func overlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let shared = lhs.intersection(rhs)
    guard !shared.isNull else { return 0 }
    let smaller = min(lhs.width * lhs.height, rhs.width * rhs.height)
    return smaller > 0 ? shared.width * shared.height / smaller : 0
}
