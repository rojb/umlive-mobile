/// Calls a discovered [ApiOperation] (`T11`).
///
/// `BackendProbe` is the only HTTP code that existed before this: it is
/// hard-wired to the one route this app is allowed to know by heart,
/// `/v3/api-docs`. Everything else — every entity's list, get, create, update
/// and delete — has to be reached through an operation the registry
/// discovered, and until now there was no way to call one at all.
///
/// **`FR-MA03` is absolute here.** Path substitution is driven entirely by
/// [ApiOperation.pathParameters] and the `{param}` placeholders in
/// [ApiOperation.path]; nothing in this file spells a route, a verb or a field
/// name as a literal. The only strings this class owns are protocol-level:
/// `errors`, the generated `ApiExceptionHandler`'s own contract key, not a
/// domain field.
///
/// It never throws for an ordinary HTTP outcome — a timeout, a refused
/// connection, a 4xx or a 5xx are all just a [OperationResult] with a
/// different [OperationFailureKind]. Mapping any of that to a Spanish sentence
/// is `T22`'s job, not this one's.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/log.dart';
import '../openapi/registry.dart';

/// How an [OperationResult] failed to be a plain success, or that it didn't.
enum OperationFailureKind {
  /// A 2xx response came back. [OperationResult.statusCode] carries it.
  none,

  /// [ConnectionController.buildExecutor] was called with no address stored —
  /// there is nothing to call.
  noBackendConfigured,

  /// A path placeholder had no bound value to substitute, named by
  /// [OperationResult.missingPathParameter].
  missingPathParameter,

  /// The request timed out against [OperationExecutor.timeout].
  timeout,

  /// The connection could not be made or was dropped: DNS failure, refused
  /// connection, reset mid-transfer.
  networkUnreachable,

  /// A response came back outside 2xx, in the 4xx range.
  clientError,

  /// A response came back outside 2xx, in the 5xx range.
  serverError,

  /// A status outside every range above (1xx, or a 3xx the client did not
  /// resolve within the redirect budget).
  unexpectedStatus,
}

/// The outcome of one [OperationExecutor.execute] call.
///
/// Carries exactly what `T22` will need to turn a failure into a domain
/// sentence, and what `T23` will need to render as technical-mode evidence —
/// neither of which happens here.
class OperationResult {
  const OperationResult({
    required this.operationKey,
    required this.method,
    required this.resolvedPath,
    required this.failure,
    this.statusCode,
    this.latencyMs,
    this.decodedBody,
    this.fieldErrors,
    this.missingPathParameter,
    this.queued = false,
  });

  /// [ApiOperation.key] of the operation that was called.
  final String operationKey;

  /// The HTTP verb that was issued, exactly as [ApiOperation.method] declares
  /// it.
  final String method;

  /// The path template after substitution, or the raw template when
  /// substitution never completed (e.g. [OperationFailureKind.missingPathParameter]).
  final String resolvedPath;

  final OperationFailureKind failure;

  /// The HTTP status the backend answered with, or null when the call never
  /// reached a response.
  final int? statusCode;

  /// Wall time of the call, in milliseconds, or null when it never ran.
  final int? latencyMs;

  /// The response body, JSON-decoded, or null when it was empty or did not
  /// parse as JSON. A `List` for a collection response, a `Map` for a single
  /// record or an error body.
  final Object? decodedBody;

  /// The generated `ApiExceptionHandler`'s `errors` map, verbatim and keyed by
  /// field, when the decoded body carried one. `T22` maps these keys to
  /// domain sentences; this class never interprets them — Bean Validation
  /// message text is JVM-locale-dependent and not a stable contract, so only
  /// the keys are carried forward.
  final Map<String, Object?>? fieldErrors;

  /// Which declared path parameter had no bound value, when
  /// [failure] is [OperationFailureKind.missingPathParameter].
  final String? missingPathParameter;

  /// True when the write was **persisted to the outbox** instead of being
  /// sent (`FR-MD02`): the backend never received it.
  ///
  /// A queued result is not a success, so [succeeded] stays false, and a
  /// caller must branch on this **before** it branches on [succeeded] —
  /// otherwise a queued write would be reported as done, which is the one
  /// thing the queue exists to prevent.
  final bool queued;

  /// True for a plain 2xx outcome. A queued result is never a success: this is
  /// false for it however the inner call went.
  bool get succeeded =>
      failure == OperationFailureKind.none &&
      statusCode != null &&
      statusCode! >= 200 &&
      statusCode! < 300;
}

/// A resolved path, or which declared parameter blocked resolving it.
class _PathSubstitution {
  const _PathSubstitution.ok(this.path) : missingParameter = null;
  const _PathSubstitution.missing(this.missingParameter) : path = null;

  final String? path;
  final String? missingParameter;
}

final RegExp _placeholderPattern = RegExp(r'\{([^{}]+)\}');

/// The seam through which a resolution reaches a discovered operation (`T11`).
///
/// This is the only place in the app that knows how to call an operation the
/// registry discovered, and the only way a resolver reaches the backend: a
/// resolver is handed one of these and can reach the network, storage and the
/// address nowhere else. `T14` composes `OutboxOperationExecutor` over the
/// HTTP implementation below, and `T17`'s read cache joins at this same seam,
/// so a resolver keeps receiving a plain [OperationExecutor] and never learns
/// what is wrapped around it.
abstract class OperationExecutor {
  const OperationExecutor();

  /// Calls [operation] with [pathParameters] bound, [body] as the request
  /// payload and [headers] set on the request, and never throws: every
  /// ordinary HTTP outcome, including no backend, no network and a non-2xx
  /// status, comes back as a result.
  ///
  /// [headers] are **protocol level and never a domain field**: the registry's
  /// own vocabulary is spelled in the path and the body, and a header is not a
  /// place any discovered name may be moved to. The only use today is a replay
  /// carrying the `Idempotency-Key` its first attempt carried (`FR-MD09`). A
  /// decorator forwards them untouched.
  Future<OperationResult> execute({
    required ApiOperation operation,
    Map<String, String> pathParameters = const <String, String>{},
    Object? body,
    Map<String, String> headers = const <String, String>{},
  });
}

/// The shipped [OperationExecutor]: calls a discovered operation over
/// `dart:io`'s `HttpClient`, mirroring `BackendProbe`'s discipline (timeout,
/// one redirect, a body cap) without reusing it — that class exists only for
/// the description path.
class HttpOperationExecutor extends OperationExecutor {
  HttpOperationExecutor(
    this._addressOf,
    this._tokenOf, {
    this.timeout = const Duration(seconds: 10),
  });

  /// Reads the live base address, so the executor is never a second source of
  /// truth for it — every call asks [ConnectionController] again.
  final Uri? Function() _addressOf;

  /// Reads the live bearer token the same way.
  final String? Function() _tokenOf;

  final Duration timeout;

  /// Same cap `BackendProbe` applies to the description document, for the
  /// same reason: a misbehaving backend must not make the app buffer without
  /// limit.
  static const int maxBodyBytes = 8 * 1024 * 1024;

  @override
  Future<OperationResult> execute({
    required ApiOperation operation,
    Map<String, String> pathParameters = const <String, String>{},
    Object? body,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final base = _addressOf();
    if (base == null) {
      logEvent('executor', {
        'operation': operation.key,
        'method': operation.method,
        'result': 'no_backend',
      });
      return OperationResult(
        operationKey: operation.key,
        method: operation.method,
        resolvedPath: operation.path,
        failure: OperationFailureKind.noBackendConfigured,
      );
    }

    final substitution = _substitutePath(operation, pathParameters);
    if (substitution.path == null) {
      logEvent('executor', {
        'operation': operation.key,
        'method': operation.method,
        'result': 'missing_path_parameter',
        'parameter': substitution.missingParameter,
      });
      return OperationResult(
        operationKey: operation.key,
        method: operation.method,
        resolvedPath: operation.path,
        failure: OperationFailureKind.missingPathParameter,
        missingPathParameter: substitution.missingParameter,
      );
    }
    final resolvedPath = substitution.path!;
    final uri = base.replace(path: resolvedPath);
    final token = _tokenOf();

    final stopwatch = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final outcome = await _send(
        client: client,
        method: operation.method,
        uri: uri,
        token: token,
        body: body,
        headers: headers,
      ).timeout(timeout);
      stopwatch.stop();

      final failure = _classify(outcome.status);
      logEvent('executor', {
        'operation': operation.key,
        'method': operation.method,
        'path': resolvedPath,
        'status': outcome.status,
        'ms': stopwatch.elapsedMilliseconds,
        'result': failure == OperationFailureKind.none ? 'ok' : failure.name,
        // Whether the request carried any caller-supplied header, never their
        // names and never their values. Today the only such header is the
        // `Idempotency-Key` a replayed write was queued with (`FR-MD09`), so
        // this one boolean is what lets a device verification tell a first
        // attempt from a replay while the key itself never reaches the log.
        'replay': headers.isNotEmpty,
      });

      return OperationResult(
        operationKey: operation.key,
        method: operation.method,
        resolvedPath: resolvedPath,
        failure: failure,
        statusCode: outcome.status,
        latencyMs: stopwatch.elapsedMilliseconds,
        decodedBody: outcome.decodedBody,
        fieldErrors: outcome.fieldErrors,
      );
    } on TimeoutException {
      stopwatch.stop();
      logEvent('executor', {
        'operation': operation.key,
        'method': operation.method,
        'path': resolvedPath,
        'result': 'timeout',
        'ms': stopwatch.elapsedMilliseconds,
        // The same flag the completed-response line carries: whether the
        // caller supplied headers, which today means this timeout cut a
        // replay rather than a first attempt.
        'replay': headers.isNotEmpty,
      });
      return OperationResult(
        operationKey: operation.key,
        method: operation.method,
        resolvedPath: resolvedPath,
        failure: OperationFailureKind.timeout,
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } on Object catch (error) {
      // DNS failure, refused connection, a socket reset mid-transfer: all of
      // them mean "no answer", the same discipline `BackendProbe` applies.
      stopwatch.stop();
      logEvent('executor', {
        'operation': operation.key,
        'method': operation.method,
        'path': resolvedPath,
        'result': 'network_error',
        'error': error.runtimeType.toString(),
        'ms': stopwatch.elapsedMilliseconds,
        // The same flag the completed-response line carries: whether the
        // caller supplied headers, which today means this failure cut a
        // replay rather than a first attempt.
        'replay': headers.isNotEmpty,
      });
      return OperationResult(
        operationKey: operation.key,
        method: operation.method,
        resolvedPath: resolvedPath,
        failure: OperationFailureKind.networkUnreachable,
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<
    ({
      int status,
      Object? decodedBody,
      Map<String, Object?>? fieldErrors,
    })
  >
  _send({
    required HttpClient client,
    required String method,
    required Uri uri,
    required String? token,
    required Object? body,
    required Map<String, String> headers,
  }) async {
    final request = await client.openUrl(method, uri);
    // Same budget `BackendProbe` uses for the description path: a tunnel or a
    // reverse proxy may redirect once, and no more.
    request.followRedirects = true;
    request.maxRedirects = 1;

    // Protocol-level headers, set before the body is written. The only caller
    // today is `T16`'s replay carrying the `Idempotency-Key` its first attempt
    // carried (`FR-MD09`); a domain field never travels here.
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }

    final bearer = token?.trim() ?? '';
    if (bearer.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }

    if (body != null) {
      final encoded = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType(
        'application',
        'json',
        charset: 'utf-8',
      );
      request.headers.contentLength = encoded.length;
      request.add(encoded);
    } else {
      request.headers.contentLength = 0;
    }

    final response = await request.close();
    final status = response.statusCode;

    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length >= maxBodyBytes) break;
    }
    if (bytes.length > maxBodyBytes) bytes.length = maxBodyBytes;

    Object? decoded;
    Map<String, Object?>? fieldErrors;
    if (bytes.isNotEmpty) {
      try {
        decoded = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        decoded = null;
      }
      if (decoded is Map) {
        // The generated `ApiExceptionHandler`'s own contract key — a protocol
        // detail this executor is told about explicitly, not a domain field
        // name derived from any diagram.
        final rawErrors = decoded['errors'];
        if (rawErrors is Map) {
          fieldErrors = rawErrors.map(
            (key, value) => MapEntry(key.toString(), value),
          );
        }
      }
    }

    return (status: status, decodedBody: decoded, fieldErrors: fieldErrors);
  }

  static OperationFailureKind _classify(int status) {
    if (status >= 200 && status < 300) return OperationFailureKind.none;
    if (status >= 400 && status < 500) return OperationFailureKind.clientError;
    if (status >= 500) return OperationFailureKind.serverError;
    return OperationFailureKind.unexpectedStatus;
  }

  /// Substitutes every `{param}` placeholder in [operation.path] using
  /// [operation.pathParameters] and the values bound in [boundParameters].
  ///
  /// Driven entirely by the registry's own declaration (`FR-MA03`): a
  /// placeholder with no declared parameter, or a declared parameter with no
  /// bound value, is reported as missing rather than guessed at or dropped.
  static _PathSubstitution _substitutePath(
    ApiOperation operation,
    Map<String, String> boundParameters,
  ) {
    var path = operation.path;
    for (final parameter in operation.pathParameters) {
      final placeholder = '{${parameter.name}}';
      if (!path.contains(placeholder)) continue;
      final value = boundParameters[parameter.name];
      if (value == null || value.isEmpty) {
        return _PathSubstitution.missing(parameter.name);
      }
      // Every substituted value is percent-encoded: a path segment is not a
      // free-form string, and a value containing `/` or a space must not be
      // able to reshape the request.
      path = path.replaceAll(placeholder, Uri.encodeComponent(value));
    }
    // Anything still shaped like `{...}` names a placeholder the operation
    // never declared a parameter for — inventing a value for it is exactly
    // what `FR-MA03` forbids.
    final leftover = _placeholderPattern.firstMatch(path);
    if (leftover != null) {
      return _PathSubstitution.missing(leftover.group(1));
    }
    return _PathSubstitution.ok(path);
  }
}
