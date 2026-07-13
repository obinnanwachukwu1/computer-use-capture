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
  if (!needsElementTarget && !["type_text", "set_value", "select_text"].includes(event.action)) {
    return direct ? withResolution(event, "direct", 1) : event;
  }

  const eventMs = Date.parse(event.timestamp);
  const toolStartMs = Date.parse(event.timing?.toolCallStartedAt ?? event.timestamp);
  const toolEndMs = Date.parse(event.timing?.toolCallEndedAt ?? event.timestamp);
  const captureStartMs = Date.parse(captureStartedAt);
  const windowStart = Math.max(captureStartMs, toolStartMs - 1500);
  const windowEnd = toolEndMs + 750;
  const nearbyCandidates = observations.filter(observation => {
    const observedMs = Date.parse(observation.observedAt);
    return observedMs >= windowStart && observedMs <= windowEnd;
  });
  // The watcher emits a new snapshot when the AX tree changes. A quiet page's
  // most recent snapshot is therefore current state, not stale telemetry. Keep
  // the last snapshot preceding the action alongside the short post-action
  // window so stable controls remain resolvable after long thinking gaps.
  const latestPreAction = observations
    .filter(observation => {
      const observedMs = Date.parse(observation.observedAt);
      return observedMs >= captureStartMs && observedMs <= toolStartMs;
    })
    .sort((left, right) => Date.parse(right.observedAt) - Date.parse(left.observedAt))[0];
  const candidates = latestPreAction && !nearbyCandidates.includes(latestPreAction)
    ? [latestPreAction, ...nearbyCandidates]
    : nearbyCandidates;

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
      ? withResolution(event, "direct", 1)
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
      ? withResolution(event, "direct", 1)
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
      bounds: normalized
    },
    targetResolution: {
      provenance: direct ? "direct" : match.provenance,
      confidence: direct ? 1 : match.confidence,
      observedAt: match.observation.observedAt,
      elementIndex: needsElementTarget ? elementIndex : undefined,
      nativeElementIndex: match.element.index
    }
  };
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
      if (!hasUsableTargetGeometry(element.bounds, observation.windowBounds)) continue;
      const timingDistance = Math.abs(Date.parse(observation.observedAt) - eventMs);
      matches.push({
        observation,
        element,
        provenance: "ax-identity",
        confidence: Math.min(0.99, 0.72 + score * 0.035),
        rank: score * 1000 - timingDistance
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
    // Prefer focus observed after the estimated action and closest to tool end.
    const afterActionBonus = observedMs >= toolStartMs ? 500 : 0;
    matches.push({
      observation,
      element,
      provenance: "ax-focus",
      confidence: target ? Math.min(0.96, 0.74 + score * 0.03) : 0.74,
      rank: score * 1000 + afterActionBonus - Math.abs(toolEndMs - observedMs)
    });
  }
  return matches.sort((left, right) => right.rank - left.rank)[0];
}

function findStructuralMatch(observations, target, context, eventMs) {
  if (!context) return undefined;
  const expectedRole = normalizeRole(target?.role ?? context.target?.role);
  if (!expectedRole) return undefined;
  const matches = [];
  for (const observation of observations) {
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
      confidence: Math.max(0.58, 0.82 - distance * 0.04),
      rank: 10_000 - distance * 500 - timingDistance
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
