import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../core/log.dart';

/// Capture could not start, and why.
class MicrophoneException implements Exception {
  MicrophoneException(this.reason);

  /// `permissionDenied` or the platform's own error type name.
  final String reason;

  @override
  String toString() => 'MicrophoneException($reason)';
}

/// Microphone capture at the rate the model wants.
///
/// The recognizer expects 16 kHz mono audio, so capture is configured that way
/// rather than resampled afterwards: `AudioEncoder.pcm16bits` gives raw little
/// endian signed 16-bit samples with no codec in the path.
///
/// The int16 -> float32 conversion is exactly the measured one:
/// `getInt16(i * 2, Endian.little) / 32768.0`, which maps the full signed range
/// onto `[-1, 1]`.
class MicrophoneCapture {
  MicrophoneCapture({this.sampleRate = 16000});

  final int sampleRate;

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _subscription;
  bool _listening = false;

  bool get isListening => _listening;

  /// Asks for the microphone permission in context (`FR-MB04`).
  Future<bool> requestPermission() async {
    final recorder = AudioRecorder();
    try {
      return await recorder.hasPermission();
    } finally {
      await recorder.dispose();
    }
  }

  /// Starts streaming mono PCM16 and yields float samples in `[-1, 1]`.
  Future<Stream<Float32List>> start() async {
    final recorder = AudioRecorder();
    final granted = await recorder.hasPermission();
    if (!granted) {
      await recorder.dispose();
      logEvent('stt', {'kind': 'capture', 'result': 'denied'});
      throw MicrophoneException('permissionDenied');
    }

    final Stream<Uint8List> raw;
    try {
      raw = await recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: 1,
        ),
      );
    } on Object catch (error) {
      await recorder.dispose();
      logEvent('stt', {
        'kind': 'capture',
        'result': 'failed',
        'error': error.runtimeType.toString(),
      });
      throw MicrophoneException(error.runtimeType.toString());
    }

    _recorder = recorder;
    _listening = true;
    logEvent('stt', {
      'kind': 'capture',
      'result': 'started',
      'sample_rate': sampleRate,
      'channels': 1,
      'encoding': 'pcm16bits',
    });

    final controller = StreamController<Float32List>();
    _subscription = raw.listen(
      (chunk) => controller.add(pcm16ToFloat32(chunk)),
      onError: (Object error) {
        logEvent('stt', {
          'kind': 'capture',
          'result': 'stream_error',
          'error': error.runtimeType.toString(),
        });
        controller.addError(MicrophoneException(error.runtimeType.toString()));
      },
      onDone: controller.close,
      cancelOnError: false,
    );
    return controller.stream;
  }

  /// Stops capture and releases the recorder.
  Future<void> stop() async {
    _listening = false;
    await _subscription?.cancel();
    _subscription = null;
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      try {
        await recorder.stop();
      } on Object {
        // Stopping a recorder that already finished is not an error worth
        // reporting: the samples captured so far are still usable.
      }
      await recorder.dispose();
    }
    logEvent('stt', {'kind': 'capture', 'result': 'stopped'});
  }
}

/// Converts little-endian PCM16 bytes into float samples in `[-1, 1]`.
///
/// A trailing odd byte — which a chunk boundary may produce — is dropped rather
/// than read as half a sample.
Float32List pcm16ToFloat32(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final count = bytes.lengthInBytes ~/ 2;
  final samples = Float32List(count);
  for (var i = 0; i < count; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return samples;
}
