/// The ordered drain of the durable queue (`T16`, `FR-MD04`, `FR-MD08`,
/// `FR-MD09`).
///
/// It is its own service so `ConversationController` only triggers it and
/// reports what it returns: this class reads the queue, sends it in issue
/// order and hands back one [DrainOutcome] per item. It owns no turn, no copy
/// and no user-facing string — the caller chooses the sentence from the domain
/// word an outcome carries.
///
/// **A replay never goes through the outbox decorator.** The executor handed to
/// [OutboxDrainer] is the replay stack
/// (`ConnectionController.buildReplayExecutor()`): the same transport and the
/// same reachability reporting, deliberately without `OutboxOperationExecutor`.
/// An item is already in the queue, and a decorator that re-enqueued a failed
/// replay would write a second row carrying a fresh idempotency key — exactly
/// the duplicate `FR-MD09` exists to prevent.
library;

import '../core/log.dart';
import '../data/outbox_repository.dart';
import '../openapi/registry.dart';
import '../presentation/discovered_scope.dart';
import 'operation_executor.dart';

/// One drained item and what happened to it.
sealed class DrainOutcome {
  const DrainOutcome({
    required this.seq,
    required this.kind,
    required this.entityName,
  });

  /// `outbox.seq` of the item: the place it holds in the queue, and the order
  /// the drain processed it in.
  final int seq;

  /// What kind of write it was, told by the item's own column — never inferred
  /// from the entity or the sentence.
  final OutboxKind kind;

  /// The entity of the registry whose `operationKeys` contains the item's
  /// operation, in sentence register (`lowerFirst`), or null when none does.
  ///
  /// It is a domain **word**, not a sentence: this is what lets the caller say
  /// the outcome in domain language without the drainer holding any copy.
  final String? entityName;
}

/// One queued write the backend accepted.
final class DrainSent extends DrainOutcome {
  const DrainSent({
    required super.seq,
    required super.kind,
    required super.entityName,
    required this.statusCode,
  });

  /// The 2xx status the backend answered with. A sent outcome always carries
  /// one: a call that never reached a response is a failure, not a success.
  final int statusCode;
}

/// One queued write that failed, and ended the run.
final class DrainFailed extends DrainOutcome {
  const DrainFailed({
    required super.seq,
    required super.kind,
    required super.entityName,
    required this.statusCode,
    required this.reason,
  });

  /// The status the backend answered with, or null when it never answered.
  final int? statusCode;

  /// A **stable code**, never a sentence: `no_answer` when no status came back
  /// at all, `rejected` when the backend answered outside 2xx, and
  /// `operation_not_in_registry` when the current registry no longer publishes
  /// the item's operation. It is what the drain reports and logs.
  ///
  /// What the queue **persists** is the stored form of it, which carries the
  /// status beside a refusal (`rejected:404`): the row is the only thing that
  /// survives, and it has to be enough for the queue screen to name the reason
  /// in domain language months later.
  final String reason;
}

/// What one drain run did.
class DrainReport {
  const DrainReport({
    required this.outcomes,
    required this.stoppedOnFailure,
    required this.remaining,
  });

  /// One entry per item the run touched, in the order it touched them. A
  /// skipped run touches nothing and has none.
  final List<DrainOutcome> outcomes;

  /// True when a failure ended the run (`FR-MD04`): the rest of the queue was
  /// left exactly as it was, because a later command may depend on the one that
  /// failed.
  final bool stoppedOnFailure;

  /// Rows still outstanding after the run, for the log and the queue badge.
  final int remaining;
}

/// Drains the durable queue in issue order (`T16`).
///
/// One item at a time, strictly by [OutboxItem.seq], stopping on the first
/// failure (`FR-MD04`): a later command can never overtake an earlier one it
/// depends on. A failed item keeps its place and its reason and is never
/// silently discarded (`FR-MD08`), so it can be retried or cancelled once `T18`
/// exposes the queue.
class OutboxDrainer {
  OutboxDrainer({
    required this.outbox,
    required this.profileIdOf,
    required this.executorOf,
    required this.registryOf,
    required this.isReachable,
  });

  /// The queue this drain reads and updates. It is the same repository the
  /// outbox decorator writes to, so the drain and the queue cannot disagree.
  final OutboxRepository outbox;

  /// Reads the **live** profile id, the same discipline the address and token
  /// closures follow: it is re-read on every run rather than captured once, so
  /// a reconnect or a profile change is visible to a drainer built earlier.
  final String? Function() profileIdOf;

  /// Builds the executor a replay goes through. It must be the outbox-free
  /// replay stack (see the note at the top of the file).
  final OperationExecutor Function() executorOf;

  /// Reads the **live** registry, so an item whose operation the current
  /// document no longer publishes is refused rather than sent to a route the
  /// backend does not have (`FR-MA03`).
  final ApiRegistry? Function() registryOf;

  /// `FR-MD01`: online means *the backend answered*. Sending a queued command
  /// against a backend that has not answered is what the requirement forbids,
  /// so the drain refuses to start when this is false.
  final bool Function() isReachable;

  /// The stable codes a skip, a per-item failure and a stop are logged with.
  /// They are protocol-level descriptions, never captured values.
  static const String _reasonNoProfile = 'no_profile';
  static const String _reasonOffline = 'offline';
  static const String _reasonNoRegistry = 'no_registry';
  static const String _reasonEmpty = 'empty';
  static const String _reasonDone = 'done';
  static const String _reasonFirstFailure = 'first_failure';
  static const String _reasonNoAnswer = 'no_answer';
  static const String _reasonRejected = 'rejected';
  static const String _reasonNotInRegistry = 'operation_not_in_registry';

  bool _draining = false;

  /// True while [drain] is running.
  ///
  /// The drain is single-threaded and this is what keeps it that way: a second
  /// run started over the same queue would send the head item twice. The caller
  /// reads it at the moment it decides to start a run — synchronously, before
  /// the run's first `await` — so the notification a drain's own result
  /// produces cannot start a second one.
  bool get isDraining => _draining;

  /// Drains the queue in issue order, one item at a time, stopping on the first
  /// failure. Never throws for an ordinary outcome.
  ///
  /// It does nothing — an empty report, with `remaining` read from the queue —
  /// when the profile is unknown, when [isReachable] is false, or when the
  /// registry is null. A queued command must not be sent to a backend that has
  /// not answered (`FR-MD01`), and without a document the app cannot say what
  /// the command means (`FR-MA03`).
  Future<DrainReport> drain() async {
    final currentProfileId = profileIdOf();
    if (currentProfileId == null || currentProfileId.isEmpty) {
      return _skip(reason: _reasonNoProfile, profileId: null);
    }
    if (!isReachable()) {
      return _skip(reason: _reasonOffline, profileId: currentProfileId);
    }
    final registry = registryOf();
    if (registry == null) {
      return _skip(reason: _reasonNoRegistry, profileId: currentProfileId);
    }

    _draining = true;
    try {
      return await _run(profileId: currentProfileId, registry: registry);
    } finally {
      _draining = false;
    }
  }

  /// The body of a run that has a profile, a reachable backend and a registry.
  Future<DrainReport> _run({
    required String profileId,
    required ApiRegistry registry,
  }) async {
    // Read **once**, so every item in the run comes from one consistent
    // snapshot of the queue, and process strictly by `seq` ascending
    // (`FR-MD04`).
    final items = await outbox.pending(profileId);
    logEvent('outbox', <String, Object?>{
      'action': 'drain',
      'step': 'start',
      'count': items.length,
    });
    if (items.isEmpty) {
      return _finish(
        profileId: profileId,
        outcomes: const <DrainOutcome>[],
        stoppedOnFailure: false,
        stopReason: _reasonEmpty,
      );
    }

    final outcomes = <DrainOutcome>[];
    var stoppedOnFailure = false;
    for (final item in items) {
      final outcome = await _drainOne(item: item, registry: registry);
      outcomes.add(outcome);
      if (outcome is DrainFailed) {
        stoppedOnFailure = true;
        break;
      }
    }

    return _finish(
      profileId: profileId,
      outcomes: outcomes,
      stoppedOnFailure: stoppedOnFailure,
      stopReason: stoppedOnFailure ? _reasonFirstFailure : _reasonDone,
    );
  }

  /// One item, end to end: in-flight, resolved against the registry, sent, and
  /// recorded. Every branch returns a [DrainOutcome] and leaves the queue in
  /// the state that outcome describes.
  Future<DrainOutcome> _drainOne({
    required OutboxItem item,
    required ApiRegistry registry,
  }) async {
    await outbox.markInFlight(item.id);

    final entityName = _entityNameFor(registry, item.operationKey);
    final operation = registry.operation(item.operationKey);
    if (operation == null) {
      // The registry no longer publishes this operation: it cannot be replayed
      // against a route that may not exist (`FR-MA03`), and a later command may
      // depend on this one, so the run stops instead of skipping ahead.
      await outbox.markFailed(item.id, _reasonNotInRegistry);
      logEvent('outbox', <String, Object?>{
        'action': 'drain',
        'step': 'failed',
        'seq': item.seq,
        'reason': _reasonNotInRegistry,
        'status': null,
      });
      return DrainFailed(
        seq: item.seq,
        kind: item.kind,
        entityName: entityName,
        statusCode: null,
        reason: _reasonNotInRegistry,
      );
    }

    final result = await executorOf().execute(
      operation: operation,
      pathParameters: item.pathParameters,
      body: item.body,
      // The header name is protocol, not a domain field (`FR-MD09`): a replay
      // of a create carries the key its first attempt carried, so an ambiguous
      // outcome cannot become a duplicate record.
      headers: item.idempotencyKey == null
          ? const <String, String>{}
          : <String, String>{'Idempotency-Key': item.idempotencyKey!},
    );

    if (result.succeeded) {
      await outbox.markSent(item.id);
      logEvent('outbox', <String, Object?>{
        'action': 'drain',
        'step': 'sent',
        'seq': item.seq,
        'status': result.statusCode,
      });
      return DrainSent(
        seq: item.seq,
        kind: item.kind,
        entityName: entityName,
        statusCode: result.statusCode!,
      );
    }

    // A queued result is never expected here — the drain does not go through
    // the outbox decorator — but if it ever came back true it is treated as no
    // answer and stops: re-queueing inside a drain would grow the queue on
    // every attempt instead of draining it.
    final reason = result.statusCode == null || result.queued
        ? _reasonNoAnswer
        : _reasonRejected;
    await outbox.markFailed(item.id, _storedReason(reason, result.statusCode));
    logEvent('outbox', <String, Object?>{
      'action': 'drain',
      'step': 'failed',
      'seq': item.seq,
      'reason': reason,
      'status': result.statusCode,
    });
    return DrainFailed(
      seq: item.seq,
      kind: item.kind,
      entityName: entityName,
      statusCode: result.statusCode,
      reason: reason,
    );
  }

  /// The reason the drain **persists** into `outbox.last_error`.
  ///
  /// A refusal keeps the status beside the code — `rejected:404` — because the
  /// queue screen has to name the reason in domain language months later, and
  /// the stored row is the only thing that survives: the one column has room
  /// for both facts, so both are written. `no_answer` and
  /// `operation_not_in_registry` carry no status and are stored as they are.
  ///
  /// [DrainFailed.reason] itself stays the bare code, because it is a log
  /// field first and only the persisted form changed (`T18`).
  String _storedReason(String reason, int? statusCode) {
    if (reason != _reasonRejected || statusCode == null) return reason;
    return '$_reasonRejected:$statusCode';
  }

  /// Closes a run: the outstanding count after it and one `stop` line.
  Future<DrainReport> _finish({
    required String profileId,
    required List<DrainOutcome> outcomes,
    required bool stoppedOnFailure,
    required String stopReason,
  }) async {
    final remaining = await outbox.pendingCount(profileId);
    logEvent('outbox', <String, Object?>{
      'action': 'drain',
      'step': 'stop',
      'reason': stopReason,
      'remaining': remaining,
    });
    return DrainReport(
      outcomes: List<DrainOutcome>.unmodifiable(outcomes),
      stoppedOnFailure: stoppedOnFailure,
      remaining: remaining,
    );
  }

  /// A run that does not start: an empty report and one `skip` line.
  ///
  /// `remaining` is read from the queue when a profile is known, so the caller
  /// can say how much is still owed even though nothing was sent; with no
  /// profile there is no queue to count, and zero is the only honest value.
  Future<DrainReport> _skip({
    required String reason,
    required String? profileId,
  }) async {
    final remaining = profileId == null
        ? 0
        : await outbox.pendingCount(profileId);
    logEvent('outbox', <String, Object?>{
      'action': 'drain',
      'step': 'skip',
      'reason': reason,
    });
    return DrainReport(
      outcomes: const <DrainOutcome>[],
      stoppedOnFailure: false,
      remaining: remaining,
    );
  }

  /// The entity whose `operationKeys` carries [operationKey], in sentence
  /// register, or null when none does.
  ///
  /// This is the drainer's only contact with domain language: it hands back a
  /// lower-cased name taken from the registry and builds no sentence, so no
  /// user-facing string exists outside `AppLocalizations`.
  String? _entityNameFor(ApiRegistry registry, String operationKey) {
    for (final entity in registry.entities) {
      if (entity.operationKeys.contains(operationKey)) {
        return lowerFirst(entity.name);
      }
    }
    return null;
  }
}
