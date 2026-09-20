import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../conversation/turn.dart';
import '../../l10n/app_localizations.dart';
import '../../net/reachability.dart';
import '../../theme/tokens.dart';
import '../routes.dart';
import '../widgets/app_background.dart';
import '../widgets/capture_section.dart';
import '../widgets/reachability_indicator.dart';
import '../widgets/voice_status_banner.dart';

/// Assistant — the home screen (`FR-MG01`).
///
/// T1 laid out the shell: the app bar with its two destinations, the start of
/// the conversation, and the capture control in the bottom third.
///
/// T2 added the reachability state to the app bar: `FR-MA05` requires it
/// visible without navigating away from the conversation, and the app bar is
/// the one surface that never leaves.
///
/// T8 bound the capture control to the real voice engine (`CaptureSection`):
/// live amplitude, the live transcript, in-context microphone permission and
/// the text fallback.
///
/// T11 replaced the bare `List<String> _utterances` this screen used to hold
/// itself, plus the greeting's special case outside it, with
/// [AppServices.conversation]: the screen renders [ConversationController]'s
/// chronological turns and no longer keeps any state of its own. Resolving a
/// turn is still not this screen's job — `T12`/`T13` fill that in behind the
/// same [ConversationController].
class AssistantScreen extends StatelessWidget {
  const AssistantScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final connection = AppScope.of(context).connection;
    final voice = AppScope.of(context).voice;
    final conversation = AppScope.of(context).conversation;

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
                // FR-MB03: offline voice readiness is stated on the one screen
                // that never leaves the conversation, so an app that cannot
                // hear never looks like one that can. It renders nothing once
                // the recognizer is built and an offline Spanish voice pinned.
                const VoiceStatusBanner(),
                Expanded(
                  // Scrollable so the platform's largest font scale grows the
                  // turn instead of clipping it (`FR-MG06`).
                  child: ListenableBuilder(
                    // Both listenables matter here: `connection` decides the
                    // cannot-work gate below, `conversation` owns the turn
                    // list itself (`T11`) — including the greeting, which is
                    // now [turns].first rather than a special case rendered
                    // outside it.
                    listenable: Listenable.merge([connection, conversation]),
                    builder: (context, _) {
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
                      final turns = conversation.turns;
                      return SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var index = 0; index < turns.length; index++) ...[
                              if (index > 0)
                                const SizedBox(height: AppSpacing.sm),
                              _TurnBubble(turn: turns[index]),
                            ],
                          ],
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
                    return CaptureSection(
                      voice: voice,
                      onUtterance: conversation.submitUtterance,
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

/// Renders one [ConversationTurn], whichever kind it is.
///
/// The sealed hierarchy in `turn.dart` forces this `switch` to cover both
/// cases; adding a third turn kind later would fail to compile here until it
/// is handled. Turn status (`TurnStatus.pending` / `resolved` / `failed`) is
/// carried on [AssistantTurn] already but is not yet distinguished visually —
/// that lands with the accessibility pass (`T24`, `FR-MG04`), not here.
class _TurnBubble extends StatelessWidget {
  const _TurnBubble({required this.turn});

  final ConversationTurn turn;

  @override
  Widget build(BuildContext context) {
    return switch (turn) {
      UserTurn(:final text) => Align(
        alignment: Alignment.topRight,
        child: _UserTurn(text: text),
      ),
      AssistantTurn(:final text) => Align(
        alignment: Alignment.topLeft,
        child: _AssistantTurn(text: text),
      ),
    };
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

/// A turn produced by the user, whether spoken or typed through the text
/// fallback (`FR-MB06`): both paths feed
/// [ConversationController.submitUtterance] and render identically here,
/// because capture does not care which one produced the utterance.
class _UserTurn extends StatelessWidget {
  const _UserTurn({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: const BoxDecoration(
        color: AppColors.userBubble,
        borderRadius: AppRadii.cardSmallAll,
      ),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: AppColors.onUserBubble),
      ),
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
