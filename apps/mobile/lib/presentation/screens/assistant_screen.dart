import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../conversation/turn.dart';
import '../../l10n/app_localizations.dart';
import '../../net/reachability.dart';
import '../../theme/tokens.dart';
import '../discovered_scope.dart';
import '../routes.dart';
import '../widgets/app_background.dart';
import '../widgets/capture_section.dart';
import '../widgets/glow_orb.dart';
import '../widgets/reachability_indicator.dart';
import '../widgets/record_cards.dart';
import '../widgets/response_focus.dart';
import '../widgets/technical_details.dart';
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
///
/// T23 put the technical block under a turn, behind the operator's own toggle
/// (`FR-ME06`). It is not a second screen and not a debug build: it is the same
/// conversation read by the Author and the Evaluator, which is why the toggle
/// lives in Settings and the block appears under the turns that are already on
/// screen the moment it is flipped.
///
/// The capture control's **speaking** state is drawn in this screen's own corner
/// (`T26`, `FR-MG03`). While the assistant talks, the composer below stays
/// exactly as it is when idle and a small orb appears in the bottom-right of
/// the conversation area. It is a `Positioned` inside a `Stack` over the turn
/// list on purpose: an indicator
/// that pushed the turns it describes would move the answer the operator is
/// reading, and the corner it takes is the empty right margin of a left-aligned
/// assistant answer. The orb is the same widget as the listening one at a
/// smaller size, so the speaking motion is one implementation and not two.
///
/// One precedence rule keeps the two indicators from ever doubling: this corner
/// orb renders only while the assistant speaks **and** the microphone is closed.
/// If the assistant starts speaking while the microphone is open, the orb in the
/// composer's place takes the speaking motion — `GlowOrb` gives speaking
/// precedence — and no second indicator is drawn.
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
                  child: Stack(
                    // The small orb's halo is painted outside its box, and
                    // clipping it would turn the glow this design language is
                    // built on into a hard edge.
                    clipBehavior: Clip.none,
                    children: [
                      // Scrollable so the platform's largest font scale grows the
                      // turn instead of clipping it (`FR-MG06`).
                      Positioned.fill(
                        child: ListenableBuilder(
                          // Both listenables matter here: `connection` decides the
                          // cannot-work gate below, `conversation` owns the turn
                          // list itself (`T11`) — including the greeting, which
                          // is now [turns].first rather than a special case
                          // rendered outside it.
                          listenable: Listenable.merge([connection, conversation]),
                          builder: (context, _) {
                            final registry = connection.apiRegistry;
                            if (registry == null && !connection.isProbing) {
                              // Pass 6, first launch offline with no cached
                              // registry: say plainly that it has never connected
                              // and cannot work yet. A conversation surface that
                              // can only fail is worse than none, so none is
                              // drawn.
                              return _CannotWork(
                                text: l10n.assistantCannotWork,
                                actionLabel: l10n.assistantOpenConnect,
                                onAction: () => Navigator.of(
                                  context,
                                ).pushNamed(AppRoutes.connect),
                              );
                            }
                            final turns = conversation.turns;
                            // The key is the turn count plus the newest turn's
                            // text: the text is what changes when a pending turn
                            // settles into its answer, and the count is what
                            // changes when a turn is added. The call is
                            // registered after every build and does nothing
                            // unless the key changed; the jump itself runs
                            // post-frame, against a laid-out list, so
                            // `maxScrollExtent` is read at the only moment it is
                            // correct — at any font scale (`FR-MG06`).
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
                                  for (
                                    var index = 0;
                                    index < turns.length;
                                    index++
                                  ) ...[
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
                      // The speaking state, in the conversation's corner. It
                      // never shifts the list, and it is not drawn while the
                      // microphone is open: in that state the orb in the
                      // composer's place is the one indicator, and it wears the
                      // speaking motion itself.
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: ListenableBuilder(
                          listenable: voice,
                          builder: (context, _) =>
                              voice.isSpeaking && !voice.isListening
                              ? _SpeakingCornerOrb(
                                  label: l10n.captureOrbSemanticsSpeaking,
                                  onTap: () => voice.stopSpeaking(),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ],
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

/// The assistant's speaking state, said in the conversation's own corner
/// (`T26`, `FR-MG03`).
///
/// It is the same [GlowOrb] the listening state uses, at [AppSizes.speakingOrb]
/// instead of [AppSizes.orb]: the motion is one implementation and only the size
/// changes. The two numbers are deliberately different — a 38 dp circle is below
/// the Material floor for a control, so the orb sits inside a
/// [AppSizes.minTouchTarget]-sized box: the eye reads the size the owner asked
/// for, the finger gets the 48 dp a touch needs. `HitTestBehavior.opaque` makes
/// that whole 48 dp square the target and not only the painted circle inside it.
///
/// **The visible indicator is the motion plus the position, and the label is
/// what keeps the state announced** (`FR-MG03`). The owner asked for the written
/// `Hablando…` caption beside the orb to be removed; what remains on the screen is
/// the clock-driven pulse in the conversation's bottom-right corner, and
/// [AppLocalizations.captureOrbSemanticsSpeaking] says the same state to a screen
/// reader. The big orb in the composer's place keeps its own written caption for
/// the one state where that orb takes the speaking motion.
///
/// **The control is activatable, not merely announced.** The node is a real
/// button: `onTap` and `button` are set on the semantics itself, so a screen
/// reader can stop the speech. A state a screen-reader user can hear but cannot
/// act on would be a voice action with no touch equivalent for that user, which
/// is exactly what `FR-MG03` forbids. The label sits on this one node and the
/// child visual is excluded, so the state is announced once and not twice.
class _SpeakingCornerOrb extends StatelessWidget {
  const _SpeakingCornerOrb({required this.label, required this.onTap});

  /// Screen-reader label: it names the state and what a tap does, the same way
  /// the orb in the composer's place does while the microphone is open.
  final String label;

  /// Stops the speech. It never opens the microphone: the tap reaches
  /// `VoiceController.stopSpeaking` directly, and no capture path is behind it.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // One label, one node: `excludeSemantics` drops the child visual so the
      // state cannot be announced twice, and `onTap` + `button` are what turn
      // this from a label a screen-reader user can only listen to into the
      // control they can activate.
      container: true,
      excludeSemantics: true,
      button: true,
      label: label,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // The 48 dp hit area around the 38 dp visual: the box is the target,
        // the circle inside it is what the owner asked to see.
        child: const SizedBox.square(
          dimension: AppSizes.minTouchTarget,
          child: Center(
            child: GlowOrb(size: AppSizes.speakingOrb, speaking: true),
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
/// is handled.
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
      AssistantTurn(
        :final text,
        :final status,
        :final result,
        :final evidence,
      ) =>
        Align(
          alignment: Alignment.topLeft,
          child: _AssistantTurn(
            text: text,
            status: status,
            result: result,
            evidence: evidence,
          ),
        ),
    };
  }
}

/// One assistant turn. The user's bubbles invert to
/// [AppColors.userBubble]; assistant turns stay on the low-contrast surface.
///
/// **The turn typology, and why every marked kind carries a word** (`T24`,
/// `FR-MG04`). The UX spec fixes five kinds of turn — the *user utterance* (the
/// inverted bubble, which needs no mark: it is the operator's own words), the
/// *assistant answer* (this bubble, plain), the *result card group* (the cards
/// below the bubble), the *queued promise*, and the *not-understood* refusal —
/// and requires them to stay distinguishable **without colour**: Pass 1 says the
/// three outcomes "never share a visual treatment", and the visual constraints
/// say the three states must be distinguishable "without colour alone". Colour
/// is therefore never the signal. A [TurnStatus.queued] turn marks itself with a
/// schedule icon **and** the word `l10n.turnQueuedLabel`, plus a hairline border;
/// a [TurnStatus.failed] turn marks itself with an error icon **and** the word
/// `l10n.turnFailedLabel`. Read the three outcomes in greyscale and they still
/// separate: *En cola*, the answer, *Falló*. A queued turn that looks like a
/// result is the app lying about durability, which is the one thing the queue
/// exists to prevent (architecture §4), and the failed turn rendered as
/// **nothing at all** until `T24` — the state was carried by the sentence alone
/// and by no mark a person could scan for.
///
/// `T21` renders the turn's [TurnResult] as cards **below the bubble and
/// outside it**: the bubble is the assistant's voice, and a record card is the
/// backend's own data (`FR-ME03`). The two stay left-aligned so the answer
/// reads as one block, and the sentence keeps owning the count while the cards
/// own the records (`T20`).
///
/// `T23` renders the turn's [OperationEvidence] last, under the sentence and
/// under the cards, and only while the operator's technical mode is on. The
/// block is gated by a [ListenableBuilder] on the mode itself, so flipping the
/// toggle redraws exactly these blocks and nothing else on the screen. A turn
/// with no evidence — the greeting, a refusal, an utterance that never reached
/// an operation — gets no block at all, because there would be nothing true to
/// put in it.
class _AssistantTurn extends StatelessWidget {
  const _AssistantTurn({
    required this.text,
    required this.status,
    this.result,
    this.evidence,
  });

  final String text;
  final TurnStatus status;

  /// The records this read returned, or null for every turn that is not a
  /// successful or cache-served read.
  final TurnResult? result;

  /// What the call this turn made actually was, or null when no call was made.
  final OperationEvidence? evidence;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final queued = status == TurnStatus.queued;
    final records = result;
    final technical = evidence;
    // The mark a settled non-answer carries, as the pair the typology asks for:
    // a word and the icon that word belongs to. An ordinary answer gets `null`,
    // because it is the kind that needs no word above its sentence, and a
    // pending turn carries its own caption instead.
    final (IconData, String)? mark = switch (status) {
      TurnStatus.queued => (Icons.schedule_outlined, l10n.turnQueuedLabel),
      TurnStatus.failed => (Icons.error_outline, l10n.turnFailedLabel),
      TurnStatus.pending || TurnStatus.resolved => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
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
              if (mark != null) ...[
                _TurnStatusMark(icon: mark.$1, label: mark.$2),
                const SizedBox(height: AppSpacing.xs),
              ],
              Text(text, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
        if (records != null && records.records.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          // The group's label needs the entity's own word, and the registry is
          // the only place one comes from (`FR-MC07`). `T24` resolves it here,
          // the same way the queue screen resolves the word for an item's own
          // label, rather than teaching the card widget to read the registry.
          RecordCards(
            result: records,
            entityName: _entityNameFor(context, technical),
          ),
        ],
        // T23: the machinery, under the sentence and under the cards, and only
        // while the operator asked for it. The builder listens to the mode
        // itself rather than the screen listening for the block, so toggling
        // it re-renders the conversation's blocks and nothing else.
        if (technical != null) ...[
          const SizedBox(height: AppSpacing.sm),
          ListenableBuilder(
            listenable: AppScope.of(context).technicalMode,
            builder: (context, _) =>
                AppScope.of(context).technicalMode.enabled
                ? TechnicalDetails(evidence: technical)
                : const SizedBox.shrink(),
          ),
        ],
      ],
    );
  }

  /// The entity whose `operationKeys` carries [evidence]'s operation, in the
  /// registry's own sentence-case spelling, or null when it cannot be named.
  ///
  /// The same lookup the queue screen performs for an item's own label, and the
  /// same limit: null means no entity of the **current** registry publishes that
  /// operation any more, and an entity word the registry cannot supply is never
  /// invented (`FR-MC07`). It is a free read — `T21`'s evidence was captured
  /// when the call was made, and the registry is the object this screen already
  /// listens to.
  static String? _entityNameFor(
    BuildContext context,
    OperationEvidence? evidence,
  ) {
    final operationKey = evidence?.operationKey;
    if (operationKey == null) return null;
    final registry = AppScope.of(context).connection.apiRegistry;
    if (registry == null) return null;
    for (final entity in registry.entities) {
      if (entity.operationKeys.contains(operationKey)) {
        return lowerFirst(entity.name);
      }
    }
    return null;
  }
}

/// The mark a queued or failed turn carries above its sentence: an outline icon
/// **and** a word (`T24`, `FR-MG04`).
///
/// One widget for both, because the rule is one rule: a state that is only a
/// hue is a state a colour-blind operator cannot read, and the two states that
/// are not an answer carry the two words the app already has for them — *En
/// cola* and *Falló*. See [_AssistantTurn] for the whole typology.
///
/// **The colour is deliberately [AppColors.textMuted] for both marks, and it is
/// supplementary.** [TurnStatus.failed] covers a real failure and an honest
/// refusal alike — the resolver settles both as `failed` — and the UX spec gives
/// the not-understood treatment "neither an error red nor a normal answer". A
/// red word would claim the app knows which of the two this is, and it does not
/// need to: the word and the icon already say it, in greyscale.
///
/// The semantics node carries **the word alone**. The icon is decorative and
/// carries no label, and without [Semantics.excludeSemantics] the word would be
/// announced twice — once as this node's label and once by the text inside it —
/// which is the one place the accessibility layer would have heard it doubled.
class _TurnStatusMark extends StatelessWidget {
  const _TurnStatusMark({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: AppTextSizes.chip, color: AppColors.textMuted),
          const SizedBox(width: AppSpacing.sm),
          // Flexible and wrapping, never an ellipsis: the largest system font
          // scale must be able to grow this mark onto a second line rather than
          // clip the word that carries the whole state (`FR-MG06`).
          Flexible(
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: AppColors.textMuted),
            ),
          ),
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
