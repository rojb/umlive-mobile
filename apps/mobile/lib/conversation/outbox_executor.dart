import '../core/log.dart';
import '../data/outbox_repository.dart';
import '../openapi/registry.dart';
import 'operation_executor.dart';

/// The durable-queue decorator over another [OperationExecutor] (`T14`).
///
/// A write the backend never received is persisted to the outbox instead of
/// being reported as a failure, so the command is not lost when the radio is
/// off (`FR-MD02`). A read is never queued: there is nothing to send later that
/// the operator is still waiting for.
///
/// It is a decorator and not a second executor: the inner [OperationExecutor]
/// is the only thing that talks to the backend, and this class changes only
/// what happens **after** the backend did not answer. That keeps one place
/// that knows how to make an HTTP call, and lets `T17`'s read cache compose
/// over the same seam later.
class OutboxOperationExecutor extends OperationExecutor {
  OutboxOperationExecutor(this._inner, this._outbox, this._profileIdOf);

  final OperationExecutor _inner;
  final OutboxRepository _outbox;

  /// Reads the **live** profile id, the same discipline the address and token
  /// closures follow: it is re-read on every call rather than captured once, so
  /// a reconnect or a profile change is visible to a caller that built this
  /// executor before it happened.
  final String? Function() _profileIdOf;

  /// HTTP's safe methods: issuing one changes nothing on the backend, so a
  /// retry has nothing to send and nothing to duplicate. This is **HTTP
  /// semantics, not a domain verb** — the app never decides for itself that
  /// some entity's write is safe.
  static const Set<String> _safeMethods = <String>{'GET', 'HEAD', 'OPTIONS'};

  /// The only two write verbs the resolver issues today: a create and a delete.
  /// Any other write verb is treated as a create, which is the conservative
  /// choice — a create carries an idempotency key, so an unexpected verb is
  /// replayed with the key that makes it recognisable rather than replayed
  /// blindly.
  static const String _methodDelete = 'DELETE';

  @override
  Future<OperationResult> execute({
    required ApiOperation operation,
    Map<String, String> pathParameters = const <String, String>{},
    Object? body,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final result = await _inner.execute(
      operation: operation,
      pathParameters: pathParameters,
      body: body,
      headers: headers,
    );

    // A safe method is never queued: a read the backend did not answer is not
    // work waiting to happen, and replaying it later would answer a question
    // the operator asked against a backend that may since have changed.
    if (_safeMethods.contains(operation.method.toUpperCase())) return result;

    // Only "the backend did not answer" means the request never arrived. A
    // 4xx or a 5xx means the backend **did** answer and the request was
    // received, so re-sending it would duplicate work the backend already saw
    // — and may already have performed.
    if (result.failure != OperationFailureKind.networkUnreachable &&
        result.failure != OperationFailureKind.timeout) {
      return result;
    }

    final profileId = _profileIdOf();
    if (profileId == null || profileId.isEmpty) {
      // No profile means no queue to persist against. Say it in the log and
      // return the call's own failure rather than pretending the write was
      // captured.
      logEvent('outbox', <String, Object?>{
        'action': 'skip',
        'operation': operation.key,
        'reason': 'no_profile',
      });
      return result;
    }

    try {
      await _outbox.enqueue(
        profileId: profileId,
        operationKey: operation.key,
        method: result.method,
        // The path the inner executor actually resolved, not the template: the
        // queue stores what has to be sent, and substitution already happened.
        path: result.resolvedPath,
        pathParameters: pathParameters,
        body: body,
        kind: _kindFor(result.method),
      );
    } on Object catch (error) {
      // The queue itself is unavailable. The write was not persisted, so the
      // honest answer is the inner failure, not a queued one.
      logEvent('outbox', <String, Object?>{
        'action': 'skip',
        'operation': operation.key,
        'reason': 'enqueue_failed',
        'error': error.runtimeType.toString(),
      });
      return result;
    }

    return _asQueued(result);
  }

  /// The kind of a queued write, from the HTTP verb it was issued with.
  static OutboxKind _kindFor(String method) =>
      method.toUpperCase() == _methodDelete
      ? OutboxKind.delete
      : OutboxKind.create;

  /// The inner result marked as queued.
  ///
  /// `queued` is set and nothing else is touched: [OperationResult.succeeded]
  /// stays exactly as the inner call left it — false — because the backend
  /// never received this write. It is the caller's job to branch on `queued`
  /// before `succeeded`, which is what keeps a queued write from ever being
  /// reported as done.
  static OperationResult _asQueued(OperationResult result) => OperationResult(
    operationKey: result.operationKey,
    method: result.method,
    resolvedPath: result.resolvedPath,
    failure: result.failure,
    statusCode: result.statusCode,
    latencyMs: result.latencyMs,
    decodedBody: result.decodedBody,
    fieldErrors: result.fieldErrors,
    missingPathParameter: result.missingPathParameter,
    queued: true,
  );
}
