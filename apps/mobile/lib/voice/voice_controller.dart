import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../conversation/speech_sink.dart';
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
///
/// It also **implements the conversation's [SpeechSink] port** (`T15`): the
/// conversation speaks through this object, so the one place that knows how to
/// synthesise is the one place that speaks. An unavailable or failed synthesis
/// must never travel back as an exception that could take a turn down
/// (`FR-MD03`) — the conversation speaks fire-and-forget, treats a failure as
/// a log line, and never lets speech delay, fail or reorder a turn.
class VoiceController extends ChangeNotifier implements SpeechSink {
  VoiceController({
    SherpaModelProvisioner? provisioner,
    PlatformSpeech? speech,
    MicrophoneCapture? microphoneCapture,
    Future<Directory> Function()? temporaryDirectory,
  })  : _provisioner = provisioner ?? SherpaModelProvisioner(),
        _speech = speech ?? PlatformSpeech(),
        _microphone = microphoneCapture ?? MicrophoneCapture(),
        _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final SherpaModelProvisioner _provisioner;
  final PlatformSpeech _speech;
  final MicrophoneCapture _microphone;
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
  MicrophonePermission _micPermission = MicrophonePermission.unknown;

  /// Real microphone level, `0..1`, forwarded from the live transcriber
  /// without going through [notifyListeners] — see
  /// [LiveTranscriber.amplitude] for why. The orb is the only thing meant to
  /// listen to this; it stays at 0 before the engine is ready and after
  /// capture stops.
  ValueListenable<double> get amplitude => _amplitude;
  final ValueNotifier<double> _amplitude = ValueNotifier<double>(0);

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

    assert(
      _recognizer!.sampleRate == _microphone.sampleRate,
      'the microphone must capture at the sample rate the recognizer expects',
    );
    _transcriber = LiveTranscriber(_recognizer!, _microphone);
    _transcriber!.amplitude.addListener(_forwardAmplitude);

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

  /// Current microphone permission, refreshed by [refreshMicrophonePermission]
  /// and [requestMicrophonePermission]. Read-only status: never shows the OS
  /// dialog on its own.
  MicrophonePermission get microphonePermission => _micPermission;

  /// Re-reads the OS permission without prompting.
  ///
  /// Safe to call at any time, including before the voice engine is ready.
  /// Called on screen build and on app resume, so a grant made from system
  /// Settings — the only way out of [MicrophonePermission.permanentlyDenied]
  /// — is picked up without an extra tap.
  Future<void> refreshMicrophonePermission() async {
    _micPermission = await _microphone.checkPermission();
    notifyListeners();
  }

  /// Shows the OS permission dialog. Must only ever be called from a user
  /// tap, after the caller has already shown — and ideally spoken — the
  /// explanation `FR-MB04` requires; this method itself explains nothing.
  Future<MicrophonePermission> requestMicrophonePermission() async {
    _micPermission = await _microphone.requestPermission();
    notifyListeners();
    return _micPermission;
  }

  /// Opens this app's system settings page — the only way out of a permanent
  /// denial.
  Future<bool> openMicrophoneSettings() => _microphone.openSettings();

  void _forwardAmplitude() {
    _amplitude.value = _transcriber?.amplitude.value ?? 0;
  }

  /// Synthesises [text] into a WAV file under the app's temporary directory.
  Future<SpeechSynthesis> synthesizeToFile(String text) async {
    final scratch = await _temporaryDirectory();
    final directory = Directory(p.join(scratch.path, 'voice-debug'));
    return _speech.synthesizeToFile(text, directory: directory);
  }

  /// The serialization point of speech: every [speak] call appends one link to
  /// this chain, so playback order equals call order — the same idiom
  /// `dart:async` chains use, where each call captures the current future and
  /// stores the new link back. The chain is never left broken by a failure, so
  /// the sentence behind a failed one still plays.
  Future<void> _speechChain = Future<void>.value();

  /// Utterances requested but not yet finished playing. It exists only to make
  /// the serialization observable: a call that arrives while this is non-zero
  /// is queued behind one that is still playing.
  int _speechPending = 0;

  /// How long [speak] waits for synthesis before it drops the sentence.
  ///
  /// Measured on `TFY-LX3` at cold start: the drain fired as soon as the backend
  /// answered, so the two outcome turns arrived at `13:26:13.843` and
  /// `13:26:13.845`, while `[umlive][voice] kind=init result=ready` only landed
  /// at `13:26:14.870` (the voice was pinned at `13:26:14.869`). The recognizer
  /// alone took 6 241 ms in that same launch, so the voice becomes ready a
  /// little after the turn does: the budget has to cover the tail of cold-start
  /// provisioning, not the whole launch.
  static const Duration _synthesisWaitBudget = Duration(seconds: 8);

  /// True when synthesis can say a sentence now, or when it never will.
  ///
  /// The settled "never will" states are the voice controller giving up on the
  /// engine ([VoiceReadiness.unavailable]) and speech having finished its own
  /// initialization with a problem. The problem check is guarded by
  /// [VoiceReadiness.ready] on purpose: [PlatformSpeech] starts out reporting
  /// `SpeechProblem.engineUnavailable` before anyone has asked it to
  /// initialize, so a bare problem check would call provisioning "settled" and
  /// release the sentence into the very race this wait exists to close.
  bool get _synthesisSettled =>
      _speech.isReady ||
      _readiness == VoiceReadiness.unavailable ||
      (_readiness == VoiceReadiness.ready &&
          _speech.problem != SpeechProblem.none);

  /// Waits for synthesis readiness on the notification this class already
  /// emits, bounded by [_synthesisWaitBudget].
  ///
  /// Returns `true` when the sentence should proceed — either the engine can
  /// say it, or it never will and the existing refusal path has to report that
  /// failure — and `false` when the budget ran out and [speak] must drop the
  /// sentence instead of committing it to the chain.
  Future<bool> _awaitSynthesis() async {
    if (_synthesisSettled) return true;

    final ready = Completer<void>();
    void onChanged() {
      if (_synthesisSettled && !ready.isCompleted) ready.complete();
    }

    addListener(onChanged);
    try {
      // The condition can turn true between the check above and the listener
      // being attached. Re-check inside the guarded region so that transition
      // is never waited out.
      onChanged();
      await ready.future.timeout(_synthesisWaitBudget);
      return true;
    } on TimeoutException {
      return false;
    } finally {
      removeListener(onChanged);
    }
  }

  /// Speaks [text] through the pinned offline voice, one sentence at a time and
  /// in call order.
  ///
  /// Measured on `TFY-LX3` during `T16`'s verification, at cold start: the
  /// voice engine spends seconds provisioning and pinning the offline voice
  /// (`kind=init result=ready` at `13:26:14.870`, the voice pinned at
  /// `13:26:14.869`), while the drain fires as soon as the backend answers. The
  /// two outcome turns arrived at `13:26:13.843` and `13:26:13.845`, and both
  /// were refused — `kind=speak result=refused reason=no_offline_voice` plus
  /// `kind=speak_failed error=SpeechException`. The sentences were never said
  /// and nothing retried them: a sentence the app owes was lost to a cold
  /// start, because the wait for readiness did not exist.
  ///
  /// The rule: a sentence the app owes is said when the engine can say it, and
  /// it is never spoken after the budget when the engine never came up.
  ///
  /// Measured on `TFY-LX3` during `T15`'s verification: the conversation issued
  /// the resolving cue (`12:41:56.203`) and the sentence that settles right
  /// behind it (`12:41:56.295`) milliseconds apart. The `[umlive][tts]` lines
  /// showed `kind=speak result=failed` for the second call and a single
  /// `result=started` 1.3 s later — the plugin (`flutter_tts` with
  /// `awaitSpeakCompletion(true)`, `QUEUE_FLUSH`) answers `0` for any `speak`
  /// that arrives while another one is playing, which the platform layer reports
  /// as a failure under `speak()`'s completion-driven result. The cue was heard
  /// and **the sentence that says the write is queued was never spoken**, which
  /// breaks `FR-MD03` and the conversation's own contract that every settled
  /// sentence is spoken.
  ///
  /// These rules compose into one: the app speaks in order, a sentence is never
  /// dropped because another one is still playing, and a sentence is never lost
  /// to a cold start. Each call waits for synthesis readiness and then appends
  /// one link to [_speechChain], completing when *this* sentence has finished
  /// playing; a failure is swallowed into a `tts` log line, never into a broken
  /// chain, because the next sentence still has to play.
  ///
  /// The wait is what makes the cold-start rule hold: a sentence is said when
  /// the engine can say it, and it is dropped with a `speak_dropped` log line
  /// when the budget runs out — never silently, and never spoken long after the
  /// operator gave up waiting. An engine that has settled as unavailable is not
  /// waited for at all: the existing refusal path reports it exactly as before.
  @override
  Future<void> speak(String text) async {
    if (!await _awaitSynthesis()) {
      logEvent('tts', {
        'kind': 'speak_dropped',
        'reason': 'engine_not_ready',
        'length': text.length,
      });
      return;
    }

    if (_speechPending > 0) {
      logEvent('tts', {
        'kind': 'queued',
        'length': text.length,
        'pending': true,
      });
    }
    _speechPending += 1;

    // Appending is the serialization: this link does not begin until every
    // sentence before it has finished playing, and the next call waits on it.
    final spoken = _speechChain.then((_) async {
      try {
        await _speech.speak(text);
      } on Object catch (error) {
        logEvent('tts', {
          'kind': 'speak_failed',
          'error': error.runtimeType.toString(),
        });
      } finally {
        _speechPending -= 1;
      }
    });

    _speechChain = spoken;
    return spoken;
  }

  @override
  void dispose() {
    _transcriber?.amplitude.removeListener(_forwardAmplitude);
    _transcriber?.dispose();
    _recognizer?.dispose();
    _amplitude.dispose();
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
