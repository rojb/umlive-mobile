import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/tokens.dart';
import '../routes.dart';
import '../widgets/app_background.dart';
import '../widgets/glow_orb.dart';

/// Assistant — the home screen (`FR-MG01`).
///
/// T1 lays out the shell only: the app bar with its two destinations, the start
/// of the conversation, and the capture control in the bottom third. The control
/// is deliberately inert and captioned as unavailable, because a listening
/// visual over a closed microphone is a correctness bug (`FR-MG05`).
class AssistantScreen extends StatelessWidget {
  const AssistantScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(l10n.appTitle),
          actions: [
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
                Expanded(
                  // Scrollable so the platform's largest font scale grows the
                  // turn instead of clipping it (`FR-MG06`).
                  child: SingleChildScrollView(
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: _AssistantTurn(text: l10n.assistantGreeting),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Semantics(
                  label: l10n.captureOrbSemantics,
                  child: Column(
                    children: [
                      // Amplitude 0, microphone closed: static and dim until T8
                      // binds the control to the real input level.
                      const GlowOrb(),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        l10n.captureUnavailableCaption,
                        textAlign: TextAlign.center,
                        style: textTheme.bodySmall,
                      ),
                    ],
                  ),
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
