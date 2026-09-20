/// The seam every resolution path implements.
///
/// `ConversationController` calls exactly this interface to turn one utterance
/// into a reply; it never resolves anything itself. `T11` wired the whole
/// conversation loop — capture, turns, the executor — against it before any
/// resolution logic existed, so a resolver could be dropped in without touching
/// the controller again.
///
/// The shipped implementation is `DeterministicOperationResolver`
/// (`deterministic_resolver.dart`): the deterministic read path of `T12` and
/// the write paths of `T13` and `T13b`, in one stateless class. There is no
/// placeholder implementation left, and no second resolver.
library;

import '../l10n/app_localizations.dart';
import '../openapi/registry.dart';
import 'operation_executor.dart';
import 'pending_write.dart';
import 'turn.dart';

/// What resolving one utterance produced.
class ResolverOutcome {
  const ResolverOutcome({
    required this.replyText,
    required this.status,
    this.evidence,
    this.pending,
  });

  /// What the assistant turn shows and, eventually, speaks.
  final String replyText;

  /// The three settled statuses are `resolved`, `failed` and `queued`:
  /// [TurnStatus.resolved] for an answer the assistant is confident in,
  /// [TurnStatus.failed] for an honest "could not resolve", and
  /// [TurnStatus.queued] for a write that was **persisted and will be sent**
  /// (`FR-MD02`) — the command did not happen and it will, so a queued outcome
  /// is neither a success nor a failure and is never reported as one. Never
  /// [TurnStatus.pending] — by the time a resolver returns, it is done.
  final TurnStatus status;

  /// The evidence of the operation call this resolution made, when it made
  /// one. Null for every outcome that never reached the executor — no entity
  /// matched, more than one matched, the intent was not understood, or the
  /// backend publishes no read operation for the entity. A call that ran and
  /// failed still carries its evidence, because the call is what `T23` has to
  /// show and `T22` has to explain.
  final OperationEvidence? evidence;

  /// The write the conversation is in the middle of after this turn, or null
  /// when there is none.
  ///
  /// A non-null value means the *next* utterance is an answer to that
  /// conversation — a field value (a create), an affirmative or a negative
  /// (either write) (`FR-MC02`, `FR-MC03`, `FR-MC05`) — and never a new command.
  /// The controller owns the write and hands it back on the next call; the
  /// resolver stays stateless. It is sealed, so a consumer has to handle both a
  /// [PendingCreate] and a [PendingDelete].
  final PendingWrite? pending;
}

/// Resolves one utterance against the discovered [ApiRegistry], optionally
/// calling operations through [OperationExecutor].
///
/// A single, narrow method: implementations decide everything about how an
/// utterance maps to an operation, but they can never reach the network,
/// storage or the backend address except through the [OperationExecutor]
/// they are handed — the same discipline that keeps [OperationExecutor]
/// itself the only place that knows how to call a discovered route.
abstract class OperationResolver {
  Future<ResolverOutcome> resolve({
    required String utterance,
    required ApiRegistry registry,
    required OperationExecutor executor,
    required AppLocalizations l10n,
    PendingWrite? pending,
  });
}
