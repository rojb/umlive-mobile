import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../voice/live_transcriber.dart';

/// The live transcript: confirmed words in `text-primary`, pending tail in
/// `text-muted` (`FR-MB05`, UX spec "confirmed words white, in-flight tail
/// muted").
///
/// One adaptation is deliberate and worth stating, because the UX spec assumes
/// a streaming recognizer: this engine is **non-streaming**, so it exposes no
/// confirmed-prefix boundary inside the utterance it is decoding. There is
/// nothing that says "these words are settled, those are still moving". What is
/// shown as confirmed is therefore the last *completed* partial — real text the
/// recognizer produced — and the tail of the utterance that no decode has
/// looked at yet is represented by a muted marker rather than by muted words,
/// because inventing words for undecoded audio would be a fabrication.
class LiveTranscriptView extends StatelessWidget {
  const LiveTranscriptView({
    super.key,
    required this.transcript,
    required this.emptyLabel,
  });

  final LiveTranscript transcript;

  /// Shown when there is nothing to render yet.
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final base = Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontSize: AppTextSizes.transcript,
        );

    if (transcript.isEmpty) {
      return Text(
        emptyLabel,
        style: base?.copyWith(color: AppColors.textMuted),
      );
    }

    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: transcript.confirmed,
            style: base?.copyWith(color: AppColors.textPrimary),
          ),
          if (transcript.inFlight)
            TextSpan(
              text: transcript.confirmed.isEmpty
                  ? l10n.voiceTranscriptInFlight
                  : ' ${l10n.voiceTranscriptInFlight}',
              style: base?.copyWith(color: AppColors.textMuted),
            ),
        ],
      ),
    );
  }
}
