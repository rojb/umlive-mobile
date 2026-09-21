import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../voice/microphone_capture.dart';
import '../../voice/voice_controller.dart';
import 'glow_orb.dart';
import 'live_transcript_view.dart';

/// The capture control, the live transcript and the text fallback, together
/// (`FR-MB04`, `FR-MB05`, `FR-MB06`, `FR-MG05`).
///
/// This is the one place the app asks for the microphone. `FR-MB04` is a
/// measured requirement, not a hypothetical one: T7 found the permission
/// dialog silently blocking a background step for 150 s, with nothing on
/// screen explaining why. The fix here is structural, not cosmetic:
/// - the explanation is always on screen (and spoken) *before* a request is
///   made, never after;
/// - the request itself only ever happens inside this widget's own tap
///   handler, never from a background `initialize()`-style call;
/// - a permanently-denied permission is detected and never re-prompted —
///   Android returns `denied` with no dialog for that case, which from the
///   app's side is indistinguishable from a hang unless it is told apart.
///
/// [VoiceController] owns every piece of state this widget reads
/// (readiness, permission, listening, speaking, amplitude); the only state kept
/// here is the transient "is a tap in flight" flag and the text field's own
/// buffer. That buffer is kept here, above the state branch below, for one
/// reason: the listening state hides the composer, and the composer has to come
/// back with the text it already held instead of an empty one.
///
/// The control carries three states, and each one says which it is in words
/// (`FR-MG03`, `FR-MG04`):
///
/// - **idle** — the composer: the instruction field with its send icon and, in
///   the same trailing row, the microphone icon. **There is no orb at rest.**
///   An animation on screen while the microphone is closed reads as "it is
///   hearing me", which is the correctness bug `FR-MG05` names, and the same
///   rule is what makes an ordinary field with a small icon on it the honest
///   resting shape of this control (`FR-MG02`).
/// - **listening** — the field and both its icons give way to [GlowOrb] in the
///   amplitude-driven listening motion (`FR-MG05`), and a tap on the orb ends
///   the capture. The composer returns exactly as it was — same field, same
///   icons, same text — because nothing in this state owns the field.
/// - **speaking** — the assistant is talking. The composer is back, and the
///   speaking state is drawn as a small orb in the conversation's own corner, by
///   `AssistantScreen`, because that corner is where the answer arrives and the
///   one thing the operator wants while it lasts is to stop it. This state is a
///   control state and not only a decoration: a tap during speech stops the
///   speech and never opens the microphone, because a microphone opened under
///   the speaker would hear the assistant and feed it back into the
///   conversation.
class CaptureSection extends StatefulWidget {
  const CaptureSection({
    super.key,
    required this.voice,
    required this.onUtterance,
  });

  final VoiceController voice;

  /// Called with the final text once the microphone finishes an utterance, or
  /// once the text fallback is submitted. Both paths produce exactly the same
  /// kind of value — a plain utterance string. Resolving it is Phase C's job,
  /// not this widget's: T8 is capture only.
  final ValueChanged<String> onUtterance;

  @override
  State<CaptureSection> createState() => _CaptureSectionState();
}

class _CaptureSectionState extends State<CaptureSection>
    with WidgetsBindingObserver {
  final TextEditingController _textController = TextEditingController();
  bool _busy = false;
  bool _captureFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A non-prompting read: safe on build, and it is how a permanently-denied
    // install shows the settings caption immediately instead of only after a
    // wasted tap.
    unawaited(widget.voice.refreshMicrophonePermission());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Catches a grant made from system Settings after the permanently-denied
    // path sent the user there — nothing else would ever re-check.
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.voice.refreshMicrophonePermission());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final voice = widget.voice;

    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) {
        // One branch, two screens: the microphone is either closed — and the
        // control is the composer — or open, and the control is the orb. Both
        // are built from the controller's state on every notification, and the
        // field's buffer lives above this builder, so the branch changes nothing
        // the operator had typed.
        return Column(
          children: [
            if (voice.isListening)
              _listeningControl(voice, l10n)
            else
              _composer(voice, l10n),
          ],
        );
      },
    );
  }

  /// The idle composer: the instruction field, its two trailing icons, and
  /// whatever the voice state has to say above them.
  ///
  /// The microphone lives in the field's own trailing row, beside the send icon,
  /// because dictation is the typed instruction's alternative rather than a
  /// separate surface. There is no orb here: the microphone is a small icon on a
  /// field, which is what an application that is not hearing anything looks like
  /// (`FR-MG05`).
  Widget _composer(VoiceController voice, AppLocalizations l10n) {
    final textTheme = Theme.of(context).textTheme;
    final ready = voice.readiness == VoiceReadiness.ready;
    final permission = voice.microphonePermission;

    final String microphoneLabel;
    final bool microphoneEnabled;
    final bool showSettingsAction;
    final String? caption;

    if (!ready) {
      // The engine cannot hear yet: the tap is refused and the label carries the
      // reason, which is what the orb used to say in this same state. The
      // readiness banner above states the detailed cause and the field keeps the
      // typed path open (FR-MB06).
      microphoneLabel = l10n.captureMicrophoneUnavailable;
      microphoneEnabled = false;
      showSettingsAction = false;
      caption = l10n.captureUnavailableCaption;
    } else if (voice.isSpeaking) {
      // The assistant is talking. The microphone permission is not an input
      // here on purpose: the state is about the speaker, and the one useful
      // action is to silence it — without opening the microphone, which
      // `_onCaptureTap` enforces before it reaches any capture code.
      microphoneLabel = l10n.captureOrbSemanticsSpeaking;
      microphoneEnabled = true;
      showSettingsAction = false;
      caption = null;
    } else if (permission == MicrophonePermission.permanentlyDenied) {
      microphoneLabel = l10n.captureMicrophonePermissionBlocked;
      microphoneEnabled = false;
      showSettingsAction = true;
      caption = l10n.microphonePermissionPermanentlyDeniedCaption;
    } else if (permission != MicrophonePermission.granted) {
      // FR-MB04: the permission is explained in writing, and spoken, before it
      // is asked for, and the ask itself only ever happens in this tap handler.
      // The icon stays armed for exactly that reason: disabling it would take
      // away the only path that can grant the microphone.
      microphoneLabel = l10n.captureMicrophonePermissionNeeded;
      microphoneEnabled = true;
      showSettingsAction = false;
      caption = l10n.microphonePermissionRationale;
    } else if (_captureFailed) {
      microphoneLabel = l10n.captureMicrophoneLabel;
      microphoneEnabled = true;
      showSettingsAction = false;
      caption = l10n.microphoneCaptureFailedCaption;
    } else {
      microphoneLabel = l10n.captureMicrophoneLabel;
      microphoneEnabled = true;
      showSettingsAction = false;
      caption = null;
    }

    final String? captionText = caption;
    return Column(
      children: [
        if (captionText != null) ...[
          Text(
            captionText,
            textAlign: TextAlign.center,
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (showSettingsAction) ...[
          OutlinedButton(
            onPressed: () => voice.openMicrophoneSettings(),
            child: Text(l10n.microphonePermissionOpenSettings),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        // FR-MB06: every voice action has a typed equivalent, always
        // available — including, and especially, while the microphone is
        // denied.
        _TextFallback(
          controller: _textController,
          microphoneLabel: microphoneLabel,
          // A tap already in flight is not tappable again: starting the
          // microphone and asking for the permission are both asynchronous, and
          // the double tap this refuses is the double capture T26's busy flag
          // was added for.
          microphoneTap: microphoneEnabled && !_busy
              ? () => _onCaptureTap(voice, l10n)
              : null,
          onSubmit: _submitText,
        ),
      ],
    );
  }

  /// The listening state: the composer's place, taken by the orb (`FR-MG02`).
  ///
  /// The field and both its icons are hidden while the microphone is open, so
  /// the screen holds exactly one control and the orb is it. The orb is the way
  /// out of the state: a tap ends the capture, which is the same path any other
  /// end of the capture takes, so the composer comes back the way it left.
  Widget _listeningControl(VoiceController voice, AppLocalizations l10n) {
    final textTheme = Theme.of(context).textTheme;
    // The orb's own precedence, followed here too: if the assistant starts
    // speaking while the microphone is open, [GlowOrb] draws the speaking
    // motion, and the tap below stops that speech rather than the capture — the
    // same order `_onCaptureTap` walks.
    final speaking = voice.isSpeaking;
    return Column(
      children: [
        Semantics(
          label: speaking
              ? l10n.captureOrbSemanticsSpeaking
              : l10n.captureOrbSemanticsListening,
          button: true,
          child: GestureDetector(
            onTap: _busy ? null : () => _onCaptureTap(voice, l10n),
            child: ValueListenableBuilder<double>(
              valueListenable: voice.amplitude,
              builder: (context, level, _) => GlowOrb(
                amplitude: level,
                listening: true,
                speaking: speaking,
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (speaking)
          // FR-MG03: the state the motion shows is also written. The transcript
          // would describe the wrong fact here, and the small corner orb that
          // carries this caption in the idle composer is deliberately not drawn
          // while the microphone is open, so the caption belongs under this orb.
          Text(
            l10n.captureSpeakingCaption,
            textAlign: TextAlign.center,
            style: textTheme.bodySmall,
          )
        else
          ListenableBuilder(
            listenable: voice.transcriber!,
            builder: (context, _) => LiveTranscriptView(
              transcript: voice.transcript,
              emptyLabel: l10n.captureListeningCaption,
            ),
          ),
      ],
    );
  }

  /// The one tap handler this control has, reached from the microphone icon in
  /// the composer and from the orb while the microphone is open.
  Future<void> _onCaptureTap(
    VoiceController voice,
    AppLocalizations l10n,
  ) async {
    // FR-MG05 / UX Pass 3 "Stop speaking / cancel capture": while the assistant
    // speaks, the tap silences it and returns *before* any microphone code, so
    // it can never open the microphone on top of the speaker — from either way
    // in. Stopping a sound needs no busy flag: the orb leaves the speaking state
    // on the controller's own notification.
    if (voice.isSpeaking) {
      await voice.stopSpeaking();
      return;
    }

    setState(() {
      _busy = true;
      _captureFailed = false;
    });
    try {
      if (voice.isListening) {
        final text = await voice.stopListening();
        if (text.isNotEmpty) widget.onUtterance(text);
        return;
      }

      if (voice.microphonePermission != MicrophonePermission.granted) {
        // FR-MB04: explained before asked, in both channels. The spoken half
        // is fire-and-forget on purpose — `speak()` only resolves once
        // playback finishes, and the OS dialog must appear in context, not
        // after waiting out the whole sentence.
        unawaited(_speakRationaleSafely(voice, l10n));
        final result = await voice.requestMicrophonePermission();
        if (result != MicrophonePermission.granted) return;
      }

      await voice.startListening();
    } on MicrophoneException catch (_) {
      // A denial is already reflected in `voice.microphonePermission` and
      // renders through the caption above; anything else is a genuine
      // capture failure, which gets its own honest caption instead of
      // silently leaving the idle one in place.
      if (mounted) setState(() => _captureFailed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _speakRationaleSafely(
    VoiceController voice,
    AppLocalizations l10n,
  ) async {
    try {
      await voice.speak(l10n.microphonePermissionRationale);
    } on Object {
      // The written explanation is already on screen; a missing offline
      // voice must not block the permission flow itself.
    }
  }

  void _submitText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    widget.onUtterance(trimmed);
    _textController.clear();
  }
}

class _TextFallback extends StatelessWidget {
  const _TextFallback({
    required this.controller,
    required this.microphoneLabel,
    required this.microphoneTap,
    required this.onSubmit,
  });

  final TextEditingController controller;

  /// Tooltip and screen-reader label of the microphone action. It says what the
  /// action is and, whenever the control refuses the tap, why it refuses it:
  /// the reason the orb used to carry (`FR-MG03`, `FR-MB04`).
  final String microphoneLabel;

  /// The microphone action, or null while the control refuses the tap — the
  /// voice engine is not ready, the permission is permanently denied and only
  /// the system settings can change it, or a tap is already in flight.
  final VoidCallback? microphoneTap;

  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return TextField(
      controller: controller,
      textInputAction: TextInputAction.send,
      // The fallback carries the operator's own words, and since `T13` an
      // answer typed here can become a field value of a record. The IME's
      // autocorrect rewrites that text — measured on the handset, `Perez
      // Zapata` arrived as `Pérez Pérez Zapata` — so suggestions and
      // correction are off, the same way `connect_screen` already sets them on
      // its own fields. What the operator typed is what the app stores.
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: l10n.textFallbackLabel,
        hintText: l10n.textFallbackHint,
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: AppRadii.pillAll,
          borderSide: BorderSide.none,
        ),
        // Both actions share the one trailing row the field already had, so the
        // field keeps its pill shape and the full width it had before the
        // microphone moved in. The microphone comes **first** and the send icon
        // second on purpose: the far end of the pill is where a thumb finishes a
        // typed instruction, and the send action — the one the operator already
        // reaches for — keeps that end, while the microphone is the inner,
        // secondary way in (`FR-MG02`).
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              // An outline glyph, per the UX spec's icon rules. The colour is
              // explicit rather than left to the theme so that a refused tap is
              // visible: the accent is this palette's colour of a working
              // action, and a microphone that cannot be used must not wear it.
              icon: Icon(
                Icons.mic_none_outlined,
                color: microphoneTap == null
                    ? AppColors.textMuted
                    : AppColors.accent,
              ),
              tooltip: microphoneLabel,
              onPressed: microphoneTap,
            ),
            IconButton(
              icon: const Icon(Icons.send_outlined, color: AppColors.accent),
              tooltip: l10n.textFallbackSend,
              onPressed: () => onSubmit(controller.text),
            ),
          ],
        ),
      ),
      onSubmitted: onSubmit,
    );
  }
}
