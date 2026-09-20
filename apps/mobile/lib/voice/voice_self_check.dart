import '../core/log.dart';
import 'microphone_capture.dart';
import 'voice_controller.dart';
import 'wav_audio.dart';

/// Set with `--dart-define=UMLIVE_VOICE_SELFCHECK=true` to run the offline voice
/// self-check on launch.
///
/// The offline claim cannot be checked from a screenshot, and nobody can speak
/// into the handset on demand, so the check synthesises the canonical utterance
/// of `PRD-MOBILE.md` §5.1 with the platform engine, decodes that same file
/// through the recognizer, speaks it, and finishes with a short microphone
/// window. Every step logs under `[umlive][stt]` / `[umlive][tts]`, so the run
/// is verifiable from `adb logcat` alone.
const bool voiceSelfCheckOnLaunch =
    bool.fromEnvironment('UMLIVE_VOICE_SELFCHECK');

/// Runs the offline voice self-check once and reports whether it passed.
///
/// Returns false when any step failed; the reasons are in the log, which is the
/// evidence surface. This is a verification entry point, not a feature: it is
/// only reachable from the debug screen or from the launch flag above.
Future<bool> runOfflineVoiceSelfCheck(
  VoiceController voice, {
  required String utterance,
  Duration micWindow = const Duration(seconds: 5),
}) async {
  logEvent('voice', {
    'kind': 'selfcheck',
    'result': 'started',
    'readiness': voice.readiness.name,
    'speech': voice.speechProblem.name,
  });

  if (voice.readiness != VoiceReadiness.ready || voice.recognizer == null) {
    logEvent('voice', {
      'kind': 'selfcheck',
      'result': 'unavailable',
      'reason': voice.problem.name,
    });
    return false;
  }

  var passed = true;

  // 1. Synthesis to a file, with the pinned voice's identity logged alongside
  //    the byte size: a non-trivial WAV is the synthesis evidence.
  try {
    final synthesis = await voice.synthesizeToFile(utterance);
    if (!synthesis.producedAudio) passed = false;

    // 2. The same file goes through the recognizer's decode path.
    final audio = await readWavAsMono16k(synthesis.path);
    logEvent('stt', {
      'kind': 'audio_source',
      'source': 'tts_file',
      'file': synthesis.path,
      'bytes': audio.sourceBytes,
      'source_rate': audio.sourceSampleRate,
      'source_channels': audio.sourceChannels,
      'resampled': audio.wasResampled,
      'audio_ms': audio.durationMs.round(),
    });
    final decoded = await voice.recognizer!.decode(
      audio.samples,
      source: 'file_tts',
    );
    if (decoded.text.isEmpty) passed = false;

    // 3. And out loud, through the pinned voice.
    await voice.speak(utterance);
  } on Object catch (error) {
    passed = false;
    logEvent('voice', {
      'kind': 'selfcheck',
      'step': 'synthesis',
      'result': 'failed',
      'error': error.runtimeType.toString(),
    });
  }

  // 4. A short microphone window: proof that capture, conversion and decode run
  //    end to end while every radio is off. What it transcribes depends on the
  //    room, so an empty result is not treated as a failure here — the
  //    recognizer's own output is logged either way.
  //
  //    The permission is read first, and the window is skipped rather than
  //    entered without it. This is not defensive coding: on a fresh install
  //    this step used to open the OS dialog from a background task with
  //    nothing on screen to explain it, and the await sat there for 150 s
  //    until somebody happened to tap Allow — a hang with no error and no
  //    timeout. A self-check must never be the thing that asks; `FR-MB04`
  //    puts that conversation on the capture screen, in context.
  await voice.refreshMicrophonePermission();
  if (voice.microphonePermission != MicrophonePermission.granted) {
    logEvent('stt', {
      'kind': 'mic_window',
      'result': 'skipped',
      'reason': 'permission_${voice.microphonePermission.name}',
    });
    logEvent('voice', {
      'kind': 'selfcheck',
      'result': passed ? 'passed' : 'failed',
      'mic_window': 'skipped',
    });
    return passed;
  }

  try {
    await voice.startListening();
    await Future<void>.delayed(micWindow);
    final text = await voice.stopListening();
    logEvent('stt', {
      'kind': 'mic_window',
      'ms': micWindow.inMilliseconds,
      'text': text,
    });
  } on Object catch (error) {
    logEvent('stt', {
      'kind': 'mic_window',
      'result': 'failed',
      'error': error.runtimeType.toString(),
    });
  }

  logEvent('voice', {
    'kind': 'selfcheck',
    'result': passed ? 'passed' : 'failed',
  });
  return passed;
}
