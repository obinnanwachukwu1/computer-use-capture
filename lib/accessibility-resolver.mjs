const INTERACTIVE_ROLES = new Set([
  "button", "popupbutton", "combobox", "checkbox", "radiobutton", "link",
  "slider", "textfield", "textarea", "editor", "tab", "menuitem"
]);

export function resolveAccessibilityTarget({
  event,
  observations,
  captureStartedAt,
  captureWidth,
  captureHeight
}) {
  const elementIndex = Number(event.args?.element_index);
  const needsElementTarget = Number.isInteger(elementIndex);
  const direct = event.coordinates != null;
  if (event.coordinateResolution?.provenance === "unresolved") {
    return {
      ...event,
      targetResolution: {
        provenance: "unresolved",
        confidence: 0,
        elementIndex: needsElementTarget ? elementIndex : undefined,
        reason: event.coordinateResolution.reason ?? "direct-coordinate-unresolved"
      }
    };
  }
  if (systemUIOccludedAt(event.timestamp, observations)) {
    return {
      ...event,
      targetResolution: {
        provenance: "unresolved",
        confidence: 0,
        elementIndex: needsElementTarget ? elementIndex : undefined,
        reason: "system-ui-frontmost"
      }
    };
  }
  if (!needsElementTarget && !["type_text", "set_value", "select_text"].includes(event.action)) {
    return direct ? withResolution(event, "direct", event.coordinateResolution?.confidence ?? 0.8) : event;
  }

  const eventMs = Date.parse(event.timestamp);
  const toolStartMs = Date.parse(event.timing?.toolCallStartedAt ?? event.timestamp);
  const toolEndMs = Date.parse(event.timing?.toolCallEndedAt ?? event.timestamp);
  const captureStartMs = Date.parse(captureStartedAt);
  const windowStart = Math.max(captureStartMs, toolStartMs - 1500);
  const windowEnd = toolEndMs + 750;
  const nearbyCandidates = observations.filter(observation => {
    const observedMs = Date.parse(observation.observedAt);
    return observation.frontmostIsSystemSurface !== true
      && observedMs >= windowStart && observedMs <= windowEnd;
  });
  // The watcher emits a new snapshot when the AX tree changes. A quiet page's
  // most recent snapshot is therefore current state, not stale telemetry. Keep
  // the last snapshot preceding the action alongside the short post-action
  // window so stable controls remain resolvable after long thinking gaps.
  const preActionCandidates = observations
    .filter(observation => {
      const observedMs = Date.parse(observation.observedAt);
      return observation.frontmostIsSystemSurface !== true
        && observedMs >= captureStartMs && observedMs <= toolStartMs;
    })
    .sort((left, right) => Date.parse(right.observedAt) - Date.parse(left.observedAt));
  const latestPreAction = preActionCandidates[0];
  const latestCompletePreAction = preActionCandidates.find(observation => observation.treeComplete !== false);
  const candidates = [...new Set([
    latestPreAction,
    latestCompletePreAction,
    ...nearbyCandidates
  ].filter(Boolean))];

  const target = event.accessibilityTarget;
  let match = findIdentityMatch(candidates, target, eventMs);
  // Focus is useful corroboration only when Computer Use supplied the identity
  // of the element it acted on. A coordinate-less click must never inherit an
  // unrelated control merely because that control happened to retain focus.
  if (!match && target) match = findFocusedMatch(candidates, target, toolStartMs, toolEndMs);
  if (!match && needsElementTarget) {
    match = findStructuralMatch(candidates, target, event.accessibilityContext, eventMs);
  }
  if (!match && ["type_text", "set_value", "select_text"].includes(event.action)) {
    match = findFocusedMatch(candidates, undefined, toolStartMs, toolEndMs);
  }

  if (!match) {
    return direct
      ? withResolution(event, "direct", event.coordinateResolution?.confidence ?? 0.8)
      : {
          ...event,
          targetResolution: {
            provenance: "unresolved",
            confidence: 0,
            elementIndex: needsElementTarget ? elementIndex : undefined,
            reason: target ? "native-geometry-not-matched" : "computer-use-identity-unavailable"
          }
        };
  }

  const normalized = normalizeBounds(match.element.bounds, match.observation.windowBounds);
  if (!normalized || normalized.widthNorm * normalized.heightNorm > 0.65) {
    return direct
      ? withResolution(event, "direct", event.coordinateResolution?.confidence ?? 0.8)
      : {
          ...event,
          targetResolution: {
            provenance: "unresolved",
            confidence: 0,
            elementIndex: needsElementTarget ? elementIndex : undefined,
            reason: "matched-geometry-invalid"
          }
        };
  }

  const point = {
    xNorm: normalized.xNorm + normalized.widthNorm / 2,
    yNorm: normalized.yNorm + normalized.heightNorm / 2,
    captureX: (normalized.xNorm + normalized.widthNorm / 2) * captureWidth,
    captureY: (normalized.yNorm + normalized.heightNorm / 2) * captureHeight
  };
  const viewportRelocation = detectViewportRelocation({
    target,
    preActionCandidates,
    match,
    eventMs,
    toolStartMs
  });
  return {
    ...event,
    coordinates: event.coordinates ?? point,
    semanticTarget: {
      source: "macos-accessibility",
      confidence: match.provenance,
      observedAt: match.observation.observedAt,
      elementIndex: needsElementTarget ? elementIndex : undefined,
      nativeElementIndex: match.element.index,
      role: match.element.role,
      title: match.element.title ?? match.element.description,
      bounds: normalized,
      ...(viewportRelocation ? { viewportRelocation } : {})
    },
    targetResolution: {
      provenance: direct ? "direct" : match.provenance,
      confidence: direct ? (event.coordinateResolution?.confidence ?? 0.8) : match.confidence,
      observedAt: match.observation.observedAt,
      elementIndex: needsElementTarget ? elementIndex : undefined,
      nativeElementIndex: match.element.index
    }
  };
}

function detectViewportRelocation({ target, preActionCandidates, match, eventMs, toolStartMs }) {
  if (!target || Date.parse(match.observation.observedAt) < toolStartMs) return undefined;
  const before = findIdentityGeometryMatch(preActionCandidates, target, eventMs);
  if (!before || Date.parse(before.observation.observedAt) >= Date.parse(match.observation.observedAt)) return undefined;
  const from = normalizeBounds(before.element.bounds, before.observation.windowBounds);
  const to = normalizeBounds(match.element.bounds, match.observation.windowBounds);
  if (!from || !to) return undefined;
  const fromVisibleFraction = visibleFraction(from);
  const toVisibleFraction = visibleFraction(to);
  const displacementNorm = Math.hypot(
    from.xNorm + from.widthNorm / 2 - (to.xNorm + to.widthNorm / 2),
    from.yNorm + from.heightNorm / 2 - (to.yNorm + to.heightNorm / 2)
  );
  // This is deliberately narrower than generic layout motion. A shot boundary
  // is factual only when the same semantic target was outside the captured
  // viewport before Computer Use acted and was brought clearly into view by
  // that action. Ordinary reflow and nearby control movement remain eligible
  // for continuous shot grouping.
  if (fromVisibleFraction >= 0.5 || toVisibleFraction < 0.75 || displacementNorm < 0.12) return undefined;
  return {
    kind: "target-entered-viewport",
    fromBounds: from,
    toBounds: to,
    fromVisibleFraction,
    toVisibleFraction,
    displacementNorm,
    postActionOffsetMs: Math.max(0, Date.parse(match.observation.observedAt) - eventMs),
    observedBeforeAt: before.observation.observedAt,
    observedAfterAt: match.observation.observedAt
  };
}

function findIdentityGeometryMatch(observations, target, eventMs) {
  const matches = [];
  for (const observation of observations) {
    for (const element of observation.elements ?? []) {
      const score = identityScore(target, element);
      if (score < 5 || (observation.treeComplete === false && score < 10)) continue;
      const normalized = normalizeBounds(element.bounds, observation.windowBounds);
      if (!normalized || normalized.widthNorm * normalized.heightNorm > 0.65) continue;
      matches.push({
        observation,
        element,
        rank: score * 1000 - Math.abs(Date.parse(observation.observedAt) - eventMs) - walkPenalty(observation)
      });
    }
  }
  return matches.sort((left, right) => right.rank - left.rank)[0];
}

function visibleFraction(bounds) {
  const x0 = Math.max(0, bounds.xNorm);
  const y0 = Math.max(0, bounds.yNorm);
  const x1 = Math.min(1, bounds.xNorm + bounds.widthNorm);
  const y1 = Math.min(1, bounds.yNorm + bounds.heightNorm);
  const visibleArea = Math.max(0, x1 - x0) * Math.max(0, y1 - y0);
  const area = bounds.widthNorm * bounds.heightNorm;
  return area > 0 ? visibleArea / area : 0;
}

function withResolution(event, provenance, confidence) {
  return { ...event, targetResolution: { provenance, confidence } };
}

function findIdentityMatch(observations, target, eventMs) {
  if (!target) return undefined;
  const matches = [];
  for (const observation of observations) {
    for (const element of observation.elements ?? []) {
      const score = identityScore(target, element);
      if (score < 5) continue;
      // A capped AX walk is incomplete, not untrustworthy. It can still
      // corroborate a control that Computer Use named exactly, but it must not
      // support weaker fuzzy matches that depend on the missing remainder.
      if (observation.treeComplete === false && score < 10) continue;
      if (!hasUsableTargetGeometry(element.bounds, observation.windowBounds)) continue;
      const timingDistance = Math.abs(Date.parse(observation.observedAt) - eventMs);
      matches.push({
        observation,
        element,
        provenance: "ax-identity",
        confidence: geometryConfidence(observation, Math.min(0.99, 0.72 + score * 0.035)),
        rank: score * 1000 - timingDistance - walkPenalty(observation)
      });
    }
  }
  return matches.sort((left, right) => right.rank - left.rank)[0];
}

function hasUsableTargetGeometry(bounds, windowBounds) {
  const normalized = normalizeBounds(bounds, windowBounds);
  if (!normalized) return false;
  const area = normalized.widthNorm * normalized.heightNorm;
  if (area > 0.65) return false;
  // Permit partially clipped controls, but reject geometry that does not
  // intersect the captured window at all.
  return normalized.xNorm < 1 && normalized.yNorm < 1
    && normalized.xNorm + normalized.widthNorm > 0
    && normalized.yNorm + normalized.heightNorm > 0;
}

function findFocusedMatch(observations, target, toolStartMs, toolEndMs) {
  const matches = [];
  for (const observation of observations) {
    if (!observation.focused || !observation.bounds) continue;
    const observedMs = Date.parse(observation.observedAt);
    if (observedMs < toolStartMs - 150 || observedMs > toolEndMs + 750) continue;
    const element = {
      index: undefined,
      role: observation.role,
      subrole: observation.subrole,
      roleDescription: observation.roleDescription,
      title: observation.title,
      description: observation.description,
      help: observation.help,
      identifier: observation.identifier,
      domIdentifier: observation.domIdentifier,
      url: observation.url,
      valueDescription: observation.valueDescription,
      value: observation.value,
      bounds: observation.bounds
    };
    const normalizedRoles = roleIdentities(element);
    if (!normalizedRoles.some(role => INTERACTIVE_ROLES.has(role))) continue;
    const score = target ? identityScore(target, element) : 4;
    if (target && score < 3) continue;
    if (observation.treeComplete === false && (!target || score < 10)) continue;
    // Prefer focus observed after the estimated action and closest to tool end.
    const afterActionBonus = observedMs >= toolStartMs ? 500 : 0;
    matches.push({
      observation,
      element,
      provenance: "ax-focus",
      confidence: geometryConfidence(
        observation,
        target ? Math.min(0.96, 0.74 + score * 0.03) : 0.74
      ),
      rank: score * 1000 + afterActionBonus - Math.abs(toolEndMs - observedMs) - walkPenalty(observation)
    });
  }
  return matches.sort((left, right) => right.rank - left.rank)[0];
}

function findStructuralMatch(observations, target, context, eventMs) {
  if (!context) return undefined;
  // A named target must match by identity. Interpolating a named control onto
  // a nearby same-role sibling is precisely how an omitted AX node becomes a
  // confident-looking but false click. Structural recovery is reserved for
  // unlabeled controls whose identity genuinely consists of role + neighbors.
  if (identityStrings(target).some(identity => identity.kind !== "value")) return undefined;
  const expectedRole = normalizeRole(target?.role ?? context.target?.role);
  if (!expectedRole) return undefined;
  const matches = [];
  for (const observation of observations) {
    if (observation.treeComplete === false) continue;
    const elements = observation.elements ?? [];
    const before = bestAnchor(elements, context.before);
    const after = bestAnchor(elements, context.after);
    const roleCandidates = elements.filter(element => roleIdentities(element).includes(expectedRole));
    if (!roleCandidates.length || (!before && !after)) continue;
    const targetIndex = context.targetIndex;
    let predicted;
    if (before && after && context.before?.elementIndex !== context.after?.elementIndex) {
      const phase = (targetIndex - context.before.elementIndex)
        / (context.after.elementIndex - context.before.elementIndex);
      predicted = before.index + (after.index - before.index) * phase;
    } else if (before) {
      predicted = before.index + Math.max(1, targetIndex - context.before.elementIndex);
    } else {
      predicted = after.index - Math.max(1, context.after.elementIndex - targetIndex);
    }
    const bounded = roleCandidates.filter(element =>
      (!before || element.index > before.index) && (!after || element.index < after.index)
    );
    const pool = bounded.length ? bounded : roleCandidates;
    const element = pool.sort((left, right) =>
      Math.abs(left.index - predicted) - Math.abs(right.index - predicted)
    )[0];
    const distance = Math.abs(element.index - predicted);
    if (distance > 8) continue;
    const timingDistance = Math.abs(Date.parse(observation.observedAt) - eventMs);
    matches.push({
      observation,
      element,
      provenance: "ax-structural",
      confidence: geometryConfidence(observation, Math.max(0.58, 0.82 - distance * 0.04)),
      rank: 10_000 - distance * 500 - timingDistance - walkPenalty(observation)
    });
  }
  return matches.sort((left, right) => right.rank - left.rank)[0];
}

function bestAnchor(elements, anchor) {
  if (!anchor) return undefined;
  return elements.map(element => ({ element, score: identityScore(anchor, element) }))
    .filter(candidate => candidate.score >= 5)
    .sort((left, right) => right.score - left.score)[0]?.element;
}

export function identityScore(target, element) {
  if (!target || !element) return 0;
  const expectedRoles = roleIdentities(target);
  const actualRoles = roleIdentities(element);
  const roleIsKnown = target.roleKnown !== false && !expectedRoles.includes("unknown");
  const roleMatches = expectedRoles.some(role => actualRoles.includes(role));
  if (roleIsKnown && expectedRoles.length && actualRoles.length && !roleMatches) return 0;
  let score = roleIsKnown && roleMatches ? 3 : 0;
  const needles = identityStrings(target);
  const haystack = identityStrings(element);
  for (const needle of needles) {
    let best = 0;
    for (const candidate of haystack) {
      if (candidate.value === needle.value) best = Math.max(best, candidate.kind === needle.kind ? 7 : 5);
      else if (needle.kind !== "value" && candidate.kind !== "value"
        && (candidate.value.includes(needle.value) || needle.value.includes(candidate.value))) {
        best = Math.max(best, 2);
      }
    }
    score += best;
  }
  return score;
}

function identityStrings(element) {
  return [
    [element.label ?? element.title, "label"],
    [element.description, "description"],
    [element.help, "help"],
    [element.identifier, "identifier"],
    [element.domIdentifier, "domIdentifier"],
    [element.url, "url"],
    [element.roleDescription, "roleDescription"],
    [element.valueDescription, "valueDescription"],
    [element.placeholderValue, "placeholderValue"],
    [element.value, "value"]
  ].filter(([value]) => ["string", "number", "boolean"].includes(typeof value) && String(value).trim())
    .map(([value, kind]) => ({ value: normalizeText(String(value)), kind }));
}

function normalizeRole(role) {
  return String(role ?? "").toLowerCase().replace(/^ax/, "").replace(/[^a-z0-9]/g, "");
}

function roleIdentities(element) {
  return [element?.role, element?.subrole, element?.roleDescription]
    .map(normalizeRole).filter(Boolean);
}

function normalizeText(value) {
  return String(value).toLowerCase().replace(/https?:\/\//g, "").replace(/\s+/g, " ").trim();
}

function normalizeBounds(bounds, windowBounds) {
  if (![bounds?.x, bounds?.y, bounds?.width, bounds?.height, windowBounds?.x,
    windowBounds?.y, windowBounds?.width, windowBounds?.height].every(Number.isFinite)) return undefined;
  if (bounds.width <= 0 || bounds.height <= 0 || windowBounds.width <= 0 || windowBounds.height <= 0) return undefined;
  return {
    xNorm: (bounds.x - windowBounds.x) / windowBounds.width,
    yNorm: (bounds.y - windowBounds.y) / windowBounds.height,
    widthNorm: bounds.width / windowBounds.width,
    heightNorm: bounds.height / windowBounds.height
  };
}

function systemUIOccludedAt(timestamp, observations) {
  const eventMs = Date.parse(timestamp);
  const ordered = observations
    .filter(observation => Number.isFinite(Date.parse(observation.observedAt)))
    .toSorted((left, right) => Date.parse(left.observedAt) - Date.parse(right.observedAt));
  const preceding = ordered.findLast(observation => Date.parse(observation.observedAt) <= eventMs);
  const following = ordered.find(observation => Date.parse(observation.observedAt) > eventMs);
  const evidence = preceding ?? (following && Date.parse(following.observedAt) - eventMs <= 750 ? following : undefined);
  return evidence?.frontmostIsSystemSurface === true;
}

function walkPenalty(observation) {
  return Math.max(0, Number(observation.walkDurationMs) || 0);
}

function geometryConfidence(observation, confidence) {
  const duration = Math.max(0, Number(observation.walkDurationMs) || 0);
  if (duration <= 250) return confidence;
  return Math.max(0.5, confidence * Math.max(0.7, 1 - (duration - 250) / 3000));
}
