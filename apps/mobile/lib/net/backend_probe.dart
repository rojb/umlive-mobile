import 'dart:async';
import 'dart:io';

import '../core/log.dart';
import 'description_endpoint.dart';
import 'reachability.dart';

/// Probes a backend's description path (`FR-MA02`, `FR-MA05`).
///
/// It answers one question — did this backend answer, and with what — and it
/// never asserts anything about the device's radios (`FR-MD01`).
class BackendProbe {
  BackendProbe({this.timeout = const Duration(seconds: 10)});

  /// FR-MA02 fixes 10 s. Exposed so a caller can pass a shorter budget.
  final Duration timeout;

  HttpClient? _client;
  int _generation = 0;

  /// Issues `GET <base>/v3/api-docs`, following at most one redirect and
  /// sending the shared bearer token when [token] is stored.
  ///
  /// Returns the state of the backend, mapping every failure mode to one of the
  /// [ReachabilityState]s. It throws nothing: a probe that cannot complete is a
  /// state, not an exception.
  Future<ProbeResult> fetchDescription({
    required Uri base,
    String? token,
    bool hasCachedRegistry = false,
  }) async {
    final uri = DescriptionEndpoint.of(base);
    final stopwatch = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = timeout;
    _client = client;
    final generation = ++_generation;

    int? status;
    try {
      status = await _send(client, uri, token).timeout(timeout);
    } on Object {
      // Timeout, DNS failure, refused connection, a second redirect, a socket
      // closed by cancel(): all of them mean "no answer", which is a state.
      status = null;
    } finally {
      stopwatch.stop();
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }

    if (generation != _generation) {
      // Cancelled or superseded: the caller discards this result.
      logEvent('probe', {'url': uri.toString(), 'result': 'stale'});
    }

    final state = _classify(status, hasCachedRegistry: hasCachedRegistry);
    return ProbeResult(
      state: state,
      url: uri.toString(),
      elapsedMs: stopwatch.elapsedMilliseconds,
      statusCode: status,
    );
  }

  /// Aborts the in-flight probe, if any. The pending future completes with a
  /// failure state that the caller must discard.
  void cancel() {
    _generation++;
    final client = _client;
    if (client != null) {
      _client = null;
      client.close(force: true);
    }
  }

  Future<int> _send(HttpClient client, Uri uri, String? token) async {
    final request = await client.getUrl(uri);
    // FR-MA02: follow one redirect — a tunnel or a reverse proxy may redirect
    // once — and no more.
    request.followRedirects = true;
    request.maxRedirects = 1;
    final bearer = token?.trim() ?? '';
    if (bearer.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  }

  static ReachabilityState _classify(
    int? status, {
    required bool hasCachedRegistry,
  }) {
    if (status == null) {
      return hasCachedRegistry
          ? ReachabilityState.offlineWithCache
          : ReachabilityState.unreachable;
    }
    if (status >= 200 && status < 300) return ReachabilityState.connected;
    if (status == 404) return ReachabilityState.missingDescription;
    return ReachabilityState.reachableButUnhealthy;
  }
}
