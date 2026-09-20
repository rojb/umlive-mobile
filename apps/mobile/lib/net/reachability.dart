/// The reachability states the app surfaces (`FR-MA05`, `FR-MA06`).
///
/// Online means **the backend answered**, never that the radio is on
/// (`FR-MD01`). A state is therefore always the outcome of a probe of the
/// backend's own description path, never of an operating-system connectivity
/// flag.
///
/// Each state owns its own sentence, icon and text in the presentation layer;
/// none of them is distinguished by colour alone (`FR-MG04`).
enum ReachabilityState {
  /// Nothing is configured yet: no stored address, nothing to probe.
  neverConnected,

  /// 2xx from the description path: a real backend that describes itself.
  connected,

  /// 404 from the description path: the backend is alive and routed, but it
  /// was generated without `springdoc-openapi`, so it publishes no API
  /// description (`FR-MA06`). Routes are never guessed to work around it.
  missingDescription,

  /// 2xx from the description path, but the body is not a parseable OpenAPI
  /// document — an HTML page published at that path, for example. The backend
  /// is alive and says it has a description; what it serves is not one
  /// (`FR-MA06`). Nothing was derived from it and no route is guessed.
  notAnApiDescription,

  /// Answered with any other non-2xx status: reachable, not usable right now.
  reachableButUnhealthy,

  /// The probe failed, but a registry row for this profile exists, so what the
  /// backend described earlier is still known (`FR-MA04`, T4 writes that row).
  offlineWithCache,

  /// The probe failed and nothing is known about this backend.
  unreachable,
}

/// One probe of the description path, with the evidence it produced.
class ProbeResult {
  const ProbeResult({
    required this.state,
    required this.url,
    required this.elapsedMs,
    this.statusCode,
    this.bodyBytes,
  });

  final ReachabilityState state;

  /// The exact URL that was probed, for `[umlive][probe]` and for display.
  final String url;

  /// Wall time from request start to the last byte, in milliseconds.
  final int elapsedMs;

  /// The HTTP status, or null when the probe never got a response.
  final int? statusCode;

  /// The description document, read on a 2xx only. T3 (`FR-MA03`) parses it
  /// into the registry; every other state carries null.
  final List<int>? bodyBytes;

  /// True when the app has a usable backend: it answered, or it answered
  /// before and its answer is cached.
  bool get isUsable =>
      state == ReachabilityState.connected ||
      state == ReachabilityState.offlineWithCache;
}
