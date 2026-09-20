import 'package:flutter/material.dart';

import '../../conversation/pending_write.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/tokens.dart';

/// The Response focus band: what the conversation is asking for right now
/// (`FR-MC02`, `FR-MC03`; UX spec Pass 2 and Pass 3).
///
/// During slot filling and confirmation this area holds that and nothing else —
/// the question, or the read-back, is Primary; the draft captured so far sits
/// beneath it as Secondary; and while confirming, the read-back carries the two
/// controls, of unequal weight and with the committing one **not** pre-selected.
///
/// The question is deliberately not also an assistant turn: the conversation
/// list above keeps the history, `ConversationController` removes that turn
/// while a draft is in flight, and the exclusive surface is this one. It renders
/// nothing outside a write in progress, so an ordinary read never pays for it.
class ResponseFocus extends StatelessWidget {
  const ResponseFocus({
    super.key,
    required this.pending,
    required this.onConfirm,
    required this.onCancel,
  });

  /// The one draft in flight, as the controller holds it.
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
    final confirming = pending.phase == WritePhase.confirming;
    final asking = pending.asking;
    final captured = pending.requiredFields
        .where((field) => pending.values.containsKey(field.name))
        .toList();

    // `asking` is non-null for every collecting draft and null while
    // confirming. An empty headline is the unreachable case in between: the
    // draft renders alone instead of a stale question.
    final headline = confirming
        ? l10n.conversationWriteReadBackCreate(pending.entityName)
        : asking == null
        ? ''
        : l10n.conversationWriteAskField(asking.name);

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
                      pending.values[field.name] ?? '',
                    ),
                    style: textTheme.bodySmall,
                  ),
                ),
            ],
            if (confirming) ...[
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Unequal weight, and no autofocus anywhere: the committing
                  // control is never pre-selected (UX spec Pass 3). Voice
                  // confirmation is accepted as well, because the control
                  // submits the same utterance a person would say.
                  TextButton(
                    onPressed: onCancel,
                    child: Text(l10n.conversationWriteCancelAction),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton(
                    onPressed: onConfirm,
                    child: Text(l10n.conversationWriteConfirmAction),
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
