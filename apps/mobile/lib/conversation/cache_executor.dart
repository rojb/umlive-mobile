import '../core/log.dart';
import '../data/read_cache_repository.dart';
import '../openapi/registry.dart';
import 'operation_executor.dart';

/// The read-cache decorator over another [OperationExecutor] (`T17`,
/// `FR-MD05`).
///
/// `FR-MD05` splits the offline behaviour of this app in two and forbids
/// conflating them: **writes queue, reads cache, and neither borrows the other's
/// mechanism.** A write the backend never received is persisted to the outbox
/// and is still waiting to happen (`T14`); a read the backend did not answer is
/// not work waiting to happen — it is a question whose answer the app may
/// already remember — so it is answered from storage, with its age, or it
/// fails and says so.
///
/// **It is the outermost decorator, and that placement is the design.** The
/// reachability reporter (`ReachabilityOperationExecutor`) sits *inside* this
/// layer, so it sees the real attempt: a cached read is reported as *the
/// backend did not answer*, which is exactly what happened. The cache replaces
/// only what the caller receives; it never rewrites evidence about the backend.
/// Composing it the other way round would let a remembered answer keep the app
/// claiming `connected` over a dead backend, which is the failure `FR-MD01`
/// exists to prevent.
///
/// Like every other decorator here, it is not a second executor: the inner
/// [OperationExecutor] is the only thing that talks to the backend, and the
/// resolver keeps receiving a plain [OperationExecutor] and never learns this
/// class exists.
///
/// A remembered read is keyed by **(profile, operation, resolved path)**, and
/// the third component is load-bearing: the operation identifies the route, the
/// resolved path identifies the record. Keying on the operation alone would let
/// one record's body answer a request for another, which is the failure every
/// other choice in this layer is arranged to avoid.
///
/// It never throws for an ordinary storage problem. A cache that cannot be read
/// or written degrades to the live path, logged, and never takes a turn down.
class CachingOperationExecutor extends OperationExecutor {
  CachingOperationExecutor(this._inner, this._cache, this._profileIdOf);

  final OperationExecutor _inner;

  /// The read cache, or null when this build has none available. A null cache
  /// is a pass-through with a log line, never a silent one.
  final ReadCacheRepository? _cache;

  /// Reads the **live** profile id, the same discipline the address and token
  /// closures follow: it is re-read on every call rather than captured once, so
  /// a reconnect or a profile change is visible to a caller that built this
  /// executor before it happened.
  final String? Function() _profileIdOf;

  /// HTTP's safe methods. This is **HTTP semantics, not a domain verb**: the
  /// app never decides for itself that some entity's read is safe, the same way
  /// `OutboxOperationExecutor` never decides a write is queueable by name.
  /// Anything outside this set is a write and passes straight through.
  static const Set<String> _safeMethods = <String>{'GET', 'HEAD', 'OPTIONS'};

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

    // A write never consults the cache and is never written to it, whatever the
    // call returned: the outbox decorator inside this layer owns writes
    // entirely. This one line is the *never conflated* rule of `FR-MD05` — a
    // write is never answered from a remembered read.
    //
    // **A write the backend accepted is the one event that makes every
    // remembered read suspect** (`FR-ME04`). A list issued after a successful
    // create has to include the created record, and a list remembered before
    // it does not: answering from it would silently omit what was just
    // created. So the read cache is dropped here and repopulated by the next
    // read, which prefers an honest miss to a collection that lies by
    // omission. A **queued** write changes nothing: `succeeded` is deliberately
    // false for it, the backend never received it, nothing was persisted and no
    // remembered answer went stale.
    if (!_safeMethods.contains(operation.method.toUpperCase())) {
      if (result.succeeded) await _clearAfterWrite(operation);
      return result;
    }

    // The backend answered, so this is a live read (`FR-MD05` at its best): it
    // is remembered for the next time the backend does not, and returned to the
    // caller completely unchanged.
    if (result.succeeded) {
      await _store(operation, result.resolvedPath, result.decodedBody);
      return result;
    }

    // Only "the backend never answered" is answered from storage. A 4xx or a
    // 5xx means the backend **did** answer and refused, and a refusal is
    // reported as it is: a cached `200` must never mask a live refusal, the
    // same way `T14` never queues a write the backend already saw. A call that
    // never left (`noBackendConfigured`, `missingPathParameter`) is not a
    // backend failure either, so it passes through untouched.
    if (result.failure != OperationFailureKind.networkUnreachable &&
        result.failure != OperationFailureKind.timeout) {
      return result;
    }

    final cached = await _read(operation, result.resolvedPath);
    // An offline read with nothing remembered is a failure and says so. The
    // original result travels untouched, so the caller reports what actually
    // happened.
    if (cached == null) return result;

    return _asCached(result, cached);
  }

  /// Drops every read remembered for the live profile, because a write just
  /// succeeded (`FR-ME04`).
  ///
  /// The clear is addressed by **profile**, never by operation: the record the
  /// write created or changed may appear in any remembered collection, and the
  /// cache key is (profile, operation, resolved path), so only a profile-wide
  /// clear is certain to drop every row the write invalidated.
  ///
  /// Like every other storage call in this layer it degrades rather than
  /// throws: a cache that cannot be cleared is logged and the write's own
  /// answer is still returned untouched. A missing cache or an unusable profile
  /// is a quiet no-op — there is nothing remembered to invalidate, so no clear
  /// happened and none is logged.
  Future<void> _clearAfterWrite(ApiOperation operation) async {
    final cache = _cache;
    if (cache == null) return;
    final profileId = _profileIdOf();
    if (profileId == null || profileId.isEmpty) return;
    try {
      await cache.clearAfterWrite(profileId);
    } on Object catch (error) {
      logEvent('cache', <String, Object?>{
        'action': 'skip',
        'operation': operation.key,
        'reason': 'clear_failed',
        'error': error.runtimeType.toString(),
      });
    }
  }

  /// Writes one successful read into the cache, or reports why it could not.
  ///
  /// A storage problem never changes what the caller receives: the live answer
  /// was already received and is already correct.
  ///
  /// [resolvedPath] — and not `operation.path` — is what identifies the record.
  /// The template is the *same string for every record* of a collection item
  /// route (`GET /api/cliente/{id}`), so storing under it would make an offline
  /// read of `cliente 2` return `cliente 1`'s remembered body. The resolved
  /// path is what the request actually went to, and it is the only thing that
  /// tells the two apart.
  Future<void> _store(
    ApiOperation operation,
    String resolvedPath,
    Object? body,
  ) async {
    final profileId = _usableProfileId(operation);
    if (profileId == null) return;
    try {
      await _cache!.store(
        profileId: profileId,
        operationKey: operation.key,
        path: resolvedPath,
        body: body,
      );
    } on Object catch (error) {
      logEvent('cache', <String, Object?>{
        'action': 'skip',
        'operation': operation.key,
        'path': resolvedPath,
        'reason': 'store_failed',
        'error': error.runtimeType.toString(),
      });
    }
  }

  /// The remembered answer for one failed read, or null when there is none to
  /// use.
  ///
  /// [resolvedPath] is looked up for the same reason it is stored: the
  /// operation key addresses the route, and only the resolved path addresses
  /// the record, so an offline `cliente 2` can never be answered from
  /// `cliente 1`'s row.
  ///
  /// Null covers three cases, and all three mean the same thing to the caller:
  /// nothing is cached, the cache is unusable, or reading it failed. Every one
  /// of them degrades to the live path.
  Future<CachedRead?> _read(ApiOperation operation, String resolvedPath) async {
    final profileId = _usableProfileId(operation);
    if (profileId == null) return null;
    try {
      return await _cache!.read(
        profileId: profileId,
        operationKey: operation.key,
        path: resolvedPath,
      );
    } on Object catch (error) {
      logEvent('cache', <String, Object?>{
        'action': 'skip',
        'operation': operation.key,
        'path': resolvedPath,
        'reason': 'read_failed',
        'error': error.runtimeType.toString(),
      });
      return null;
    }
  }

  /// The live profile id, or null with the reason this call cannot use the
  /// cache.
  ///
  /// Both skips are logged rather than assumed away: a read answered offline
  /// with no age is a very different thing from one answered offline from
  /// storage, and the log has to be able to tell them apart.
  String? _usableProfileId(ApiOperation operation) {
    if (_cache == null) {
      logEvent('cache', <String, Object?>{
        'action': 'skip',
        'operation': operation.key,
        'reason': 'no_cache',
      });
      return null;
    }
    final profileId = _profileIdOf();
    if (profileId == null || profileId.isEmpty) {
      logEvent('cache', <String, Object?>{
        'action': 'skip',
        'operation': operation.key,
        'reason': 'no_profile',
      });
      return null;
    }
    return profileId;
  }

  /// The failed result, with the remembered body and the age that marks it as
  /// remembered.
  ///
  /// [OperationResult.succeeded] stays exactly as the inner call left it —
  /// false — because the backend did not answer this read. `queued` is copied
  /// through untouched: a read is never queued (`T14`), and this layer has no
  /// business asserting otherwise. The status stays null for the same reason:
  /// no response came back, and the cached body is not a response of this call.
  static OperationResult _asCached(OperationResult result, CachedRead cached) =>
      OperationResult(
        operationKey: result.operationKey,
        method: result.method,
        resolvedPath: result.resolvedPath,
        failure: result.failure,
        statusCode: result.statusCode,
        latencyMs: result.latencyMs,
        decodedBody: cached.body,
        fieldErrors: result.fieldErrors,
        missingPathParameter: result.missingPathParameter,
        queued: result.queued,
        fromCache: true,
        cacheAge: cached.age(DateTime.now()),
      );
}
