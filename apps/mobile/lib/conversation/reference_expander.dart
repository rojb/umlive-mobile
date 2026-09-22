/// Expands foreign-key fields into the referenced record's own label, after a
/// read settles (`FR-ME03`; design in
/// `odd/tasks/reference-expansion-on-reads.md`).
///
/// **Runs after the executor stack, never inside it.** `CachingOperationExecutor`
/// is the outermost decorator and stores the raw decoded body exactly as the
/// backend sent it; baking an expanded label into that body would go stale
/// independently of the referenced record and would need its own invalidation
/// parallel to `clearAfterWrite`. This class instead calls the same
/// [OperationExecutor] the resolver already holds, after the read it decorates
/// has already settled, so the live and cache-served branches converge on one
/// code path and the cache keeps storing exactly what the backend answered.
///
/// **A failed expansion is never an error.** A referenced record that 404s,
/// times out or fails for any other reason is swallowed here: a read that
/// worked must not start failing because a decoration on top of it did not.
/// The field/id pair simply stays absent from the returned map, which is what
/// tells the caller to fall back to the raw id.
library;

import '../l10n/app_localizations.dart';
import '../openapi/reference_hint.dart';
import '../openapi/registry.dart';
import 'operation_executor.dart';

/// How many extra HTTP calls one turn's expansion may issue, whatever the
/// number of hinted fields or records it found. A list of twenty sales by one
/// customer stays under this cap through deduplication alone; this ceiling
/// bounds the worst case — many distinct referenced records — the honest
/// shape of N+1 at demo scale, the same trade-off `FR-ME02` already accepts
/// for `RecordCards.maxCards`. Rows beyond the cap keep their raw id.
const int maxReferenceFetches = 20;

/// Builds the `TurnResult.referenceLabels` map for one read's [records], given
/// the entity's [fields] and the [registry] the read was resolved against.
///
/// [fields] drives [inferReferences]: when it infers no reference field at
/// all, this returns the empty map without looking at a single record, so a
/// backend with no inferable reference costs nothing beyond that one check.
///
/// Every fetch is deduplicated by `(entity, id)` — twenty records naming the
/// same customer resolve to one call, whose label is then reused for every
/// field/id pair that named that record — and the total is capped by
/// [maxReferenceFetches].
Future<Map<String, String>> expandReferences({
  required List<Map<String, Object?>> records,
  required List<FieldDescriptor> fields,
  required ApiRegistry registry,
  required OperationExecutor executor,
  required AppLocalizations l10n,
}) async {
  final hints = inferReferences(fields: fields, registry: registry);
  if (hints.isEmpty || records.isEmpty) return const <String, String>{};

  // Grouped by the `(entity, id)` dedupe key, so one fetch can fill in every
  // field/id pair that named the same referenced record.
  final grouped = <String, List<_Reference>>{};
  for (final hint in hints) {
    final operation = _getOperation(hint.entity, registry);
    if (operation == null) continue;
    final parameterName = operation.pathParameterNames.isEmpty
        ? null
        : operation.pathParameterNames.first;
    if (parameterName == null) continue;

    for (final record in records) {
      final rawId = record[hint.fieldName];
      if (rawId == null) continue;
      final idText = rawId.toString();
      final dedupeKey = '${hint.entity.name}\u0000$idText';
      grouped
          .putIfAbsent(dedupeKey, () => <_Reference>[])
          .add(
            _Reference(
              fieldName: hint.fieldName,
              idText: idText,
              entity: hint.entity,
              operation: operation,
              parameterName: parameterName,
            ),
          );
    }
  }
  if (grouped.isEmpty) return const <String, String>{};

  final labels = <String, String>{};
  var fetches = 0;
  for (final references in grouped.values) {
    if (fetches >= maxReferenceFetches) break;
    fetches++;

    final first = references.first;
    final label = await _fetchLabel(
      entity: first.entity,
      operation: first.operation,
      parameterName: first.parameterName,
      idText: first.idText,
      executor: executor,
      l10n: l10n,
    );
    if (label == null) continue;

    for (final reference in references) {
      labels['${reference.fieldName}:${reference.idText}'] = label;
    }
  }
  return labels;
}

/// The entity's `get` operation, or null when the registry no longer publishes
/// one for it — the same "nothing honest to call" refusal every other read
/// path in this app applies (`FR-MA03`). [inferReferences] already required
/// the role key to be present, so this can only miss when [registry.operation]
/// itself does not resolve it.
ApiOperation? _getOperation(EntityModel entity, ApiRegistry registry) {
  final key = entity.roleKeys[EntityRole.get];
  return key == null ? null : registry.operation(key);
}

/// One fetched label, or null when the call did not produce a usable record —
/// swallowed here rather than thrown, so the row this label was for simply
/// falls back to its raw id.
Future<String?> _fetchLabel({
  required EntityModel entity,
  required ApiOperation operation,
  required String parameterName,
  required String idText,
  required OperationExecutor executor,
  required AppLocalizations l10n,
}) async {
  try {
    final result = await executor.execute(
      operation: operation,
      pathParameters: <String, String>{parameterName: idText},
    );
    // A cache-served answer is a real answer here too, exactly as it is for
    // the read this decorates (`FR-MD05`): the remembered body is as usable a
    // source for a label as a live one.
    if (!result.succeeded && !result.fromCache) return null;
    final body = result.decodedBody;
    if (body is! Map) return null;
    return _label(
      entity: entity,
      record: Map<String, Object?>.from(body),
      idText: idText,
      l10n: l10n,
    );
  } on Object {
    // Nothing an executor's own contract documents throwing, but this call is
    // decoration on top of an already-settled read and may never let a
    // failure of its own propagate into it.
    return null;
  }
}

/// The referenced record's first readable string field, with the id kept
/// visible next to it so the rendering is never ambiguous about which record
/// it means. With no such field, only the id is shown.
String _label({
  required EntityModel entity,
  required Map<String, Object?> record,
  required String idText,
  required AppLocalizations l10n,
}) {
  final idLabel = l10n.recordReferenceIdSuffix(idText);
  for (final field in entity.readableFields) {
    if (field.name == 'id') continue;
    if (field.type != 'string') continue;
    final value = record[field.name];
    if (value is String && value.isNotEmpty) {
      return l10n.recordReferenceValue(value, idLabel);
    }
  }
  return l10n.recordReferenceValueUnnamed(idLabel);
}

/// One field/id pair waiting to be labelled, carrying everything one fetch
/// needs, grouped by [expandReferences]'s `(entity, id)` dedupe key.
class _Reference {
  const _Reference({
    required this.fieldName,
    required this.idText,
    required this.entity,
    required this.operation,
    required this.parameterName,
  });

  final String fieldName;
  final String idText;
  final EntityModel entity;
  final ApiOperation operation;
  final String parameterName;
}
