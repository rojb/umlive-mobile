import 'package:flutter/material.dart';

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
class RecordCards extends StatelessWidget {
  const RecordCards({super.key, required this.result});

  /// What the read returned: the records, and the entity's readable fields in
  /// response-schema order.
  final TurnResult result;

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < shown; index++) ...[
          if (index > 0) const SizedBox(height: AppSpacing.sm),
          _RecordCard(record: records[index], fields: result.fields),
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
class _RecordCard extends StatelessWidget {
  const _RecordCard({required this.record, required this.fields});

  /// The decoded JSON object, exactly as the backend returned it.
  final Map<String, Object?> record;

  /// The entity's readable fields, in response-schema order.
  final List<FieldDescriptor> fields;

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

      rows.add(
        _FieldRow(
          label: field.name,
          value: _valueText(value, l10n),
          // An absent key and a `null` are both "no value" and share the muted
          // treatment, so the card reads the same whichever the backend sent.
          hasValue: value != null,
        ),
      );
    }

    // Every field was a nested object: there is nothing a card can say about
    // this record without printing JSON.
    if (rows.isEmpty) return const SizedBox.shrink();

    return Container(
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
/// clipping what the backend returned (`FR-MG06`, checked by `T24`).
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
