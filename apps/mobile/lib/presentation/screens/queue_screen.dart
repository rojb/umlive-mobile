import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/tokens.dart';
import '../widgets/app_background.dart';

/// Queue (`FR-MG01`): the pending outbox.
///
/// T1 renders the empty state only. An empty queue costs zero attention, so
/// there is nothing here but the statement that there is nothing here — the
/// pending list, per-item cancel and failure reasons arrive with T18.
class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(l10n.queueTitle)),
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Icon plus text, never one without the other.
                const Icon(
                  Icons.inbox_outlined,
                  size: AppSizes.minTouchTarget,
                  color: AppColors.textMuted,
                ),
                const SizedBox(height: AppSpacing.md),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xl,
                  ),
                  child: Text(
                    l10n.queueEmpty,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
