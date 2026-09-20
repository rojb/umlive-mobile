/// The seam `T12` (read path) and `T13` (write path) fill in.
///
/// `ConversationController` calls exactly this interface to turn one
/// utterance into a reply; it never resolves anything itself. Splitting it out
/// this way means `T11` can wire the whole conversation loop — capture,
/// turns, the executor — before any resolution logic exists, and `T12`/`T13`
/// can be dropped in later without touching the controller again.
library;

import '../core/log.dart';
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
  /// one. Null for every outcome that never reached the executor — which, for
  /// [UnimplementedOperationResolver], is always.
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

/// The honest placeholder until `T12`/`T13` land.
///
/// It never guesses an operation, never invents a matched entity and never
/// fakes a reply: it names, in the conversation itself, that resolution has
/// not been built yet. `FR-MC04` requires an unresolved utterance to say what
/// it could not understand; this implementation understands nothing yet, and
/// says exactly that rather than something that only sounds like an answer.
class UnimplementedOperationResolver implements OperationResolver {
  const UnimplementedOperationResolver();

  @override
  Future<ResolverOutcome> resolve({
    required String utterance,
    required ApiRegistry registry,
    required OperationExecutor executor,
    required AppLocalizations l10n,
  }) async {
    // The utterance's content is never logged — only that one arrived and how
    // long it was — the same discipline `log.dart` already applies to the
    // bearer token.
    logEvent('resolver', {
      'result': 'unimplemented',
      'utteranceLength': utterance.length,
      'entities': registry.entities.length,
    });
    return ResolverOutcome(
      replyText: l10n.conversationResolverNotImplemented,
      status: TurnStatus.failed,
    );
  }
}
