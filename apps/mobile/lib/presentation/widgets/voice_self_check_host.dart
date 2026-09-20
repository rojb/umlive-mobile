import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../voice/voice_self_check.dart';

/// Runs the offline voice self-check once, on launch, when the build was made
/// with `--dart-define=UMLIVE_VOICE_SELFCHECK=true`.
///
/// The check cannot be driven by a tap on a headless verification run, and a
/// microphone cannot be read from a screenshot, so this host turns one build
/// flag into a fully logged run of the offline path. It renders nothing and is
/// inert without the flag — it is a verification entry point, not a feature,
/// and the screen it reports on is not even registered without the same flag.
class VoiceSelfCheckOnLaunch extends StatefulWidget {
  const VoiceSelfCheckOnLaunch({
    super.key,
    required this.utterance,
    required this.child,
  });

  /// The sentence synthesised and decoded, taken from `AppLocalizations`.
  final String utterance;

  final Widget child;

  @override
  State<VoiceSelfCheckOnLaunch> createState() => _VoiceSelfCheckOnLaunchState();
}

class _VoiceSelfCheckOnLaunchState extends State<VoiceSelfCheckOnLaunch> {
  @override
  void initState() {
    super.initState();
    if (!voiceSelfCheckOnLaunch) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final voice = AppScope.of(context).voice;
      await voice.initialize();
      await runOfflineVoiceSelfCheck(voice, utterance: widget.utterance);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
