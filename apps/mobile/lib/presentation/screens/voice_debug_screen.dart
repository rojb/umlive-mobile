import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../voice/microphone_capture.dart';
import '../../voice/voice_controller.dart';
import '../../voice/voice_self_check.dart';
import '../widgets/app_background.dart';
import '../widgets/live_transcript_view.dart';
import '../widgets/voice_status_banner.dart';

/// Voice diagnostics: a clearly marked verification screen, not a user feature.
///
/// It is registered as a route **only** in a build made with
/// `--dart-define=UMLIVE_VOICE_SELFCHECK=true` (see `AppRoutes`), so no tap in
/// an ordinary build reaches it: the product ships four screens, not five.
///
/// The offline claim cannot be checked from a screenshot — nobody can read a
/// microphone, and nobody can speak into the handset on demand — so this screen
/// makes the machine do the talking: it synthesises the canonical utterance of
/// `PRD-MOBILE.md` §5.1 with the platform engine, decodes that same file
/// through the recognizer, speaks it out loud, and offers a live microphone
/// window whose partials render exactly as the capture UI will render them.
///
/// Every step logs `[umlive][stt]` / `[umlive][tts]` lines, which are the
/// evidence; the screen only triggers and summarises them.
class VoiceDebugScreen extends StatefulWidget {
  const VoiceDebugScreen({super.key});

  @override
  State<VoiceDebugScreen> createState() => _VoiceDebugScreenState();
}

class _VoiceDebugScreenState extends State<VoiceDebugScreen> {
  bool _running = false;
  bool? _passed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final voice = AppScope.of(context).voice;

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(l10n.voiceDebugTitle)),
        body: SafeArea(
          child: ListenableBuilder(
            listenable: voice,
            builder: (context, _) {
              return ListView(
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  Text(l10n.voiceDebugIntro, style: textTheme.bodySmall),
                  const SizedBox(height: AppSpacing.md),
                  const VoiceStatusBanner(),
                  _Field(
                    label: l10n.voiceDebugModelLabel,
                    value: l10n.voiceDebugModelValue,
                  ),
                  _Field(
                    label: l10n.voiceDebugVoiceLabel,
                    value: voice.speech.voice == null
                        ? l10n.voiceDebugVoiceNone
                        : l10n.voiceDebugVoiceValue(
                            voice.speech.voice!.name,
                            voice.speech.voice!.locale,
                          ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  FilledButton(
                    onPressed: _running || voice.readiness != VoiceReadiness.ready
                        ? null
                        : () => _runSelfCheck(voice, l10n),
                    child: Text(
                      _running
                          ? l10n.voiceDebugSelfCheckRunning
                          : l10n.voiceDebugSelfCheck,
                    ),
                  ),
                  if (_passed != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      _passed!
                          ? l10n.voiceDebugSelfCheckPassed
                          : l10n.voiceDebugSelfCheckFailed,
                      style: textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  _LiveCapture(voice: voice),
                  const SizedBox(height: AppSpacing.lg),
                  Text(l10n.voiceDebugLogNote, style: textTheme.bodySmall),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _runSelfCheck(
    VoiceController voice,
    AppLocalizations l10n,
  ) async {
    setState(() {
      _running = true;
      _passed = null;
    });
    final passed = await runOfflineVoiceSelfCheck(
      voice,
      utterance: l10n.voiceDebugUtterance,
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _passed = passed;
    });
  }
}

/// One labelled fact about the engine, read from the engine itself.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: textTheme.bodySmall)),
          Expanded(
            child: Text(
              value,
              style: textTheme.bodyMedium,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

/// The live microphone window: capture, partials, final text.
class _LiveCapture extends StatefulWidget {
  const _LiveCapture({required this.voice});

  final VoiceController voice;

  @override
  State<_LiveCapture> createState() => _LiveCaptureState();
}

class _LiveCaptureState extends State<_LiveCapture> {
  String? _error;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final voice = widget.voice;
    final transcriber = voice.transcriber;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton(
          onPressed: voice.readiness == VoiceReadiness.ready
              ? () => _toggle(voice)
              : null,
          child: Text(
            voice.isListening
                ? l10n.voiceDebugCaptureStop
                : l10n.voiceDebugCaptureStart,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (_error != null)
          Text(
            l10n.voicePermissionDenied,
            style: textTheme.bodySmall,
          ),
        if (transcriber == null)
          LiveTranscriptView(
            transcript: voice.transcript,
            emptyLabel: l10n.voiceDebugTranscriptEmpty,
          )
        else
          ListenableBuilder(
            listenable: transcriber,
            builder: (context, _) => LiveTranscriptView(
              transcript: transcriber.transcript,
              emptyLabel: l10n.voiceDebugTranscriptEmpty,
            ),
          ),
      ],
    );
  }

  Future<void> _toggle(VoiceController voice) async {
    try {
      if (voice.isListening) {
        await voice.stopListening();
      } else {
        await voice.startListening();
      }
      if (mounted) setState(() => _error = null);
    } on MicrophoneException catch (error) {
      if (mounted) setState(() => _error = error.reason);
    }
  }
}
