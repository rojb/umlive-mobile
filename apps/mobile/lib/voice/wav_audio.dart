import 'dart:io';
import 'dart:typed_data';

/// A WAV file could not be read as mono PCM audio.
class WavFormatException implements Exception {
  WavFormatException(this.detail);

  final String detail;

  @override
  String toString() => 'WavFormatException($detail)';
}

/// Mono 16 kHz float samples, plus where they came from.
class WavAudio {
  const WavAudio({
    required this.samples,
    required this.sourceSampleRate,
    required this.sourceChannels,
    required this.sourceBytes,
  });

  /// Mono, [targetSampleRate] Hz, values in `[-1, 1]`.
  final Float32List samples;

  final int sourceSampleRate;
  final int sourceChannels;
  final int sourceBytes;

  static const int targetSampleRate = 16000;

  bool get wasResampled => sourceSampleRate != targetSampleRate;

  double get durationMs => samples.length * 1000 / targetSampleRate;
}

/// Reads a PCM WAV file as mono 16 kHz float samples.
///
/// This exists for one reason: to drive the recognizer with audio the app did
/// not capture from the microphone, so recognition can be *observed* with the
/// radios off without a human speaking into the handset. The platform
/// synthesizer already writes WAV files (`FR-MB02`), so a single `flutter_tts`
/// call produces both the offline-synthesis evidence and the audio the same
/// decode path then transcribes.
///
/// The platform engine chooses its own rate (22050 Hz and 24000 Hz are both
/// common), so a rate that is not 16 kHz is linearly resampled and the source
/// rate is reported. The recognizer itself only ever sees 16 kHz mono.
Future<WavAudio> readWavAsMono16k(String path) async {
  final bytes = await File(path).readAsBytes();
  if (bytes.lengthInBytes < 44) {
    throw WavFormatException('file too short: ${bytes.lengthInBytes} bytes');
  }
  final data = ByteData.sublistView(bytes);
  if (_tag(data, 0) != 'RIFF' || _tag(data, 8) != 'WAVE') {
    throw WavFormatException('not a RIFF/WAVE file');
  }

  int? format;
  int? channels;
  int? sampleRate;
  int? bitsPerSample;
  int? dataOffset;
  int? dataLength;

  var offset = 12;
  while (offset + 8 <= bytes.lengthInBytes) {
    final id = _tag(data, offset);
    final size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ' && body + 16 <= bytes.lengthInBytes) {
      format = data.getUint16(body, Endian.little);
      channels = data.getUint16(body + 2, Endian.little);
      sampleRate = data.getUint32(body + 4, Endian.little);
      bitsPerSample = data.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      dataOffset = body;
      dataLength = size;
      // Keep scanning: some writers put `fmt ` after `data`.
    }
    // Chunks are word-aligned.
    offset = body + size + (size.isOdd ? 1 : 0);
  }

  if (format == null || channels == null || sampleRate == null) {
    throw WavFormatException('missing fmt chunk');
  }
  if (dataOffset == null || dataLength == null) {
    throw WavFormatException('missing data chunk');
  }
  final end = dataOffset + dataLength;
  final available = end <= bytes.lengthInBytes ? dataLength : bytes.lengthInBytes - dataOffset;
  if (available <= 0) {
    throw WavFormatException('empty data chunk');
  }

  final mono = _toMono(data, dataOffset, available, format, channels, bitsPerSample);
  if (mono.isEmpty) {
    throw WavFormatException('no samples in data chunk');
  }

  final samples = sampleRate == WavAudio.targetSampleRate
      ? mono
      : _resample(mono, sampleRate, WavAudio.targetSampleRate);

  return WavAudio(
    samples: samples,
    sourceSampleRate: sampleRate,
    sourceChannels: channels,
    sourceBytes: bytes.lengthInBytes,
  );
}

Float32List _toMono(
  ByteData data,
  int offset,
  int length,
  int format,
  int channels,
  int? bitsPerSample,
) {
  if (format != 1 && format != 3) {
    throw WavFormatException('unsupported format tag $format');
  }
  if (channels < 1) {
    throw WavFormatException('unsupported channel count $channels');
  }

  if (format == 1) {
    // 16-bit PCM is what the Android synthesizer writes.
    if (bitsPerSample != 16) {
      throw WavFormatException(
        'unsupported PCM depth ${bitsPerSample ?? 0} bits; expected 16',
      );
    }
    final frames = length ~/ (2 * channels);
    final mono = Float32List(frames);
    for (var frame = 0; frame < frames; frame++) {
      var sum = 0.0;
      for (var channel = 0; channel < channels; channel++) {
        sum += data.getInt16(offset + (frame * channels + channel) * 2, Endian.little) /
            32768.0;
      }
      mono[frame] = sum / channels;
    }
    return mono;
  }

  if (bitsPerSample != 32) {
    throw WavFormatException(
      'unsupported float depth ${bitsPerSample ?? 0} bits; expected 32',
    );
  }
  final frames = length ~/ (4 * channels);
  final mono = Float32List(frames);
  for (var frame = 0; frame < frames; frame++) {
    var sum = 0.0;
    for (var channel = 0; channel < channels; channel++) {
      sum += data.getFloat32(offset + (frame * channels + channel) * 4, Endian.little);
    }
    mono[frame] = sum / channels;
  }
  return mono;
}

Float32List _resample(Float32List input, int fromRate, int toRate) {
  if (input.isEmpty) return input;
  final ratio = fromRate / toRate;
  final length = (input.length / ratio).floor();
  if (length <= 1) return input;
  final output = Float32List(length);
  for (var i = 0; i < length; i++) {
    final position = i * ratio;
    final lower = position.floor();
    final upper = lower + 1 < input.length ? lower + 1 : input.length - 1;
    final fraction = position - lower;
    output[i] = input[lower] * (1 - fraction) + input[upper] * fraction;
  }
  return output;
}

String _tag(ByteData data, int offset) {
  final codes = <int>[
    data.getUint8(offset),
    data.getUint8(offset + 1),
    data.getUint8(offset + 2),
    data.getUint8(offset + 3),
  ];
  return String.fromCharCodes(codes);
}
