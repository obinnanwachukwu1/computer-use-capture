const resolutionKinds = new Set([
  "bufferWidth", "bufferHeight", "contentRectWidth", "contentRectHeight",
  "contentRectUnavailable", "boundingRectWidth", "boundingRectHeight",
  "boundingRectUnavailable", "scaleFactor", "scaleFactorUnavailable",
  "contentScale", "contentScaleUnavailable", "effectivePixelsPerPointX",
  "effectivePixelsPerPointY"
]);

const placementKinds = new Set(["contentRectX", "contentRectY"]);

export function summarizeCaptureLedger(ledger) {
  const samples = Array.isArray(ledger?.samples) ? ledger.samples : [];
  const complete = samples.filter(sample => sample.status === "complete");
  const withGeometry = complete.filter(sample => sample.geometry);
  const withContentRect = withGeometry.filter(sample => sample.geometry.contentRect);
  const withBoundingRect = withGeometry.filter(sample => sample.geometry.boundingRect);
  const withScale = withGeometry.filter(sample => Number.isFinite(sample.geometry.contentScale)
    && Number.isFinite(sample.geometry.scaleFactor));
  const discontinuous = complete.filter(sample => sample.geometryDiscontinuities?.length);
  const effectiveX = finiteValues(withGeometry.map(sample => effectivePixelsPerPoint(
    sample.geometry, "width"
  )));
  const effectiveY = finiteValues(withGeometry.map(sample => effectivePixelsPerPoint(
    sample.geometry, "height"
  )));
  const contentWidths = finiteValues(withGeometry.map(sample => sample.geometry.contentRect?.width));
  const contentHeights = finiteValues(withGeometry.map(sample => sample.geometry.contentRect?.height));
  const contentScales = finiteValues(withGeometry.map(sample => sample.geometry.contentScale));
  const runs = discontinuityRuns(complete);

  return {
    ledgerVersion: ledger?.version,
    observability: complete.length > 0
      && withContentRect.length === complete.length
      && withBoundingRect.length === complete.length
      && withScale.length === complete.length
      ? "complete" : withGeometry.length > 0 ? "partial" : "unavailable",
    verdict: withGeometry.length === 0
      ? "unobservable"
      : discontinuous.length > 0 ? "discontinuous"
        : (withContentRect.length === complete.length
          && withBoundingRect.length === complete.length
          && withScale.length === complete.length) ? "stable" : "inconclusive",
    samples: {
      total: samples.length,
      complete: complete.length,
      geometryObserved: withGeometry.length,
      contentRectObserved: withContentRect.length,
      boundingRectObserved: withBoundingRect.length,
      scaleObserved: withScale.length,
      discontinuityFrames: discontinuous.length,
      resolutionDiscontinuityFrames: discontinuous.filter(hasKindIn(resolutionKinds)).length,
      placementDiscontinuityFrames: discontinuous.filter(hasKindIn(placementKinds)).length
    },
    contract: ledger?.geometryContract ?? null,
    baseline: ledger?.geometryBaseline ?? withGeometry[0]?.geometry ?? null,
    ranges: {
      contentWidth: range(contentWidths),
      contentHeight: range(contentHeights),
      contentScale: range(contentScales),
      effectivePixelsPerPointX: range(effectiveX),
      effectivePixelsPerPointY: range(effectiveY)
    },
    discontinuityRuns: runs
  };
}

export function discontinuityRuns(samples, maximumGap = 0.1) {
  const result = [];
  for (const sample of samples) {
    const kinds = [...new Set((sample.geometryDiscontinuities ?? []).map(item => item.kind))].sort();
    if (!kinds.length || !Number.isFinite(sample.sourceTime)) continue;
    const signature = kinds.join(",");
    const previous = result.at(-1);
    if (previous && previous.signature === signature && sample.sourceTime - previous.end <= maximumGap) {
      previous.end = sample.sourceTime;
      previous.frames += 1;
      continue;
    }
    result.push({
      start: sample.sourceTime,
      end: sample.sourceTime,
      frames: 1,
      kinds,
      signature
    });
  }
  return result.map(({ signature: _, ...run }) => run);
}

function hasKindIn(kinds) {
  return sample => sample.geometryDiscontinuities.some(item => kinds.has(item.kind));
}

function effectivePixelsPerPoint(geometry, dimension) {
  const content = geometry?.contentRect?.[dimension];
  const bounds = geometry?.boundingRect?.[dimension];
  return Number.isFinite(content) && Number.isFinite(bounds) && bounds > 0
    ? content / bounds : undefined;
}

function finiteValues(values) {
  return values.filter(Number.isFinite);
}

function range(values) {
  return values.length ? { min: Math.min(...values), max: Math.max(...values) } : null;
}
