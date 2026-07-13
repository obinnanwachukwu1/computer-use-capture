export function mapEventCoordinates({
  event,
  screenshotSpace,
  captureWidth,
  captureHeight,
  observations = []
}) {
  const hasDirectPoint = event.action === "drag"
    ? [event.args?.from_x, event.args?.from_y, event.args?.to_x, event.args?.to_y].every(Number.isFinite)
    : [event.args?.x, event.args?.y].every(Number.isFinite);
  if (!hasDirectPoint) return event;
  const validation = validateCoordinateSpace({ screenshotSpace, captureWidth, captureHeight });
  const geometry = captureGeometryAt(event.timestamp, observations);
  if (!validation.valid || !geometry.stable || geometry.systemUIOccluded === true) {
    return {
      ...event,
      coordinateResolution: {
        provenance: "unresolved",
        confidence: 0,
        reason: !validation.valid ? validation.reason
          : geometry.systemUIOccluded === true ? "system-ui-frontmost"
            : "capture-window-geometry-changed",
        screenshot: screenshotSpace,
        captureGeometry: geometry
      }
    };
  }
  const confidence = screenshotSpace.confidence === "event_nearby" ? 0.99
    : screenshotSpace.confidence === "capture_nearby" ? 0.85 : 0.55;
  const mapped = event.action === "drag"
    ? {
        from: normalizePoint(event.args.from_x, event.args.from_y, screenshotSpace, captureWidth, captureHeight),
        to: normalizePoint(event.args.to_x, event.args.to_y, screenshotSpace, captureWidth, captureHeight)
      }
    : normalizePoint(event.args.x, event.args.y, screenshotSpace, captureWidth, captureHeight);
  return {
    ...event,
    coordinates: mapped,
    coordinateResolution: {
      provenance: "direct",
      confidence,
      screenshot: screenshotSpace,
      captureGeometry: geometry
    }
  };
}

export function validateCoordinateSpace({ screenshotSpace, captureWidth, captureHeight }) {
  if (![screenshotSpace?.width, screenshotSpace?.height, captureWidth, captureHeight].every(Number.isFinite)) {
    return { valid: false, reason: "screenshot-coordinate-space-unavailable" };
  }
  if (screenshotSpace.confidence === "stale") {
    return { valid: false, reason: "screenshot-coordinate-space-stale" };
  }
  const screenshotAspect = screenshotSpace.width / screenshotSpace.height;
  const captureAspect = captureWidth / captureHeight;
  const relativeError = Math.abs(screenshotAspect - captureAspect) / captureAspect;
  return relativeError <= 0.03
    ? { valid: true, relativeAspectError: relativeError }
    : { valid: false, reason: "screenshot-capture-aspect-mismatch", relativeAspectError: relativeError };
}

function captureGeometryAt(timestamp, observations) {
  const withBounds = observations.filter(observation => validBounds(observation.windowBounds));
  if (!withBounds.length) return { stable: true, evidence: "unavailable" };
  const baseline = withBounds[0].windowBounds;
  const time = Date.parse(timestamp);
  const nearestObservation = withBounds.toSorted((left, right) =>
    Math.abs(Date.parse(left.observedAt) - time) - Math.abs(Date.parse(right.observedAt) - time)
  )[0];
  const nearest = nearestObservation.windowBounds;
  const deltas = {
    x: nearest.x - baseline.x,
    y: nearest.y - baseline.y,
    width: nearest.width - baseline.width,
    height: nearest.height - baseline.height
  };
  return {
    stable: Object.values(deltas).every(delta => Math.abs(delta) <= 2),
    evidence: "macos-accessibility-window-bounds",
    baseline,
    current: nearest,
    deltas,
    targetIsFrontmost: nearestObservation.targetIsFrontmost,
    systemUIOccluded: nearestObservation.frontmostIsSystemSurface === true,
    frontmostBundleIdentifier: nearestObservation.frontmostBundleIdentifier
  };
}

function validBounds(bounds) {
  return [bounds?.x, bounds?.y, bounds?.width, bounds?.height].every(Number.isFinite);
}

function normalizePoint(x, y, screenshotSpace, captureWidth, captureHeight) {
  const xNorm = x / screenshotSpace.width;
  const yNorm = y / screenshotSpace.height;
  return { xNorm, yNorm, captureX: xNorm * captureWidth, captureY: yNorm * captureHeight };
}
