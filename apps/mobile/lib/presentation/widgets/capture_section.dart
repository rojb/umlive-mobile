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
/// (readiness, permission, listening, amplitude); the only state kept here is
/// the transient "is a tap in flight" flag and the text field's own buffer.
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
    final textTheme = Theme.of(context).textTheme;
    final voice = widget.voice;

    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) {
        final ready = voice.readiness == VoiceReadiness.ready;
        final permission = voice.microphonePermission;
        final listening = voice.isListening;

        final String caption;
        final String semantics;
        final bool orbEnabled;
        final bool showSettingsAction;
        if (!ready) {
          caption = l10n.captureUnavailableCaption;
          semantics = l10n.captureOrbSemantics;
          orbEnabled = false;
          showSettingsAction = false;
        } else if (permission == MicrophonePermission.permanentlyDenied) {
          caption = l10n.microphonePermissionPermanentlyDeniedCaption;
          semantics = l10n.captureOrbSemanticsPermissionBlocked;
          orbEnabled = false;
          showSettingsAction = true;
        } else if (permission != MicrophonePermission.granted) {
          caption = l10n.microphonePermissionRationale;
          semantics = l10n.captureOrbSemanticsPermissionNeeded;
          orbEnabled = true;
          showSettingsAction = false;
        } else if (!listening && _captureFailed) {
          caption = l10n.microphoneCaptureFailedCaption;
          semantics = l10n.captureOrbSemanticsReady;
          orbEnabled = true;
          showSettingsAction = false;
        } else if (listening) {
          caption = '';
          semantics = l10n.captureOrbSemanticsListening;
          orbEnabled = true;
          showSettingsAction = false;
        } else {
          caption = l10n.captureIdleCaption;
          semantics = l10n.captureOrbSemanticsReady;
          orbEnabled = true;
          showSettingsAction = false;
        }

        return Column(
          children: [
            Semantics(
              label: semantics,
              button: orbEnabled,
              enabled: orbEnabled,
              child: GestureDetector(
                onTap: orbEnabled && !_busy
                    ? () => _onOrbTap(voice, l10n)
                    : null,
                child: ValueListenableBuilder<double>(
                  valueListenable: voice.amplitude,
                  builder: (context, level, _) =>
                      GlowOrb(amplitude: level, listening: listening),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (listening)
              ListenableBuilder(
                listenable: voice.transcriber!,
                builder: (context, _) => LiveTranscriptView(
                  transcript: voice.transcript,
                  emptyLabel: l10n.captureListeningCaption,
                ),
              )
            else
              Text(
                caption,
                textAlign: TextAlign.center,
                style: textTheme.bodySmall,
              ),
            if (showSettingsAction) ...[
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton(
                onPressed: () => voice.openMicrophoneSettings(),
                child: Text(l10n.microphonePermissionOpenSettings),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            // FR-MB06: every voice action has a typed equivalent, always
            // available — including, and especially, while the microphone is
            // denied.
            _TextFallback(
              controller: _textController,
              enabled: !listening,
              onSubmit: _submitText,
            ),
          ],
        );
      },
    );
  }

  Future<void> _onOrbTap(VoiceController voice, AppLocalizations l10n) async {
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
    required this.enabled,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return TextField(
      controller: controller,
      enabled: enabled,
      textInputAction: TextInputAction.send,
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
        suffixIcon: IconButton(
          icon: const Icon(Icons.send_outlined, color: AppColors.accent),
          tooltip: l10n.textFallbackSend,
          onPressed: enabled ? () => onSubmit(controller.text) : null,
        ),
      ),
      onSubmitted: onSubmit,
    );
  }
}
