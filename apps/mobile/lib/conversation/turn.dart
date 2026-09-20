/// The chronological conversation model (`T11`).
///
/// `assistant_screen.dart` used to hold a bare `List<String> _utterances`,
/// with the greeting as a separate widget outside it. That left no room for an
/// assistant reply, no ordering between what the user said and what the
/// assistant answered, and no way to say a turn is still being worked on or
/// failed to resolve. This is the real model: one chronological list of turns,
/// each carrying who spoke and its own status.
library;

import 'operation_executor.dart';

/// The lifecycle of one turn.
///
/// A [UserTurn] is always [resolved] the moment it is captured — there is
/// nothing pending about having said or typed something. An [AssistantTurn]
/// starts [pending] while resolution and, later, execution are in flight, and
/// settles into [resolved], [queued] or [failed].
enum TurnStatus {
  /// Still being worked on: resolution or an HTTP call is in flight.
  pending,

  /// Settled with the command **persisted and not sent** (`FR-MD02`): it did
  /// not happen and it will.
  ///
  /// A queued turn is never a success and never a failure — nothing was
  /// answered by the backend, and nothing was lost either. The UX spec's rule
  /// is that a queued turn is never rendered like a done one, because a queued
  /// action that looks like a result is the app lying about durability.
  queued,

  /// Settled with an answer the assistant is confident in.
  resolved,

  /// Settled, but the assistant could not do — or could not understand —
  /// what was asked. The turn's text names what, specifically.
  failed,
}

/// The evidence of one operation call, carried on the [AssistantTurn] it
/// produced.
///
/// Nothing renders this yet — that is `T23`'s technical mode (`FR-ME06`) — but
/// the fields are captured now, at the only point they are ever known: the
/// moment the executor returns.
class OperationEvidence {
  const OperationEvidence({
    required this.operationKey,
    required this.resolvedPath,
    required this.method,
    this.statusCode,
    this.latencyMs,
  });

  /// Builds the evidence a turn carries from the executor's own result, so the
  /// two shapes never drift apart.
  factory OperationEvidence.fromResult(OperationResult result) =>
      OperationEvidence(
        operationKey: result.operationKey,
        resolvedPath: result.resolvedPath,
        method: result.method,
        statusCode: result.statusCode,
        latencyMs: result.latencyMs,
      );

  /// [ApiOperation.key] of the operation that ran — never a route or verb
  /// literal, always whatever the registry discovered (`FR-MA03`).
  final String operationKey;

  /// The path template after path-parameter substitution, e.g.
  /// `/api/cliente/42`.
  final String resolvedPath;

  /// The HTTP verb that was issued.
  final String method;

  /// The HTTP status the backend answered with, or null when the call never
  /// reached a response (no backend configured, unreachable, timed out).
  final int? statusCode;

  /// Wall time of the call, in milliseconds, or null when it never ran.
  final int? latencyMs;
}

/// One turn in the conversation, spoken by either party.
///
/// Sealed so every place that renders a turn is forced to handle both cases —
/// there is no third kind of turn and no way to add one without the compiler
/// pointing at every `switch` that needs it.
sealed class ConversationTurn {
  const ConversationTurn({required this.id, required this.timestamp});

  /// Stable identity within one conversation session. Never reused: a turn is
  /// replaced by a new value with the same [id], never mutated in place, so
  /// equality and list diffing stay simple.
  final String id;

  /// When the turn was created. Chronological order in the list is the
  /// source of truth for display; this is kept alongside it for evidence and
  /// for a future "how long ago" rendering.
  final DateTime timestamp;
}

/// A turn produced by the user, whether spoken or typed through the text
/// fallback (`FR-MB06`) — both paths produce the same kind of turn, because
/// capture does not care which one produced the utterance.
///
/// Always [TurnStatus.resolved]: capturing an utterance cannot itself fail in
/// a way this model represents; a capture failure never reaches the
/// conversation as a turn at all.
final class UserTurn extends ConversationTurn {
  const UserTurn({
    required super.id,
    required super.timestamp,
    required this.text,
  });

  final String text;
}

/// A turn produced by the assistant: the greeting, a resolved answer, a queued
/// write, or an honest "could not resolve" reply.
///
/// The greeting is no longer a special case outside the list — it is the
/// first [AssistantTurn], always [TurnStatus.resolved], synthesized by
/// [ConversationController] from the discovered registry the same way the old
/// widget-level greeting was.
final class AssistantTurn extends ConversationTurn {
  const AssistantTurn({
    required super.id,
    required super.timestamp,
    required this.text,
    required this.status,
    this.evidence,
  });

  /// What is shown and, eventually, spoken. Empty while [status] is
  /// [TurnStatus.pending] and a caption is used instead.
  final String text;

  final TurnStatus status;

  /// Which operation ran to produce this turn, when one did. Null for the
  /// greeting, for a turn that never reached execution, and for every turn
  /// until `T12`/`T13` start calling the executor.
  final OperationEvidence? evidence;

  AssistantTurn copyWith({
    String? text,
    TurnStatus? status,
    OperationEvidence? evidence,
  }) => AssistantTurn(
    id: id,
    timestamp: timestamp,
    text: text ?? this.text,
    status: status ?? this.status,
    evidence: evidence ?? this.evidence,
  );
}
