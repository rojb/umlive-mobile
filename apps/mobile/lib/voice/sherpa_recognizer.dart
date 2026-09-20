import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../core/log.dart';

/// What building the recognizer cost, measured inside the isolate that built it.
class SherpaRecognizerProfile {
  const SherpaRecognizerProfile({
    required this.initBindingsMs,
    required this.modelLoadMs,
    required this.recognizerMs,
    required this.modelBytes,
    required this.numThreads,
    required this.sampleRate,
  });

  /// `initBindings()` time. It is **per isolate**, so it is measured again in
  /// the isolate that touches sherpa, not reused from the UI isolate.
  final int initBindingsMs;

  /// Time spent opening both model files and reading their size: the step that
  /// proves the provisioned files are present and readable on this device.
  /// sherpa parses them inside the constructor, so the parse itself is counted
  /// in [recognizerMs].
  final int modelLoadMs;

  /// `OfflineRecognizer(...)` — creates the native recognizer and loads the
  /// acoustic model.
  final int recognizerMs;

  final int modelBytes;
  final int numThreads;
  final int sampleRate;
}

/// One decode of one buffer of mono audio.
class SherpaDecodeResult {
  const SherpaDecodeResult({
    required this.text,
    required this.decodeMs,
    required this.audioMs,
  });

  final String text;
  final int decodeMs;
  final double audioMs;

  /// Decode time over audio duration: below 1 means faster than real time. It
  /// is logged for every decode because it is what tells whether re-decoding
  /// the growing buffer keeps up with the microphone.
  double get realTimeFactor => audioMs <= 0 ? 0 : decodeMs / audioMs;
}

/// Raised when the recognizer cannot be built, or when it dies mid-decode.
class SherpaRecognizerException implements Exception {
  SherpaRecognizerException(this.detail);

  final String detail;

  @override
  String toString() => 'SherpaRecognizerException($detail)';
}

/// The offline recognizer, owned by a background isolate.
///
/// Recognition is heavy — building this model takes seconds on the demo handset
/// and a decode of five seconds of audio a measurable fraction of that — so the
/// recognizer never lives on the UI isolate. [spawn] starts a dedicated
/// isolate, initialises the native bindings **inside it** and builds the
/// recognizer there once; [decode] hands buffers over and awaits text.
///
/// Every timing is measured in the isolate that paid it and logged from here,
/// on the UI isolate, as `[umlive][stt]` lines.
class SherpaRecognizer {
  SherpaRecognizer._(
    this._isolate,
    this._commands,
    this._events,
    this._pending,
    this._exited,
    this.profile,
  );

  /// Builds a recognizer from provisioned model files.
  ///
  /// [modelPath] and [tokensPath] are real filesystem paths inside the app's
  /// support directory — see `SherpaModelProvisioner`.
  static Future<SherpaRecognizer> spawn({
    required String modelPath,
    required String tokensPath,
    int numThreads = 2,
    int sampleRate = 16000,
  }) async {
    final events = ReceivePort();
    final exits = ReceivePort();
    final errors = ReceivePort();
    final commands = Completer<SendPort>();
    final ready = Completer<SherpaRecognizerProfile>();
    final pending = <int, Completer<_DecodeAnswer>>{};
    var exited = false;

    // One listener for the whole lifetime of the isolate: the protocol and the
    // decode answers share it, because a ReceivePort is single-subscription.
    final subscription = events.listen((message) {
      if (message is! Map) return;
      final event = message.cast<String, Object?>();
      switch (event['kind']) {
        case 'commands':
          commands.complete(event['port'] as SendPort);
        case 'ready':
          ready.complete(
            SherpaRecognizerProfile(
              initBindingsMs: event['init_bindings_ms'] as int,
              modelLoadMs: event['model_load_ms'] as int,
              recognizerMs: event['recognizer_ms'] as int,
              modelBytes: event['model_bytes'] as int,
              numThreads: event['num_threads'] as int,
              sampleRate: event['sample_rate'] as int,
            ),
          );
        case 'fatal':
          ready.completeError(
            SherpaRecognizerException(event['error'] as String? ?? 'unknown'),
          );
        case 'result':
          pending.remove(event['id'] as int?)?.complete(
                _DecodeAnswer(
                  text: event['text'] as String? ?? '',
                  decodeMs: event['decode_ms'] as int? ?? 0,
                ),
              );
        case 'decode_error':
          pending.remove(event['id'] as int?)?.completeError(
                SherpaRecognizerException(event['error'] as String? ?? 'unknown'),
              );
      }
    });

    final errorSubscription = errors.listen((message) {
      // A crashed isolate is reported rather than swallowed: a recognizer that
      // died is the difference between "no speech" and "no engine".
      final list = message as List<Object?>?;
      logEvent('stt', {
        'kind': 'isolate_error',
        'error': list != null && list.isNotEmpty ? list[0] : 'unknown',
      });
    });

    final isolate = await Isolate.spawn<_RecognizerInit>(
      _recognizerMain,
      _RecognizerInit(
        events: events.sendPort,
        modelPath: modelPath,
        tokensPath: tokensPath,
        numThreads: numThreads,
        sampleRate: sampleRate,
      ),
      debugName: 'umlive-stt',
      errorsAreFatal: false,
      onError: errors.sendPort,
      onExit: exits.sendPort,
    );

    final exitSubscription = exits.listen((_) {
      exited = true;
      final failure = SherpaRecognizerException('recognition isolate exited');
      for (final completer in pending.values) {
        if (!completer.isCompleted) completer.completeError(failure);
      }
      pending.clear();
    });

    final SherpaRecognizerProfile profile;
    try {
      profile = await ready.future;
    } on Object {
      // Nothing was built: release the isolate and its ports instead of leaving
      // them parked for the lifetime of the app.
      isolate.kill(priority: Isolate.immediate);
      await subscription.cancel();
      await errorSubscription.cancel();
      await exitSubscription.cancel();
      events.close();
      exits.close();
      errors.close();
      rethrow;
    }

    logEvent('stt', {
      'kind': 'model_load',
      'files': 2,
      'bytes': profile.modelBytes,
      'ms': profile.modelLoadMs,
    });
    logEvent('stt', {
      'kind': 'recognizer',
      'ms': profile.recognizerMs,
      'init_bindings_ms': profile.initBindingsMs,
      'threads': profile.numThreads,
      'decoding': 'greedy_search',
      'sample_rate': profile.sampleRate,
    });

    return SherpaRecognizer._(
      isolate,
      await commands.future,
      events,
      pending,
      () => exited,
      profile,
    );
  }

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _events;
  final Map<int, Completer<_DecodeAnswer>> _pending;

  final SherpaRecognizerProfile profile;

  final bool Function() _exited;
  int _nextRequest = 0;
  bool _disposed = false;

  int get sampleRate => profile.sampleRate;

  /// Decodes one buffer of mono float samples in `[-1, 1]`.
  ///
  /// [source] only labels the log line (`mic_partial`, `mic_final`,
  /// `file_tts`), because the log is the verification surface: a microphone
  /// cannot be read from a screenshot.
  Future<SherpaDecodeResult> decode(
    Float32List samples, {
    String source = 'unknown',
  }) {
    if (_disposed) {
      throw StateError('SherpaRecognizer.decode() after dispose()');
    }
    if (_exited()) {
      throw SherpaRecognizerException('recognition isolate is gone');
    }
    final id = _nextRequest++;
    final completer = Completer<_DecodeAnswer>();
    _pending[id] = completer;
    _commands.send(<String, Object?>{
      'kind': 'decode',
      'id': id,
      'samples': samples,
      'sample_rate': sampleRate,
    });
    return completer.future.then((answer) {
      final result = SherpaDecodeResult(
        text: answer.text,
        decodeMs: answer.decodeMs,
        audioMs: samples.length * 1000 / sampleRate,
      );
      logEvent('stt', {
        'kind': 'decode',
        'source': source,
        'sample_rate': sampleRate,
        'audio_ms': result.audioMs.round(),
        'decode_ms': result.decodeMs,
        'rtf': result.realTimeFactor.toStringAsFixed(2),
        'text': result.text,
      });
      return result;
    });
  }

  /// Frees the native recognizer and stops its isolate.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _commands.send(<String, Object?>{'kind': 'dispose'});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _events.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

class _DecodeAnswer {
  const _DecodeAnswer({required this.text, required this.decodeMs});

  final String text;
  final int decodeMs;
}

class _RecognizerInit {
  const _RecognizerInit({
    required this.events,
    required this.modelPath,
    required this.tokensPath,
    required this.numThreads,
    required this.sampleRate,
  });

  final SendPort events;
  final String modelPath;
  final String tokensPath;
  final int numThreads;
  final int sampleRate;
}

/// Isolate entry point: initialise, build, then answer decode commands.
Future<void> _recognizerMain(_RecognizerInit init) async {
  final commands = ReceivePort();
  init.events
      .send(<String, Object?>{'kind': 'commands', 'port': commands.sendPort});

  final sherpa.OfflineRecognizer recognizer;
  try {
    // initBindings() is per isolate: this isolate is a second one and holds
    // none of the UI isolate's FFI state, so it initialises its own.
    final bindingsStarted = DateTime.now();
    sherpa.initBindings();
    final initBindingsMs =
        DateTime.now().difference(bindingsStarted).inMilliseconds;

    final loadStarted = DateTime.now();
    var modelBytes = 0;
    for (final path in <String>[init.modelPath, init.tokensPath]) {
      final file = File(path);
      final length = file.lengthSync();
      final handle = file.openSync();
      try {
        // Reading one byte is what proves the file is readable and not a
        // zero-length placeholder left behind by an interrupted copy.
        handle.readSync(1);
      } finally {
        handle.closeSync();
      }
      modelBytes += length;
    }
    final modelLoadMs = DateTime.now().difference(loadStarted).inMilliseconds;

    final config = sherpa.OfflineRecognizerConfig(
      feat: sherpa.FeatureConfig(sampleRate: init.sampleRate, featureDim: 80),
      model: sherpa.OfflineModelConfig(
        nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(model: init.modelPath),
        tokens: init.tokensPath,
        numThreads: init.numThreads,
        provider: 'cpu',
        debug: false,
      ),
      decodingMethod: 'greedy_search',
    );
    final constructStarted = DateTime.now();
    recognizer = sherpa.OfflineRecognizer(config);
    final recognizerMs =
        DateTime.now().difference(constructStarted).inMilliseconds;

    init.events.send(<String, Object?>{
      'kind': 'ready',
      'init_bindings_ms': initBindingsMs,
      'model_load_ms': modelLoadMs,
      'recognizer_ms': recognizerMs,
      'model_bytes': modelBytes,
      'num_threads': init.numThreads,
      'sample_rate': init.sampleRate,
    });
  } on Object catch (error) {
    init.events.send(<String, Object?>{
      'kind': 'fatal',
      'error': error.runtimeType.toString(),
    });
    commands.close();
    return;
  }

  await for (final message in commands) {
    final command = (message as Map).cast<String, Object?>();
    final kind = command['kind'];
    if (kind == 'dispose') {
      recognizer.free();
      init.events.send(<String, Object?>{'kind': 'disposed'});
      commands.close();
      return;
    }
    if (kind != 'decode') continue;

    final id = command['id'] as int;
    final samples = command['samples'] as Float32List;
    final sampleRate = command['sample_rate'] as int? ?? init.sampleRate;
    final started = DateTime.now();
    try {
      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
        recognizer.decode(stream);
        final text = recognizer.getResult(stream).text;
        init.events.send(<String, Object?>{
          'kind': 'result',
          'id': id,
          'text': text,
          'decode_ms': DateTime.now().difference(started).inMilliseconds,
        });
      } finally {
        stream.free();
      }
    } on Object catch (error) {
      init.events.send(<String, Object?>{
        'kind': 'decode_error',
        'id': id,
        'error': error.runtimeType.toString(),
      });
    }
  }
}
