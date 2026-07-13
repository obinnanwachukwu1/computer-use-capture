export function redactAccessibilityObservation(observation) {
  const redact = element => {
    if (!element || typeof element !== "object") return element;
    const { value, valueDescription, placeholderValue, ...safe } = element;
    return safe;
  };
  return {
    ...redact(observation),
    elements: observation.elements?.map(redact)
  };
}

export function redactEventForPersistence(event) {
  const redactIdentity = identity => {
    if (!identity || typeof identity !== "object") return identity;
    const { rawDescriptor, value, valueDescription, placeholderValue, ...safe } = identity;
    return safe;
  };
  const context = event.accessibilityContext;
  const coordinateResolution = event.coordinateResolution ? {
    ...event.coordinateResolution,
    ...(event.coordinateResolution.screenshot ? {
      screenshot: stripEvidencePath(event.coordinateResolution.screenshot)
    } : {})
  } : undefined;
  return {
    ...event,
    ...(coordinateResolution ? { coordinateResolution } : {}),
    ...(event.accessibilityTarget ? { accessibilityTarget: redactIdentity(event.accessibilityTarget) } : {}),
    ...(context ? {
      accessibilityContext: {
        ...context,
        target: redactIdentity(context.target),
        before: redactIdentity(context.before),
        after: redactIdentity(context.after)
      }
    } : {})
  };
}

function stripEvidencePath(screenshot) {
  const { evidence: _privateCachePath, ...safe } = screenshot;
  return safe;
}
