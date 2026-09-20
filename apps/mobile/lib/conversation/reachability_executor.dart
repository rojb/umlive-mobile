import '../openapi/registry.dart';
import 'operation_executor.dart';

/// The reachability decorator over another [OperationExecutor] (`T15`,
/// `FR-MD01`).
///
/// `FR-MA05`'s state was decided only by the probe of the description path, so
/// a backend that died after that one probe stayed `connected` on screen over
/// a full-signal radio: the probe had answered earlier in the session and
/// nothing ever revised it. `FR-MD01` defines online as *the backend answered*
/// — a captive portal, an expired tunnel or a dead backend on a full-signal
/// connection is offline — and a call to a discovered operation is the
/// strongest evidence this app ever gets: a real request, to a real route,
/// which either comes back with a status or does not.
///
/// **It reports every result and claims nothing about its meaning.** A 4xx or
/// a 5xx is an answer like any other — the backend is alive and routing — and
/// a timeout is not; deciding which `ReachabilityState` each one settles on is
/// `ConnectionController.reportOperationOutcome`'s job, which is why this class
/// holds a plain callback and no policy. A resolver keeps receiving a plain
/// [OperationExecutor] and never learns this decorator exists, the same seam
/// `OutboxOperationExecutor` uses.
///
/// Composed in `ConnectionController.buildExecutor()` as the **outermost**
/// layer, so the reporter sees exactly the [OperationResult] the conversation
/// received — including one the outbox decorator marked as queued, whose
/// backend never answered.
class ReachabilityOperationExecutor extends OperationExecutor {
  ReachabilityOperationExecutor(this._inner, this._report);

  final OperationExecutor _inner;

  /// Called with every result, before it is returned.
  ///
  /// Synchronous on purpose: revising a reachability state must not add a
  /// microtask, an await or a timeout between a turn and its own answer.
  final void Function(OperationResult result) _report;

  @override
  Future<OperationResult> execute({
    required ApiOperation operation,
    Map<String, String> pathParameters = const <String, String>{},
    Object? body,
  }) async {
    final result = await _inner.execute(
      operation: operation,
      pathParameters: pathParameters,
      body: body,
    );
    _report(result);
    return result;
  }
}
