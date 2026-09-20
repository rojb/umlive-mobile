/// The seam every resolution path implements.
///
/// `ConversationController` calls exactly this interface to turn one
/// utterance into a reply; it never resolves anything itself. `T11` wired the
/// whole conversation loop — capture, turns, the executor — against it before
/// any resolution logic existed, so a resolver could be dropped in without
/// touching the controller again.
///
/// The shipped implementation is `DeterministicOperationResolver`
/// (`deterministic_resolver.dart`): the deterministic read path of `T12`,
/// which `T13` extends with the write path. There is no placeholder
/// implementation left, and no second resolver.
library;

import '../l10n/app_localizations.dart';
import '../openapi/registry.dart';
import 'operation_executor.dart';
import 'turn.dart';

/// What resolving one utterance produced.
class ResolverOutcome {
  const ResolverOutcome({
    required this.replyText,
    required this.status,
    this.evidence,
  });

  /// What the assistant turn shows and, eventually, speaks.
  final String replyText;

  /// [TurnStatus.resolved] for an answer the assistant is confident in,
  /// [TurnStatus.failed] for an honest "could not resolve". Never
  /// [TurnStatus.pending] — by the time a resolver returns, it is done.
  final TurnStatus status;

  /// The evidence of the operation call this resolution made, when it made
  /// one. Null for every outcome that never reached the executor — no entity
  /// matched, more than one matched, the intent was not understood, or the
  /// backend publishes no read operation for the entity. A call that ran and
  /// failed still carries its evidence, because the call is what `T23` has to
  /// show and `T22` has to explain.
  final OperationEvidence? evidence;
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
  });
}
