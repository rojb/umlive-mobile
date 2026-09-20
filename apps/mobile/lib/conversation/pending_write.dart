/// The writes the conversation is in the middle of (`T13`, `T13b`) and the
/// phase a create is in.
///
/// **Why the write lives outside the resolver.** `DeterministicOperationResolver`
/// is stateless by construction (`docs/architecture.md` §14): every call gets
/// its utterance, the registry, the executor and the localizations, and there
/// is nothing to reset between turns. A write spans several utterances, so it
/// cannot live there without making one resolution depend on the previous one.
/// The conversation owns it instead — `ConversationController` holds the one
/// write in flight and hands it back to the resolver as a parameter — which is
/// also what lets the next utterance be an answer to a question rather than a
/// new command.
///
/// **Why it is a value and not a mutable object.** The same rule every model in
/// this folder follows: a write is replaced by a new write, never mutated in
/// place — a create by [PendingCreate.withValue], which adds one field, and a
/// delete by a new [PendingDelete]. The resolver never mutates a write, and the
/// surface that renders one is handed an immutable snapshot. That is what keeps
/// the turn list and the draft from disagreeing about what was captured.
library;

import 'package:flutter/foundation.dart';

import '../openapi/registry.dart';

/// Where a create the conversation is assembling is.
enum WritePhase {
  /// Still asking for required fields, one at a time, in schema order.
  collecting,

  /// Every required field is captured and the complete record is being read
  /// back, waiting for an affirmative (`FR-MC03`).
  confirming,
}

/// A write the conversation is in the middle of (`FR-MC02`, `FR-MC03`,
/// `FR-MC05`).
///
/// Sealed because the two writes this app performs are read back
/// differently and confirmed identically: a create collects fields one at a
/// time, a delete names one record and nothing else. The band switches on
/// the type, so adding a third write would fail to compile until it is
/// handled, the same discipline `turn.dart` applies to turns.
sealed class PendingWrite {
  const PendingWrite({required this.entityName, required this.operationKey});

  /// The entity's recovered domain name in sentence register (`dirección`).
  final String entityName;

  /// [ApiOperation.key] of the operation the write will be sent to.
  final String operationKey;
}

/// A write the conversation is assembling (`FR-MC02`).
final class PendingCreate extends PendingWrite {
  const PendingCreate({
    required super.entityName,
    required super.operationKey,
    required this.requiredFields,
    required this.bodyFields,
    required this.values,
    required this.asking,
    required this.phase,
  });

  /// The create operation's required fields, in schema order: the list
  /// `FR-MC02` walks, one at a time, and the only thing that decides which
  /// question is asked next.
  final List<FieldDescriptor> requiredFields;

  /// Every writable field of the create body, in schema order: the whole body
  /// the backend accepts, not only the part `FR-MC02` asks for.
  ///
  /// **The distinction is the point of this list.** [requiredFields] drives the
  /// *questions* — one missing required field at a time — while [bodyFields]
  /// drives what may be *captured*: a value the operator volunteers for an
  /// optional field is legitimate only if the create body declares that field
  /// writable, and the draft shows what it holds in this order. That is why a
  /// read-only projection such as an `id` is never in it, and so can never be
  /// volunteered. It is `requestBody.fields` of the create operation verbatim,
  /// so the list is exactly as wide as the backend's own description.
  final List<FieldDescriptor> bodyFields;

  /// What has been captured so far, keyed by field name, in the schema order
  /// of [bodyFields]. The display text the operator gave, never the
  /// converted JSON value — conversion happens once, at submit time.
  final Map<String, String> values;

  /// The single field currently being asked for, or null while confirming.
  final FieldDescriptor? asking;

  final WritePhase phase;

  /// The required fields that are still missing, in schema order.
  List<FieldDescriptor> get missing => requiredFields
      .where((field) => !values.containsKey(field.name))
      .toList();

  /// True when every required field has a value and the record can be read
  /// back and submitted (`FR-MC02`: no partial body is ever sent).
  bool get isComplete => missing.isEmpty;

  /// The same draft with [name] captured and the phase advanced by
  /// [nextAsking] (`null` means the record is complete and is being
  /// confirmed).
  ///
  /// A copy, never a mutation: the resolver never mutates a draft in place, so
  /// a draft handed to a renderer and the draft handed back to the resolver can
  /// never be the same object.
  PendingCreate withValue(
    String name,
    String value, {
    WritePhase? phase,
    FieldDescriptor? nextAsking,
  }) => PendingCreate(
    entityName: entityName,
    operationKey: operationKey,
    requiredFields: requiredFields,
    bodyFields: bodyFields,
    values: <String, String>{...values, name: value},
    asking: nextAsking,
    phase:
        phase ??
        (nextAsking == null ? WritePhase.confirming : WritePhase.collecting),
  );

  /// Value equality: a draft is a value, never an identity.
  ///
  /// The conversation compares the draft it held before a resolve with the one
  /// the resolver hands back, and that comparison is what separates an outcome
  /// that moved the conversation forward from one that only repeated its
  /// question (`T13`). It is also what decides where the sentence is shown: an
  /// advance is owned by the Response focus band, a repeat stays a turn.
  ///
  /// [values] is compared with [mapEquals], so two drafts that captured the
  /// same fields are equal whatever order they were captured in.
  ///
  /// [bodyFields] is compared by **name list**, and deliberately not by the
  /// descriptors' own identity: two drafts built from the same schema declare
  /// the same body even when the registry handed back rebuilt
  /// [FieldDescriptor] objects, and a comparison that depended on their
  /// identity would let one registry reload look like a conversation that
  /// advanced.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PendingCreate &&
          other.entityName == entityName &&
          other.operationKey == operationKey &&
          other.phase == phase &&
          other.asking?.name == asking?.name &&
          mapEquals(other.values, values) &&
          listEquals(
            other.bodyFields.map((field) => field.name).toList(),
            bodyFields.map((field) => field.name).toList(),
          );

  /// Consistent with [==]: equal drafts hash the same.
  ///
  /// [Object.hashAllUnordered] is what keeps the hash contract intact — a
  /// `Map`'s iteration order is its insertion order, so hashing [values] in
  /// order would give two equal drafts two different hashes.
  @override
  int get hashCode => Object.hash(
    entityName,
    operationKey,
    phase,
    asking?.name,
    Object.hashAllUnordered(
      values.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
    Object.hashAll(bodyFields.map((field) => field.name)),
  );
}

/// A delete waiting for its affirmative (`FR-MC05`).
///
/// It carries exactly one target: the identifier the operator named. There
/// is no phase, because a delete is never assembled — it is identified and
/// then confirmed — and nothing is asked for while it is open.
final class PendingDelete extends PendingWrite {
  const PendingDelete({
    required super.entityName,
    required super.operationKey,
    required this.recordId,
  });

  /// The identifier of the record the read-back restates. `FR-MC05`: an
  /// ambiguous utterance never becomes a delete, so this is never guessed.
  final String recordId;

  /// Value equality: a delete is a value, never an identity.
  ///
  /// The conversation compares the write it held before a resolve with the one
  /// the resolver hands back, and that comparison is what separates an outcome
  /// that moved the conversation forward from one that only repeated its
  /// read-back (`T13b`). The runtime type is part of the comparison, so a
  /// delete can never compare equal to a create.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PendingDelete &&
          other.entityName == entityName &&
          other.operationKey == operationKey &&
          other.recordId == recordId;

  /// Consistent with [==]: equal deletes hash the same.
  @override
  int get hashCode => Object.hash(entityName, operationKey, recordId);
}
