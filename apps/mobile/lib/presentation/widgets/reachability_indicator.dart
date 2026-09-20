import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../l10n/app_localizations.dart';
import '../../net/reachability.dart';
import '../../theme/tokens.dart';
import '../connection_controller.dart';

/// The reachability state of `FR-MA05`, always rendered as **icon + text**.
///
/// Colour is decoration here, never the signal: every state carries its own
/// icon, its own short label and its own sentence, so the states stay
/// distinguishable in greyscale and for a screen reader (`FR-MG04`).
class ReachabilityIndicator extends StatelessWidget {
  const ReachabilityIndicator({super.key, this.compact = false});

  /// Compact renders the short label in a pill, for the Assistant app bar;
  /// the full form renders label plus sentence.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final connection = AppScope.of(context).connection;
    return ListenableBuilder(
      listenable: connection,
      builder: (context, _) {
        final view = ReachabilityView.of(context, connection);
        return Tooltip(
          message: view.sentence,
          child: compact ? _Pill(view: view) : _Block(view: view),
        );
      },
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.view});

  final ReachabilityView view;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 168),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.pillAll,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(view.icon, size: 18, color: view.color),
          const SizedBox(width: AppSpacing.xs),
          Flexible(
            child: Text(
              view.label,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.view});

  final ReachabilityView view;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.cardSmallAll,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(view.icon, color: view.color),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(view.label, style: textTheme.labelLarge),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  view.sentence,
                  style: textTheme.bodySmall?.copyWith(
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One reachability state, resolved to its icon, label and sentence.
class ReachabilityView {
  const ReachabilityView({
    required this.icon,
    required this.label,
    required this.sentence,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String sentence;

  /// Supplementary only. The state is already legible without it.
  final Color color;

  static ReachabilityView of(
    BuildContext context,
    ConnectionController connection,
  ) {
    final l10n = AppLocalizations.of(context);
    if (connection.isProbing) {
      return ReachabilityView(
        icon: Icons.hourglass_top_outlined,
        label: l10n.reachabilityProbingLabel,
        sentence: l10n.reachabilityProbingSentence,
        color: AppColors.textMuted,
      );
    }
    final probe = connection.lastProbe;
    switch (connection.reachability) {
      case ReachabilityState.neverConnected:
        return ReachabilityView(
          icon: Icons.link_off_outlined,
          label: l10n.reachabilityNeverConnectedLabel,
          sentence: l10n.reachabilityNeverConnectedSentence,
          color: AppColors.textMuted,
        );
      case ReachabilityState.connected:
        return ReachabilityView(
          icon: Icons.cloud_done_outlined,
          label: l10n.reachabilityConnectedLabel,
          sentence: l10n.reachabilityConnectedSentence,
          color: AppColors.success,
        );
      case ReachabilityState.missingDescription:
        return ReachabilityView(
          icon: Icons.description_outlined,
          label: l10n.reachabilityMissingDescriptionLabel,
          sentence: l10n.reachabilityMissingDescriptionSentence,
          color: AppColors.danger,
        );
      case ReachabilityState.reachableButUnhealthy:
        final status = probe?.statusCode;
        return ReachabilityView(
          icon: Icons.warning_amber_outlined,
          label: l10n.reachabilityUnhealthyLabel,
          sentence: status == null
              ? l10n.reachabilityUnhealthyNoStatusSentence
              : l10n.reachabilityUnhealthySentence(status),
          color: AppColors.danger,
        );
      case ReachabilityState.offlineWithCache:
        return ReachabilityView(
          icon: Icons.offline_pin_outlined,
          label: l10n.reachabilityOfflineWithCacheLabel,
          sentence: l10n.reachabilityOfflineWithCacheSentence,
          color: AppColors.accent,
        );
      case ReachabilityState.unreachable:
        return ReachabilityView(
          icon: Icons.cloud_off_outlined,
          label: l10n.reachabilityUnreachableLabel,
          sentence: l10n.reachabilityUnreachableSentence,
          color: AppColors.danger,
        );
    }
  }
}
