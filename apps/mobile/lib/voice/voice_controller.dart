import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/log.dart';
import 'live_transcriber.dart';
import 'microphone_capture.dart';
import 'model_provisioner.dart';
import 'platform_speech.dart';
import 'sherpa_recognizer.dart';
import 'voice_assets.dart';

/// How far the voice engine is from being usable.
enum VoiceReadiness {
  /// Nothing has been tried yet.
  idle,

  /// Provisioning is about to run.
  checking,

  /// The model is being copied out of the APK. Not usable yet, and the app says
  /// so while it runs (`FR-MB01c`, `FR-MB03`).
  provisioning,

  /// Recognizer built and speech voice pinned (speech may still be unavailable
  /// on its own — see [VoiceController.speechProblem]).
  ready,

  /// Offline voice will not work on this install, for [VoiceController.problem].
  unavailable,
}

/// Why offline voice is unavailable. Rendered as a sentence, never as the
/// exception that produced it.
enum VoiceProblem {
  none,

  /// The APK does not carry the model: the fetch script was never run before
  /// the build.
  modelMissing,

  /// The copied model is not the model that was measured.
  modelCorrupt,

  /// The copy itself failed.
  provisioningFailed,

  /// The native recognizer could not be built from usable files.
  recognizerFailed,
}

/// Owns the voice engine: model provisioning, the recognizer isolate, the
/// microphone and platform speech.
///
/// It is the single object the presentation layer listens to for voice state,
/// the same way `ConnectionController` owns connection state. Nothing else
/// builds a recognizer, and nothing else copies the model.
class VoiceController extends ChangeNotifier {
  VoiceController({
    SherpaModelProvisioner? provisioner,
    PlatformSpeech? speech,
    MicrophoneCapture? microphoneCapture,
    Future<Directory> Function()? temporaryDirectory,
  })  : _provisioner = provisioner ?? SherpaModelProvisioner(),
        _speech = speech ?? PlatformSpeech(),
        _microphone = microphoneCapture,
        _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final SherpaModelProvisioner _provisioner;
  final PlatformSpeech _speech;
  final MicrophoneCapture? _microphone;
  final Future<Directory> Function() _temporaryDirectory;

  VoiceReadiness _readiness = VoiceReadiness.idle;
  VoiceProblem _problem = VoiceProblem.none;
  String? _detail;
  int _copiedBytes = 0;
  final int _totalBytes =
      sherpaAssetIdentities.fold<int>(0, (sum, a) => sum + a.bytes);
  SherpaRecognizer? _recognizer;
  LiveTranscriber? _transcriber;
  Future<void>? _initialization;

  VoiceReadiness get readiness => _readiness;

  VoiceProblem get problem => _problem;

  /// Machine detail for logs only.
  String? get detail => _detail;

  PlatformSpeech get speech => _speech;

  SpeechProblem get speechProblem => _speech.problem;

  SherpaRecognizer? get recognizer => _recognizer;

  LiveTranscriber? get transcriber => _transcriber;

  LiveTranscript get transcript =>
      _transcriber?.transcript ?? const LiveTranscript();

  double get provisioningProgress {
    if (_totalBytes <= 0) return 0;
    final ratio = _copiedBytes / _totalBytes;
    return ratio < 0 ? 0 : (ratio > 1 ? 1 : ratio);
  }

  bool get isListening => _transcriber?.isListening ?? false;

  /// Provisions the model, builds the recognizer and pins a speech voice.
  ///
  /// Every caller shares one run: the launch path and the diagnostics screen
  /// both ask for it, and a second caller must not see "not ready" while the
  /// first one is still working. A run that failed is not retried — a missing
  /// model or a crashed engine is not fixed by trying the same thing again.
  Future<void> initialize() {
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    _readiness = VoiceReadiness.provisioning;
    _copiedBytes = 0;
    notifyListeners();

    final provisioned = await _provisioner.provision(
      onProgress: (file, copied, total) {
        _copiedBytes = _committedBytes(file) + (copied < 0 ? 0 : copied);
        notifyListeners();
      },
    );

    if (!provisioned.isReady) {
      _problem = switch (provisioned.problem) {
        SherpaProvisionProblem.assetsMissingFromApk => VoiceProblem.modelMissing,
        SherpaProvisionProblem.identityMismatch => VoiceProblem.modelCorrupt,
        SherpaProvisionProblem.copyFailed => VoiceProblem.provisioningFailed,
        SherpaProvisionProblem.none => VoiceProblem.none,
      };
      _detail = provisioned.detail;
      _readiness = VoiceReadiness.unavailable;
      logEvent('voice', {
        'kind': 'init',
        'result': 'unavailable',
        'reason': _problem.name,
      });
      notifyListeners();
      return;
    }

    final paths = provisioned.paths!;
    try {
      _recognizer = await SherpaRecognizer.spawn(
        modelPath: paths.model,
        tokensPath: paths.tokens,
      );
    } on Object catch (error) {
      _problem = VoiceProblem.recognizerFailed;
      _detail = error.toString();
      _readiness = VoiceReadiness.unavailable;
      logEvent('voice', {
        'kind': 'init',
        'result': 'unavailable',
        'reason': _problem.name,
        'error': error.runtimeType.toString(),
      });
      notifyListeners();
      return;
    }

    _transcriber = LiveTranscriber(
      _recognizer!,
      _microphone ?? MicrophoneCapture(sampleRate: _recognizer!.sampleRate),
    );

    // Speech is selected independently of recognition (`FR-MB02`): a missing
    // offline voice does not disable recognition, and it is reported on its own.
    await _speech.initialize();

    _readiness = VoiceReadiness.ready;
    _problem = VoiceProblem.none;
    logEvent('voice', {
      'kind': 'init',
      'result': 'ready',
      'speech': _speech.isReady ? 'ready' : _speech.problem.name,
      'model_bytes': _recognizer!.profile.modelBytes,
      'recognizer_ms': _recognizer!.profile.recognizerMs,
    });
    notifyListeners();
  }

  /// Starts the microphone and the partial schedule.
  Future<void> startListening() async {
    final transcriber = _transcriber;
    if (transcriber == null) {
      throw MicrophoneException('voice engine is not ready');
    }
    await transcriber.start();
    notifyListeners();
  }

  /// Stops capture and returns the final transcript.
  Future<String> stopListening() async {
    final transcriber = _transcriber;
    if (transcriber == null) return '';
    final text = await transcriber.stop();
    logEvent('stt', {'kind': 'final', 'source': 'mic_final', 'text': text});
    notifyListeners();
    return text;
  }

  /// Synthesises [text] into a WAV file under the app's temporary directory.
  Future<SpeechSynthesis> synthesizeToFile(String text) async {
    final scratch = await _temporaryDirectory();
    final directory = Directory(p.join(scratch.path, 'voice-debug'));
    return _speech.synthesizeToFile(text, directory: directory);
  }

  /// Speaks [text] through the pinned offline voice.
  Future<void> speak(String text) => _speech.speak(text);

  @override
  void dispose() {
    _transcriber?.dispose();
    _recognizer?.dispose();
    super.dispose();
  }

  int _committedBytes(String file) {
    var total = 0;
    for (final identity in sherpaAssetIdentities) {
      if (identity.fileName == file) return total;
      total += identity.bytes;
    }
    return total;
  }
}
