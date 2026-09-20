import 'package:flutter/material.dart';

import '../../conversation/pending_write.dart';
import '../../l10n/app_localizations.dart';
import '../../openapi/registry.dart';
import '../../theme/tokens.dart';

/// The Response focus band: what the conversation is asking for right now
/// (`FR-MC02`, `FR-MC03`, `FR-MC05`; UX spec Pass 2 and Pass 3).
///
/// During slot filling and confirmation this area holds that and nothing else —
/// the question, or the read-back, is Primary; the draft captured so far sits
/// beneath it as Secondary; and while confirming, the read-back carries the two
/// controls, of unequal weight and with the committing one **not** pre-selected.
///
/// **The escape route exists at every phase.** A create still collecting its
/// fields carries a single *Cancelar* control: the operator who changes their
/// mind can stop the draft at any point instead of having to finish the required
/// fields first, which is not a way out at all. The committing control is the
/// one that waits — *Confirmar* appears only once the record is complete and has
/// been read back (`FR-MC03`), and a draft that is not complete has nothing to
/// confirm.
///
/// It serves both writes (`T13`, `T13b`). A create is assembled, so it has a
/// question and a draft beneath it; a delete names one record and nothing else,
/// so it has only its read-back. Both are confirmed through the same two
/// controls.
///
/// The question is deliberately not also an assistant turn: the conversation
/// list above keeps the history, `ConversationController` removes that turn
/// while a write is in flight, and the exclusive surface is this one. It renders
/// nothing outside a write in progress, so an ordinary read never pays for it.
///
/// **The largest system font scale is a layout requirement here, not a
/// hope** (`FR-MG06`, applied by `T24`). Both controls carry two-word Spanish
/// labels at [AppTextSizes.chip] — *Cancelar* and *Confirmar* — and at the
/// scale's maximum a `Row` of the two of them overflows the band instead of
/// making room. They are therefore laid out in a `Wrap`: one line while they
/// fit, which is the whole comfortable range, and the second control on its own
/// line when they do not. Nothing here has a fixed height and no label is ever
/// ellipsised, so the band grows instead of clipping.
class ResponseFocus extends StatelessWidget {
  const ResponseFocus({
    super.key,
    required this.pending,
    required this.onConfirm,
    required this.onCancel,
  });

  /// The one write in flight, as the controller holds it.
  final PendingWrite pending;

  /// The two controls submit their own labels as ordinary utterances through
  /// `ConversationController`, so a confirmation spoken, typed or tapped takes
  /// exactly one path through the resolver.
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;

    // Which write the band is showing, in the three things it renders: the
    // headline, the draft and whether the confirmation is open. The sealed type
    // is switched on, so a third write would not compile until it were
    // handled here too.
    final headline = switch (pending) {
      // A delete restates the identity of its one target (`FR-MC05`).
      PendingDelete(:final entityName, :final recordId) =>
        l10n.conversationDeleteReadBack(recordId, entityName),

      // `asking` is non-null for every collecting create and null while
      // confirming. An empty headline is the unreachable case in between: the
      // draft renders alone instead of a stale question.
      PendingCreate(:final entityName, :final phase, :final asking) =>
        phase == WritePhase.confirming
            ? l10n.conversationWriteReadBackCreate(entityName)
            : asking == null
            ? ''
            : l10n.conversationWriteAskField(asking.name),
    };

    // The draft is a create's alone: a delete names one record and captures
    // nothing, so it has no draft to show (`FR-MC05`). It walks the create
    // body's fields, not only the required ones, so a field the operator
    // volunteered (`T13c`) appears here exactly like the ones that were asked
    // for, in schema order.
    final captured = switch (pending) {
      PendingDelete() => const <FieldDescriptor>[],
      PendingCreate(:final bodyFields, :final values) => bodyFields
          .where((field) => values.containsKey(field.name))
          .toList(),
    };

    // The captured text, in the same terms: empty for a delete for the same
    // reason.
    final capturedValues = switch (pending) {
      PendingDelete() => const <String, String>{},
      PendingCreate(:final values) => values,
    };

    // A delete is always waiting for its affirmative; a create once every
    // required field is captured (`FR-MC03`, `FR-MC05`).
    final confirming = switch (pending) {
      PendingDelete() => true,
      PendingCreate(:final phase) => phase == WritePhase.confirming,
    };

    // Whether the band is showing a draft that is still being collected. It is
    // the complement of [confirming] for a create and never true for a delete,
    // which has no fields to collect (`FR-MC05`).
    final collecting = switch (pending) {
      PendingDelete() => false,
      PendingCreate(:final phase) => phase == WritePhase.collecting,
    };

    return Semantics(
      container: true,
      // The band appears in response to the operator's own utterance, so it is
      // announced rather than silently replaced. T24 completes the
      // accessibility pass (`FR-MG03`, `FR-MG04`).
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadii.cardSmallAll,
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (headline.isNotEmpty)
              Text(headline, style: textTheme.titleMedium),
            if (captured.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                l10n.conversationWriteDraftHeading,
                style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
              const SizedBox(height: AppSpacing.xs),
              for (final field in captured)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: Text(
                    l10n.conversationWriteDraftLine(
                      field.name,
                      capturedValues[field.name] ?? '',
                    ),
                    style: textTheme.bodySmall,
                  ),
                ),
            ],
            if (confirming) ...[
              const SizedBox(height: AppSpacing.md),
              // Unequal weight, and no autofocus anywhere: the committing
              // control is never pre-selected (UX spec Pass 3). Voice
              // confirmation is accepted as well, because the control submits
              // the same utterance a person would say.
              //
              // A `Wrap` and not a `Row` for the font-scale rule stated on the
              // class: at the largest system text scale the committing label is
              // the wider of the two and it is the one that no longer fits
              // beside *Cancelar*. Wrapping keeps the order — so the committing
              // control stays last and stays second in the reading order — and
              // keeps both controls reachable with `FR-MG02`'s one hand.
              Wrap(
                alignment: WrapAlignment.end,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  TextButton(
                    onPressed: onCancel,
                    child: Text(l10n.conversationWriteCancelAction),
                  ),
                  FilledButton(
                    onPressed: onConfirm,
                    child: Text(l10n.conversationWriteConfirmAction),
                  ),
                ],
              ),
            ] else if (collecting) ...[
              // A collecting draft gets the one control that can always be
              // used and none of the one that cannot: *Cancelar* alone, so the
              // operator can refuse a draft that is not finished yet. The
              // committing control is deliberately absent — there is nothing
              // to confirm until the record is complete and read back
              // (`FR-MC03`) — and this control submits the same utterance a
              // person would say, exactly like its confirming counterpart.
              //
              // It stays a `Row` because a single control cannot overflow one:
              // the button's own label wraps inside whatever width the band
              // gives it (`FR-MG06`).
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: onCancel,
                    child: Text(l10n.conversationWriteCancelAction),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
