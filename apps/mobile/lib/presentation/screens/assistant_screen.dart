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
import '../widgets/response_focus.dart';
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
///
/// T12b made the list follow the newest turn. The answer is the point of the
/// turn, and a list that does not move leaves it below the fold: the operator
/// sees their own words and no reply, which reads as the app having done
/// nothing. `T13`'s read-back and confirmation, `T15`'s acknowledgement and
/// `T18`'s queue reports all land in the same list.
///
/// T13 added the Response focus band below the conversation: while a write
/// is being assembled it holds the one question, or the read-back of the
/// complete record with its two controls, and the draft captured so far. The
/// question is not also a turn — `ConversationController` drops the
/// assistant turn while a draft is in flight — so the screen shows it once.
///
/// T18 put the queue's count on the app bar. A non-zero queue is a promise the
/// app made and has not kept, so it is never hidden; an empty one costs zero
/// attention, so the badge is not drawn at all rather than drawn as a zero
/// (UX spec Pass 3 and Pass 5).
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  /// Drives the conversation list to its bottom (`T12b`).
  final ScrollController _conversationScroll = ScrollController();

  /// The last conversation state this screen followed, as `count|newest text`.
  ///
  /// The turn count alone is not enough: resolving a turn *replaces* the
  /// pending bubble with the answer, so the list does not grow at the one
  /// moment the operator is waiting for it (`T11`'s lifecycle). The newest
  /// turn's text changes exactly then, which is why it is part of the key.
  String _followedKey = '';

  @override
  void dispose() {
    _conversationScroll.dispose();
    super.dispose();
  }

  /// Scrolls to the newest turn whenever the conversation changed.
  ///
  /// The UX spec's Assistant composition is explicit — turns newest at the
  /// bottom, **auto-scrolled** — and without this an answer lands below the
  /// fold and stays invisible until the list is swiped by hand, which reads
  /// as the app having done nothing. A jump rather than an animation: motion
  /// in this app reports state and never decorates, and a jump cannot fight a
  /// scroll the operator started.
  void _followNewestTurn(String key) {
    if (key == _followedKey) return;
    _followedKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_conversationScroll.hasClients) return;
      _conversationScroll.jumpTo(
        _conversationScroll.position.maxScrollExtent,
      );
    });
  }

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
            // Pass 3: "a count badge that is only present when the count is
            // non-zero". `Badge.count` with `isLabelVisible` false draws the
            // child alone, so an empty queue leaves the app bar exactly as it
            // was — no dot, no zero. The number itself is the label, because a
            // badge that says "something is waiting" does not say how much is
            // owed.
            ListenableBuilder(
              listenable: conversation,
              builder: (context, _) => Badge.count(
                count: conversation.queuedCount,
                isLabelVisible: conversation.queuedCount > 0,
                child: IconButton(
                  icon: const Icon(Icons.inbox_outlined),
                  tooltip: l10n.queueTitle,
                  onPressed: () =>
                      Navigator.of(context).pushNamed(AppRoutes.queue),
                ),
              ),
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
                      // The key is the turn count plus the newest turn's text: the text is
                      // what changes when a pending turn settles into its answer, and the
                      // count is what changes when a turn is added. The call is registered
                      // after every build and does nothing unless the key changed; the jump
                      // itself runs post-frame, against a laid-out list, so
                      // `maxScrollExtent` is read at the only moment it is correct — at any
                      // font scale (`FR-MG06`).
                      final newestText = turns.isEmpty
                          ? ''
                          : switch (turns.last) {
                              UserTurn(:final text) => text,
                              AssistantTurn(:final text) => text,
                            };
                      _followNewestTurn('${turns.length}|$newestText');
                      return SingleChildScrollView(
                        controller: _conversationScroll,
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
                // Response focus (UX spec Pass 2 and Pass 3): during slot
                // filling and confirmation this area holds the question or the
                // read-back "and nothing else" — the draft beneath it, and,
                // while confirming, the two controls. It renders nothing outside
                // a write in progress, and the conversation list above keeps the
                // history, so the same question is never on screen twice.
                ListenableBuilder(
                  listenable: conversation,
                  builder: (context, _) {
                    final pending = conversation.pendingWrite;
                    if (pending == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.md),
                      child: ResponseFocus(
                        pending: pending,
                        onConfirm: conversation.confirmPendingWrite,
                        onCancel: conversation.cancelPendingWrite,
                      ),
                    );
                  },
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
/// is handled. Turn status is carried on [AssistantTurn] (`T14`):
/// [TurnStatus.queued] gets its own mark below, and the remaining states get
/// their visual treatment with the accessibility pass (`T24`, `FR-MG04`).
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
      AssistantTurn(:final text, :final status) => Align(
        alignment: Alignment.topLeft,
        child: _AssistantTurn(text: text, status: status),
      ),
    };
  }
}

/// One assistant turn. The user's bubbles invert to
/// [AppColors.userBubble]; assistant turns stay on the low-contrast surface.
///
/// A [TurnStatus.queued] turn marks itself with an icon **and** the word
/// `l10n.turnQueuedLabel` above its text, because the UX spec forbids carrying
/// this state in colour alone (`FR-MG04`), and gives the bubble a border so the
/// mark survives even for someone who does not read the icon. A queued turn
/// that looks like a result is the app lying about durability, which is the one
/// thing the queue exists to prevent (architecture §4).
class _AssistantTurn extends StatelessWidget {
  const _AssistantTurn({required this.text, required this.status});

  final String text;
  final TurnStatus status;

  @override
  Widget build(BuildContext context) {
    final queued = status == TurnStatus.queued;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadii.cardSmallAll,
        border: queued ? Border.all(color: AppColors.border) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (queued) ...[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.schedule_outlined,
                  size: 16,
                  color: AppColors.textMuted,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  AppLocalizations.of(context).turnQueuedLabel,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
          Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
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
