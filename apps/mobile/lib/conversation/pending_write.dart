/// The write the conversation is assembling, one field at a time (`T13`,
/// `FR-MC02`), and the phase it is in.
///
/// **Why the draft lives outside the resolver.** `DeterministicOperationResolver`
/// is stateless by construction (`docs/architecture.md` §14): every call gets
/// its utterance, the registry, the executor and the localizations, and there
/// is nothing to reset between turns. A draft spans several utterances, so it
/// cannot live there without making one resolution depend on the previous one.
/// The conversation owns it instead — `ConversationController` holds the one
/// draft in flight and hands it back to the resolver as a parameter — which is
/// also what lets the next utterance be an answer to a question rather than a
/// new command.
///
/// **Why it is a value and not a mutable object.** The same rule every model in
/// this folder follows: a draft is replaced by a new draft with one more field
/// ([withValue]), never mutated in place. The resolver never mutates a draft,
/// and the surface that renders one is handed an immutable snapshot. That is
/// what keeps the turn list and the draft from disagreeing about what was
/// captured.
library;

import 'package:flutter/foundation.dart';

import '../openapi/registry.dart';

/// Where a write in progress is.
enum WritePhase {
  /// Still asking for required fields, one at a time, in schema order.
  collecting,

  /// Every required field is captured and the complete record is being read
  /// back, waiting for an affirmative (`FR-MC03`).
  confirming,
}

/// A write the conversation is assembling (`FR-MC02`).
final class PendingWrite {
  const PendingWrite({
    required this.entityName,
    required this.operationKey,
    required this.requiredFields,
    required this.values,
    required this.asking,
    required this.phase,
  });

  /// The entity's recovered domain name in sentence register (`dirección`,
  /// recovered from `Dirección`), which is what the read-back and the question
  /// name (`FR-MC07`).
  final String entityName;

  /// [ApiOperation.key] of the create operation the draft will be sent to.
  final String operationKey;

  /// The create operation's required fields, in schema order: the list
  /// `FR-MC02` walks, one at a time.
  final List<FieldDescriptor> requiredFields;

  /// What has been captured so far, keyed by field name, in the schema order
  /// of [requiredFields]. The display text the operator gave, never the
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
  PendingWrite withValue(
    String name,
    String value, {
    WritePhase? phase,
    FieldDescriptor? nextAsking,
  }) => PendingWrite(
    entityName: entityName,
    operationKey: operationKey,
    requiredFields: requiredFields,
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
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PendingWrite &&
          other.entityName == entityName &&
          other.operationKey == operationKey &&
          other.phase == phase &&
          other.asking?.name == asking?.name &&
          mapEquals(other.values, values);

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
  );
}
