/// Name-based inference of a foreign-key field into the entity it references
/// (`FR-ME03`; mirror image of `FR-MC06`, which resolves name to id for
/// writes — this resolves id to name for reads).
///
/// **The OpenAPI document does not declare the relation.** Measured against
/// the live-generated backend: `VentaResponse.clienteId` is published as
/// `{"type": "integer", "format": "int64"}`, with no `$ref` and no vendor
/// extension. `_resolveRef` (`registry_parser.dart:744`) resolves *schema*
/// `$ref`s and is never invoked for this property, so `FieldDescriptor` cannot
/// tell `clienteId` apart from any other integer.
///
/// The only signal left is the field's own name. `apps/api/src/codegen/build-ir.ts`
/// names a foreign-key DTO field `` `${base}Id` `` where `base` is the
/// association's role name, falling back to the target class name. That
/// convention holds when the role/attribute name equals the target's class
/// name and breaks when it does not (a role name such as `comprador` yields
/// `compradorId`, which names no route) — see
/// `odd/tasks/reference-expansion-on-reads.md` for the measured table. This is
/// a heuristic over a naming convention, not a fact the document asserts, so
/// the match here is exact or it does not fire at all: never partial, never
/// fuzzy. A near miss leaves the field to render exactly as it does today.
///
/// Pure and synchronous: no I/O, no Flutter import, nothing about the render
/// shape. `reference_expander.dart` is the caller that turns a hint into an
/// HTTP call.
library;

import '../core/text_fold.dart';
import 'registry.dart';

/// One field inferred, by name convention, to reference a record of [entity].
class ReferenceHint {
  const ReferenceHint({required this.fieldName, required this.entity});

  /// The reference field's own name, exactly as the schema declares it, e.g.
  /// `clienteId`.
  final String fieldName;

  /// The entity the field is inferred to point at. Always exposes
  /// `EntityRole.get` — [inferReferences] never returns a hint for an entity
  /// that does not, because there would be nothing to fetch the referenced
  /// record with.
  final EntityModel entity;
}

/// The suffix the generator appends to a foreign-key field's base name
/// (`apps/api/src/codegen/build-ir.ts`, `fieldBase`).
const String _idSuffix = 'Id';

/// The two JSON types a foreign key is ever declared as. A `$ref` field is
/// never one of these — its declared `type` carries the referenced schema
/// name instead — so this check alone keeps an inline object relation out of
/// the inference.
const Set<String> _referenceTypes = <String>{'integer', 'string'};

/// Infers which of [fields] are foreign keys into an entity [registry]
/// publishes a `get` for, by the name convention above.
///
/// A field qualifies only when *all* of: its name ends in `Id` with a
/// non-empty base — which is also what keeps the record's own `id` from ever
/// being mistaken for a reference, since `id` does not end in the capitalised
/// `Id` the convention requires; its declared type is `integer` or `string`;
/// and the folded base matches the folded name of a registry entity that
/// exposes `EntityRole.get`. Everything else is left out of the result, and
/// the caller renders it exactly as it does today.
List<ReferenceHint> inferReferences({
  required List<FieldDescriptor> fields,
  required ApiRegistry registry,
}) {
  final hints = <ReferenceHint>[];
  for (final field in fields) {
    if (!field.name.endsWith(_idSuffix)) continue;
    final base = field.name.substring(0, field.name.length - _idSuffix.length);
    if (base.isEmpty) continue;
    if (!_referenceTypes.contains(field.type)) continue;

    final foldedBase = foldText(base);
    EntityModel? target;
    for (final entity in registry.entities) {
      if (foldText(entity.name) != foldedBase) continue;
      if (!entity.roleKeys.containsKey(EntityRole.get)) continue;
      target = entity;
      break;
    }
    if (target != null) {
      hints.add(ReferenceHint(fieldName: field.name, entity: target));
    }
  }
  return hints;
}
