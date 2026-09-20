import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../l10n/app_localizations.dart';
import '../../net/reachability.dart';
import '../../theme/tokens.dart';
import '../discovered_scope.dart';
import '../routes.dart';
import '../widgets/app_background.dart';
import '../widgets/glow_orb.dart';
import '../widgets/reachability_indicator.dart';

/// Assistant — the home screen (`FR-MG01`).
///
/// T1 lays out the shell only: the app bar with its two destinations, the start
/// of the conversation, and the capture control in the bottom third. The control
/// is deliberately inert and captioned as unavailable, because a listening
/// visual over a closed microphone is a correctness bug (`FR-MG05`).
///
/// T2 adds the reachability state to the app bar: `FR-MA05` requires it visible
/// without navigating away from the conversation, and the app bar is the one
/// surface that never leaves.
class AssistantScreen extends StatelessWidget {
  const AssistantScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final connection = AppScope.of(context).connection;

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(l10n.appTitle),
          actions: [
            const Padding(
              padding: EdgeInsets.only(right: AppSpacing.sm),
              child: Center(child: ReachabilityIndicator(compact: true)),
            ),
            IconButton(
              icon: const Icon(Icons.inbox_outlined),
              tooltip: l10n.queueTitle,
              onPressed: () =>
                  Navigator.of(context).pushNamed(AppRoutes.queue),
            ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: l10n.settingsTitle,
              onPressed: () =>
                  Navigator.of(context).pushNamed(AppRoutes.settings),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The pill in the app bar carries the short label; anything but
                // a healthy connection also gets its full sentence here, so the
                // state is never only an abbreviation.
                ListenableBuilder(
                  listenable: connection,
                  builder: (context, _) =>
                      connection.reachability == ReachabilityState.connected &&
                          !connection.isProbing
                      ? const SizedBox.shrink()
                      : const Padding(
                          padding: EdgeInsets.only(top: AppSpacing.sm),
                          child: ReachabilityIndicator(),
                        ),
                ),
                Expanded(
                  // Scrollable so the platform's largest font scale grows the
                  // turn instead of clipping it (`FR-MG06`).
                  child: ListenableBuilder(
                    listenable: connection,
                    builder: (context, _) {
                      // T3/T4: the greeting states the discovered scope in
                      // domain terms (`FR-MC07`). The registry it reads is the
                      // cached one when the backend did not answer (`FR-MA04`).
                      final registry = connection.apiRegistry;
                      if (registry == null && !connection.isProbing) {
                        // Pass 6, first launch offline with no cached registry:
                        // say plainly that it has never connected and cannot
                        // work yet. A conversation surface that can only fail
                        // is worse than none, so none is drawn.
                        return _CannotWork(
                          text: l10n.assistantCannotWork,
                          actionLabel: l10n.assistantOpenConnect,
                          onAction: () => Navigator.of(
                            context,
                          ).pushNamed(AppRoutes.connect),
                        );
                      }
                      final greeting = registry == null
                          ? l10n.assistantGreeting
                          : scopeGreeting(l10n, registry);
                      return SingleChildScrollView(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: _AssistantTurn(text: greeting),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                // A description that parsed but declares no operation is workable
                // for nothing: the greeting says so and the capture control stays
                // out of the way, instead of presenting a surface that can only
                // fail (Pass 6).
                ListenableBuilder(
                  listenable: connection,
                  builder: (context, _) {
                    // No registry, or one that declares no operation: there is
                    // nothing to capture for, so the control is not drawn.
                    if (!connection.hasWorkableRegistry) {
                      return const SizedBox.shrink();
                    }
                    return Semantics(
                      label: l10n.captureOrbSemantics,
                      child: Column(
                        children: [
                          // Amplitude 0, microphone closed: static and dim until
                          // T8 binds the control to the real input level.
                          const GlowOrb(),
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            l10n.captureUnavailableCaption,
                            textAlign: TextAlign.center,
                            style: textTheme.bodySmall,
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: AppSpacing.xl),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One assistant turn. The user's bubbles invert to
/// [AppColors.userBubble]; assistant turns stay on the low-contrast surface.
class _AssistantTurn extends StatelessWidget {
  const _AssistantTurn({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.cardSmallAll,
      ),
      child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}

/// Pass 6, flow integrity: the app states plainly that it cannot work yet, and
/// offers the one action that changes that. It draws no conversation surface,
/// because a control that can only fail is worse than no control.
class _CannotWork extends StatelessWidget {
  const _CannotWork({
    required this.text,
    required this.actionLabel,
    required this.onAction,
  });

  final String text;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: AppRadii.cardSmallAll,
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.cloud_off_outlined, color: AppColors.textMuted),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(text, style: textTheme.bodyMedium),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
    );
  }
}
