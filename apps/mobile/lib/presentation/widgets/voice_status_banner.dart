import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../voice/platform_speech.dart';
import '../../voice/voice_controller.dart';

/// States the voice readiness of this install, and says so plainly when it is
/// not ready (`FR-MB01c`, `FR-MB03`).
///
/// Nothing here is decorative: the app must never look like it can hear when
/// the recognizer has no model, and it must never quietly fall back to a voice
/// that needs the network. The banner is hidden only in the one state where
/// recognition and synthesis are both known to work.
class VoiceStatusBanner extends StatelessWidget {
  const VoiceStatusBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final voice = AppScope.of(context).voice;
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;

    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) {
        final lines = <String>[
          ..._recognitionLines(l10n, voice),
          ..._speechLines(l10n, voice),
        ];
        if (lines.isEmpty) return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.only(bottom: AppSpacing.md),
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadii.cardSmallAll,
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.mic_off_outlined, color: AppColors.textMuted),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in lines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                        child: Text(line, style: textTheme.bodySmall),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  List<String> _recognitionLines(
    AppLocalizations l10n,
    VoiceController voice,
  ) {
    switch (voice.readiness) {
      case VoiceReadiness.idle:
      case VoiceReadiness.checking:
        return <String>[l10n.voiceStatusChecking];
      case VoiceReadiness.provisioning:
        return <String>[
          l10n.voiceStatusProvisioning(
            (voice.provisioningProgress * 100).round(),
          ),
        ];
      case VoiceReadiness.ready:
        return const <String>[];
      case VoiceReadiness.unavailable:
        return <String>[
          switch (voice.problem) {
            VoiceProblem.modelMissing => l10n.voiceStatusUnavailableModel,
            VoiceProblem.modelCorrupt => l10n.voiceStatusUnavailableModelCorrupt,
            VoiceProblem.provisioningFailed =>
              l10n.voiceStatusUnavailableProvisioning,
            VoiceProblem.recognizerFailed =>
              l10n.voiceStatusUnavailableRecognizer,
            VoiceProblem.none => l10n.voiceStatusUnavailableRecognizer,
          },
        ];
    }
  }

  List<String> _speechLines(AppLocalizations l10n, VoiceController voice) {
    return switch (voice.speechProblem) {
      SpeechProblem.none => const <String>[],
      SpeechProblem.noOfflineSpanishVoice => <String>[
          l10n.voiceStatusUnavailableSpeech,
        ],
      SpeechProblem.voiceNotPinned => <String>[
          l10n.voiceStatusUnavailableSpeechPinning,
        ],
      SpeechProblem.engineUnavailable => <String>[
          l10n.voiceStatusUnavailableSpeechEngine,
        ],
    };
  }
}
