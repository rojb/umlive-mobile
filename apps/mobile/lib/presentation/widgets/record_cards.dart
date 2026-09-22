import 'package:flutter/material.dart';

import '../../conversation/spanish_language.dart';
import '../../conversation/turn.dart';
import '../../l10n/app_localizations.dart';
import '../../openapi/registry.dart';
import '../../theme/tokens.dart';

/// The records a read returned, as cards, under the assistant turn that answers
/// it (`T21`, `FR-ME03`).
///
/// The default presentation of a collection is this surface and never the JSON
/// the backend sent. Each card is a column of label/value rows in the
/// **schema's** field order, labelled with the name the backend gave each field
/// — the original UML spelling, `códigoPostal` and not `codigoPostal`
/// (`FR-MC07`). That is the whole point of rendering domain data instead of
/// JSON: the vocabulary on screen is the backend's description of itself, and
/// nothing here invents a name a diagram did not declare.
///
/// It draws only what the backend returned. `T21` attaches a [TurnResult] to
/// the successful and cache-served read paths alone, so a card can never show a
/// local draft or a queued command — the UX rule is that if the operator sees a
/// card, that data came back from the backend (UX spec, Pass 3).
///
/// A zero-record answer draws **nothing**: the count is the turn's sentence
/// (`T20`), and an empty card area under it would only repeat that with
/// whitespace.
///
/// **The stack is labelled for the accessibility layer** (`T24`, `FR-MG03`).
/// A collection reaches the screen as up to twenty cards, each one a column of
/// label/value nodes; with no label, a screen reader walks a dozen value nodes
/// and is never told what they belong to or how many there are. The group
/// therefore carries one `Semantics` label naming the entity in the registry's
/// own plural and the number of cards it renders, and each card carries its
/// position in that group. Both are **labels on top of the contents**, not
/// replacements: the field rows inside a card stay readable, because that is
/// the data the operator came for (`T24` is not a licence to relabel the app).
///
/// The entity is passed in rather than derived here: the card knows the records
/// and their fields, and the caller is the only place that resolved the
/// operation they came from against the registry (`FR-MC07`).
class RecordCards extends StatelessWidget {
  const RecordCards({super.key, required this.result, this.entityName});

  /// What the read returned: the records, and the entity's readable fields in
  /// response-schema order.
  final TurnResult result;

  /// The entity the records came from, in the registry's own sentence-case
  /// spelling (`cliente`, `dirección`), or null when it cannot be named — an
  /// operation the current registry no longer publishes, or a turn with no
  /// evidence to resolve. Null means the group is not labelled at all, and each
  /// card still says its position: an invented entity word would be worse than
  /// no word (`FR-MC07`).
  final String? entityName;

  /// How many records are rendered before the rest are summarised in one line.
  ///
  /// `FR-ME02` puts a collection of one thousand in scope as correct behaviour,
  /// and a thousand cards inside the conversation's `SingleChildScrollView` is
  /// a freeze, not a rendering: the whole list is laid out eagerly, so the work
  /// is unbounded while the answer itself is finished. Twenty bounds the worst
  /// case and fits a collection a demo actually produces; the records beyond it
  /// are counted by the truncation line, so what was left out is **stated**
  /// instead of silently dropped.
  static const int maxCards = 20;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final records = result.records;
    if (records.isEmpty) return const SizedBox.shrink();

    final truncated = records.length > maxCards;
    final shown = truncated ? maxCards : records.length;

    final cards = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < shown; index++) ...[
          if (index > 0) const SizedBox(height: AppSpacing.sm),
          _RecordCard(
            record: records[index],
            fields: result.fields,
            referenceLabels: result.referenceLabels,
            position: index + 1,
            total: shown,
          ),
        ],
        if (truncated) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.recordCardsTruncated(shown, records.length),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ],
      ],
    );

    final entity = entityName;
    // No entity to name means no group label: the cards keep their own position
    // labels, and the app does not invent a word the registry did not supply.
    if (entity == null) return cards;

    return Semantics(
      container: true,
      // The plural rule is the same one the count answer uses, so the app has
      // exactly one definition of how an entity's name grows a syllable
      // (`spanish_language.dart`).
      label: l10n.recordCardsGroupSemantics(
        shown,
        entity,
        pluralizeSpanishNoun(entity),
      ),
      child: cards,
    );
  }
}

/// One record, as a surface: a column of label/value rows.
///
/// The labels walk [TurnResult.fields], which is the schema's own list in the
/// order the response declares it, so two records of the same entity line up
/// row for row and a value is always labelled with the name the backend gave
/// the field (`FR-MC07`).
///
/// A field the record does not carry is rendered with the "no value" copy
/// **rather than disappearing**: a card that skipped it would shift every row
/// below it, and two records of the same entity would stop being comparable at
/// a glance. An absent field and a `null` value render the same way, because to
/// an operator they are the same fact: the backend does not carry that value.
///
/// The card carries its position as a `Semantics` label (`T24`), so the reader
/// who entered a labelled group can tell one card from the next. The rows
/// inside stay readable underneath it.
class _RecordCard extends StatelessWidget {
  const _RecordCard({
    required this.record,
    required this.fields,
    required this.referenceLabels,
    required this.position,
    required this.total,
  });

  /// The decoded JSON object, exactly as the backend returned it.
  final Map<String, Object?> record;

  /// The entity's readable fields, in response-schema order.
  final List<FieldDescriptor> fields;

  /// [TurnResult.referenceLabels]: the labels reference expansion resolved
  /// for this read, keyed `'<fieldName>:<idValue>'` (`FR-ME03`). A field/id
  /// pair this map does not carry — because the field is not an inferred
  /// reference, or its fetch failed — falls back to the raw value exactly as
  /// it rendered before this feature.
  final Map<String, String> referenceLabels;

  /// This card's position in the group, counting from one.
  final int position;

  /// How many cards the group renders.
  final int total;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    final rows = <Widget>[];
    for (final field in fields) {
      final value = record[field.name];

      // A nested object is omitted entirely. A card's value column is one line
      // of domain text, and a nested object has no honest one-line rendering:
      // it would have to be printed as JSON, and **raw JSON never reaches the
      // default presentation** (`FR-ME03`). The row is dropped rather than
      // shown empty, because a label with nothing truthful under it is worse
      // than no row at all.
      if (value is Map) continue;

      // A field reference expansion resolved (`FR-ME03`) shows the
      // referenced record's own label instead of the bare foreign key, with
      // its id still visible inside that label. The row's own label stays the
      // schema's field name either way (`clienteId`, never an invented
      // `cliente`) — only the value column changes.
      final referenceLabel = value == null
          ? null
          : referenceLabels['${field.name}:$value'];

      rows.add(
        _FieldRow(
          label: field.name,
          value: referenceLabel ?? _valueText(value, l10n),
          // An absent key and a `null` are both "no value" and share the muted
          // treatment, so the card reads the same whichever the backend sent.
          hasValue: value != null,
        ),
      );
    }

    // Every field was a nested object: there is nothing a card can say about
    // this record without printing JSON.
    if (rows.isEmpty) return const SizedBox.shrink();

    return Semantics(
      container: true,
      label: l10n.recordCardSemantics(position, total),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadii.cardSmallAll,
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < rows.length; index++) ...[
              if (index > 0) const SizedBox(height: AppSpacing.xs),
              rows[index],
            ],
          ],
        ),
      ),
    );
  }

  /// One value, rendered as the text a card shows.
  ///
  /// The rules, each deliberate:
  /// - a `String` is shown as it is — it is the operator's data, unchanged;
  /// - a `num` with no fractional part is shown in its integer form, because
  ///   the fixture returns `monto: 1500.0` and "1500.0" is not what an operator
  ///   says;
  /// - a `bool` is shown as the yes/no copy, in the operator's own language;
  /// - a `null` is the "no value" copy (the caller mutes it);
  /// - a `List` is summarised by its element count, and nothing more: a card
  ///   cannot honestly render the contents of a list-valued field in one line;
  /// - a nested `Map` never reaches here, because [_RecordCard] omits its row.
  ///
  /// A decoded JSON body carries only the cases above; anything else is shown
  /// as its own string rather than dropped, so an unexpected value degrades to
  /// something visible instead of an empty row.
  static String _valueText(Object? value, AppLocalizations l10n) {
    if (value == null) return l10n.recordNoValue;
    if (value is String) return value;
    if (value is bool) {
      return value ? l10n.recordBooleanTrue : l10n.recordBooleanFalse;
    }
    if (value is num) {
      if (value == value.truncateToDouble()) return value.truncate().toString();
      return value.toString();
    }
    if (value is List) return l10n.recordListValue(value.length);
    return value.toString();
  }
}

/// One label/value row of a record card.
///
/// Both halves share the row and both wrap: the layout never truncates a value
/// with an ellipsis, so the largest font scale grows the card instead of
/// clipping what the backend returned (`FR-MG06`, applied by `T24`). The two
/// `Expanded`s are what makes that hold at every text scale: there is no fixed
/// height anywhere in this row and no `TextOverflow` on either half, so the
/// worst case is a taller card, never a clipped word and never an overflow.
/// A long schema name such as `códigoPostal` therefore wraps inside its own
/// column instead of pushing the value out of the card.
class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.label,
    required this.value,
    required this.hasValue,
  });

  /// The field's schema name, in its original UML spelling (`FR-MC07`).
  final String label;

  /// The rendered value, or the "no value" copy.
  final String value;

  /// False when [value] is the "no value" copy rather than data, which is the
  /// one thing that changes its colour.
  final bool hasValue;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Text(
            label,
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          flex: 3,
          child: Text(
            value,
            style: textTheme.bodyMedium?.copyWith(
              color: hasValue ? AppColors.textPrimary : AppColors.textMuted,
            ),
          ),
        ),
      ],
    );
  }
}
