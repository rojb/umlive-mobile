import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/log.dart';
import 'microphone_capture.dart';
import 'sherpa_recognizer.dart';

/// What the live transcript shows right now (`FR-MB05`).
class LiveTranscript {
  const LiveTranscript({this.confirmed = '', this.inFlight = false});

  /// The last completed partial: the text the recognizer actually produced for
  /// the audio captured so far.
  final String confirmed;

  /// True while more audio has been captured than the last decode saw, i.e.
  /// there are words in the air that no decode has looked at yet.
  final bool inFlight;

  bool get isEmpty => confirmed.isEmpty && !inFlight;
}

/// Turns a live microphone into a growing transcript.
///
/// The selected model is **non-streaming**: it has no notion of a confirmed
/// prefix, so partials are produced by re-decoding everything captured so far.
/// That is why the cadence is deliberate rather than continuous — a first
/// partial after [firstPartialDelay], then at most one every [partialInterval],
/// and a tick is skipped outright while the previous decode is still running so
/// work never piles up behind a slow decode. Every decode logs its real-time
/// factor under `[umlive][stt]`, which is what proves the loop keeps up.
class LiveTranscriber extends ChangeNotifier {
  LiveTranscriber(
    this._recognizer,
    this._capture, {
    this.firstPartialDelay = const Duration(milliseconds: 1200),
    this.partialInterval = const Duration(milliseconds: 1500),
    this.maxSeconds = 45,
  });

  final SherpaRecognizer _recognizer;
  final MicrophoneCapture _capture;

  /// About 1.2 s of audio is the shortest buffer this model decodes into
  /// something better than noise.
  final Duration firstPartialDelay;
  final Duration partialInterval;

  /// Ceiling on the re-decoded buffer. 45 s at 16 kHz is 2.8 MB of floats:
  /// bounded so a forgotten session cannot grow without limit, and longer than
  /// any single utterance in `PRD-MOBILE.md` §5.1.
  final int maxSeconds;

  final List<Float32List> _chunks = <Float32List>[];
  int _sampleCount = 0;
  int _decodedSampleCount = 0;
  LiveTranscript _transcript = const LiveTranscript();
  Future<void>? _inFlightDecode;
  Timer? _firstTimer;
  Timer? _periodicTimer;
  StreamSubscription<Float32List>? _subscription;
  bool _listening = false;
  bool _capped = false;

  LiveTranscript get transcript => _transcript;

  bool get isListening => _listening;

  int get sampleRate => _recognizer.sampleRate;

  int get capturedMs => _sampleCount * 1000 ~/ sampleRate;

  /// Starts capture and the partial schedule.
  ///
  /// Throws [MicrophoneException] when the permission or the device refuses;
  /// the caller turns that into copy, never into a silent no-op.
  Future<void> start() async {
    if (_listening) return;
    final stream = await _capture.start();
    _chunks.clear();
    _sampleCount = 0;
    _decodedSampleCount = 0;
    _capped = false;
    _transcript = const LiveTranscript();
    _listening = true;
    _subscription = stream.listen(
      _onChunk,
      onError: (Object error) {
        logEvent('stt', {
          'kind': 'capture',
          'result': 'stream_error',
          'error': error.runtimeType.toString(),
        });
      },
    );
    _firstTimer = Timer(firstPartialDelay, () {
      unawaited(_partial());
      _periodicTimer = Timer.periodic(partialInterval, (_) {
        unawaited(_partial());
      });
    });
    notifyListeners();
  }

  void _onChunk(Float32List samples) {
    final limit = sampleRate * maxSeconds;
    if (_sampleCount >= limit) {
      if (!_capped) {
        _capped = true;
        logEvent('stt', {
          'kind': 'capture',
          'result': 'window_capped',
          'max_seconds': maxSeconds,
        });
      }
      return;
    }
    _chunks.add(samples);
    _sampleCount += samples.length;
  }

  Future<void> _partial() async {
    if (!_listening) return;
    if (_inFlightDecode != null) {
      // The tick is skipped on purpose: a decode slower than the interval must
      // not queue up work that is already stale by the time it runs.
      logEvent('stt', {
        'kind': 'partial_skipped',
        'reason': 'decode_in_flight',
        'captured_ms': capturedMs,
      });
      return;
    }
    if (_sampleCount == 0) return;

    final samples = _snapshot();
    _decodedSampleCount = samples.length;
    final future = _runPartial(samples);
    _inFlightDecode = future;
    await future;
  }

  Future<void> _runPartial(Float32List samples) async {
    try {
      final result = await _recognizer.decode(samples, source: 'mic_partial');
      _transcript = LiveTranscript(
        confirmed: result.text,
        inFlight: _sampleCount > _decodedSampleCount,
      );
      notifyListeners();
    } on Object catch (error) {
      logEvent('stt', {
        'kind': 'partial',
        'result': 'failed',
        'error': error.runtimeType.toString(),
      });
    } finally {
      _inFlightDecode = null;
    }
  }

  /// Stops capture and decodes the whole buffer once more.
  ///
  /// Returns the final text: the partial schedule may never have seen the last
  /// words, and the final decode is the answer the rest of the app acts on.
  Future<String> stop() async {
    if (!_listening) return _transcript.confirmed;
    _listening = false;
    _firstTimer?.cancel();
    _firstTimer = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    final inFlight = _inFlightDecode;
    if (inFlight != null) {
      await inFlight;
    }
    await _subscription?.cancel();
    _subscription = null;
    await _capture.stop();

    if (_sampleCount == 0) {
      notifyListeners();
      return _transcript.confirmed;
    }
    try {
      final result = await _recognizer.decode(_snapshot(), source: 'mic_final');
      _transcript = LiveTranscript(confirmed: result.text);
      notifyListeners();
    } on Object catch (error) {
      logEvent('stt', {
        'kind': 'final',
        'result': 'failed',
        'error': error.runtimeType.toString(),
      });
    }
    return _transcript.confirmed;
  }

  Float32List _snapshot() {
    final samples = Float32List(_sampleCount);
    var offset = 0;
    for (final chunk in _chunks) {
      samples.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return samples;
  }

  @override
  void dispose() {
    _firstTimer?.cancel();
    _periodicTimer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_capture.stop());
    super.dispose();
  }
}
