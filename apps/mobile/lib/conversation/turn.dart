/// The chronological conversation model (`T11`).
///
/// `assistant_screen.dart` used to hold a bare `List<String> _utterances`,
/// with the greeting as a separate widget outside it. That left no room for an
/// assistant reply, no ordering between what the user said and what the
/// assistant answered, and no way to say a turn is still being worked on or
/// failed to resolve. This is the real model: one chronological list of turns,
/// each carrying who spoke and its own status.
library;

import '../openapi/registry.dart';
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
/// It was captured at the only point any of it is ever known — the moment the
/// executor returns — and `T23`'s technical mode (`FR-ME06`) is the one surface
/// that renders it.
class OperationEvidence {
  const OperationEvidence({
    required this.operationKey,
    required this.resolvedPath,
    required this.method,
    this.statusCode,
    this.latencyMs,
    this.openapiVersion,
  });

  /// Builds the evidence a turn carries from the executor's own result, so the
  /// two shapes never drift apart.
  ///
  /// [openapiVersion] is the one fact the result cannot know and the app must
  /// never invent, so the caller hands it in: the resolver reads it off the
  /// registry it resolved the operation against ([ApiRegistry.openapiVersion],
  /// the `openapi` field the document itself declares) and passes it here
  /// (`T23`). Passing it in rather than looking it up later is deliberate: the
  /// registry in force at the moment of the call is the only one that can
  /// honestly explain that call, and a later lookup could read a document the
  /// operation never came from.
  factory OperationEvidence.fromResult(
    OperationResult result, {
    String? openapiVersion,
  }) => OperationEvidence(
    operationKey: result.operationKey,
    resolvedPath: result.resolvedPath,
    method: result.method,
    statusCode: result.statusCode,
    latencyMs: result.latencyMs,
    openapiVersion: openapiVersion,
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
  ///
  /// A call that ran and then failed without an answer does carry a number
  /// here — the executor measured how long the failed attempt took, and this is
  /// a faithful projection of that result. `T23`'s block is what decides not to
  /// present that number as a latency; see `technical_details.dart`.
  final int? latencyMs;

  /// The `openapi` field of the document this operation's registry was derived
  /// from ([ApiRegistry.openapiVersion]), e.g. `3.1.0`, or null when the
  /// document declared none.
  ///
  /// This is what makes the model-driven claim checkable **per turn** (`T23`,
  /// `FR-ME06`): the technical detail under a turn can name the version of the
  /// document the operation actually came from instead of asserting that the
  /// app discovered it. It is the **document's** own version, read from the
  /// `openapi` field at parse time, and never a constant this app believes.
  final String? openapiVersion;
}

/// What a read returned, in the shape a surface renders (`T21`).
///
/// It carries the records **and** the field list of the entity they came
/// from, because a card has to label a value with the name the schema gave it
/// — the original UML spelling, `códigoPostal` and not `codigoPostal` — and
/// the order the schema declares them in. That is the whole point of
/// rendering domain data instead of JSON: the vocabulary is the backend's,
/// not the app's (`FR-MC07`), and raw JSON never reaches the default
/// presentation (`FR-ME03`).
final class TurnResult {
  const TurnResult({
    required this.records,
    required this.fields,
    this.fromCache = false,
    this.referenceLabels = const <String, String>{},
  });

  /// Zero or more records, each a decoded JSON object.
  final List<Map<String, Object?>> records;

  /// The entity's readable fields, in response-schema order.
  final List<FieldDescriptor> fields;

  /// True when the answer came from the read cache (`FR-MD05`). The age is
  /// carried by the turn's sentence, so the cards do not repeat it.
  final bool fromCache;

  /// Foreign-key fields this read resolved into the referenced record's own
  /// label, by name convention (`FR-ME03`, `reference_hint.dart`), keyed
  /// `'<fieldName>:<idValue>'` — a given field always points at one entity, so
  /// the field name alone disambiguates the key.
  ///
  /// Defaults to empty so every existing [TurnResult] construction keeps
  /// compiling. It stays empty when [fields] carries no inferable reference,
  /// and a field/id pair is simply absent from it when the referenced record
  /// could not be fetched — `record_cards.dart` falls back to the raw id for
  /// any key this map does not carry (`reference_expander.dart`).
  final Map<String, String> referenceLabels;
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
///
/// The [result] this turn may carry holds the records a read returned, and
/// they are what the **backend** returned — never a local draft, a queued
/// command or anything the app inferred. The UX rule is exact: if the operator
/// sees a card, that data came back from the backend (UX spec, Pass 3), which
/// is why only the successful and cache-served read paths ever attach one.
final class AssistantTurn extends ConversationTurn {
  const AssistantTurn({
    required super.id,
    required super.timestamp,
    required this.text,
    required this.status,
    this.evidence,
    this.result,
  });

  /// What is shown and, eventually, spoken. Empty while [status] is
  /// [TurnStatus.pending] and a caption is used instead.
  final String text;

  final TurnStatus status;

  /// Which operation ran to produce this turn, when one did. Null for the
  /// greeting, for a turn that never reached execution, and for every turn
  /// until `T12`/`T13` start calling the executor.
  final OperationEvidence? evidence;

  /// The records a read returned, when this turn answers a read that succeeded
  /// or was served from the read cache (`T21`). Null for every other turn: the
  /// greeting, a write, a queued write, a refusal and a failure.
  final TurnResult? result;

  AssistantTurn copyWith({
    String? text,
    TurnStatus? status,
    OperationEvidence? evidence,
    TurnResult? result,
  }) => AssistantTurn(
    id: id,
    timestamp: timestamp,
    text: text ?? this.text,
    status: status ?? this.status,
    evidence: evidence ?? this.evidence,
    result: result ?? this.result,
  );
}
