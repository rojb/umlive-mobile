import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;

import '../core/log.dart';

/// Why synthesis cannot be offered, when it cannot.
enum SpeechProblem {
  /// An offline Spanish voice was found, pinned, and accepted by the engine.
  none,

  /// No voice in the catalogue is both Spanish and `network_required: 0`.
  noOfflineSpanishVoice,

  /// A voice was chosen but the engine refused to pin it — pinning is what
  /// makes the choice stick, so this is a loud failure and not a downgrade.
  voiceNotPinned,

  /// The platform engine did not answer at all.
  engineUnavailable,
}

/// The voice synthesis is pinned to, with the evidence that it is offline.
class PinnedSpeechVoice {
  const PinnedSpeechVoice({
    required this.name,
    required this.locale,
    required this.networkRequired,
    required this.preferredLocale,
  });

  final String name;
  final String locale;

  /// From the catalogue's `network_required`, not from a preference hint.
  final bool networkRequired;

  /// True when the locale is the `es-US` one this feature is specified on.
  final bool preferredLocale;
}

/// A file the platform engine wrote, with the evidence that it is not empty.
class SpeechSynthesis {
  const SpeechSynthesis({
    required this.path,
    required this.bytes,
    required this.voice,
  });

  final String path;
  final int bytes;
  final PinnedSpeechVoice voice;

  /// A WAV header alone is a few dozen bytes. Anything above this came from an
  /// engine that synthesised an utterance, which is the only evidence of
  /// offline synthesis available without listening.
  bool get producedAudio => bytes > 4096;
}

/// Speech synthesis on the platform engine, pinned to an offline Spanish voice.
///
/// `FR-MB02` measured the platform synthesizer working on this handset with the
/// radios off, so it is the selected branch — *provided* the voice is one the
/// engine can speak without the network. Half the `es-US` catalogue needs the
/// network, so `setLanguage` alone is not enough: the voice is enumerated from
/// `getVoices`, filtered on `network_required == 0`, and pinned with
/// `setVoice`, and availability is decided from the catalogue — never from
/// `isLanguageAvailable`, which this handset reports as optimistic (it answers
/// `true` for locales the catalogue does not contain: PRD-MOBILE.md §10.2).
///
/// When no offline Spanish voice exists, synthesis fails loudly: no network
/// voice is ever substituted, because a voice that needs the radio is exactly
/// the silent degradation `FR-MB01b` forbids.
class PlatformSpeech {
  PlatformSpeech({FlutterTts? engine}) : _engine = engine ?? FlutterTts();

  final FlutterTts _engine;

  SpeechProblem _problem = SpeechProblem.engineUnavailable;
  PinnedSpeechVoice? _voice;
  List<String> _languages = const <String>[];
  bool _initialized = false;

  SpeechProblem get problem => _problem;

  PinnedSpeechVoice? get voice => _voice;

  /// Locales the engine reports. Recorded as evidence, never used as the
  /// availability predicate on its own.
  List<String> get languages => _languages;

  bool get isReady => _problem == SpeechProblem.none && _voice != null;

  /// Enumerates the catalogue, chooses an offline Spanish voice and pins it.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    final List<Map<String, String>> voices;
    final List<String> languages;
    try {
      voices = _readVoices(await _engine.getVoices);
      languages = _readLanguages(await _engine.getLanguages);
    } on Object catch (error) {
      _problem = SpeechProblem.engineUnavailable;
      logEvent('tts', {
        'kind': 'catalogue',
        'result': 'failed',
        'error': error.runtimeType.toString(),
      });
      return;
    }
    _languages = languages;

    final offlineSpanish = voices.where(_isOfflineSpanish).toList()
      ..sort((a, b) => _rank(a).compareTo(_rank(b)));

    logEvent('tts', {
      'kind': 'catalogue',
      'voices': voices.length,
      'languages': languages.join(','),
      'offline_spanish': offlineSpanish.length,
    });

    if (offlineSpanish.isEmpty) {
      _problem = SpeechProblem.noOfflineSpanishVoice;
      logEvent('tts', {
        'kind': 'voice',
        'result': 'unavailable',
        'reason': 'no_offline_spanish_voice',
        'network_voices_seen': voices.where(_isSpanish).length,
      });
      return;
    }

    final chosen = offlineSpanish.first;
    final locale = chosen['locale'] ?? '';
    logEvent('tts', {
      'kind': 'voice',
      'op': 'candidate',
      'name': chosen['name'] ?? '',
      'locale': locale,
      'network_required': 0,
      'quality': chosen['quality'] ?? 'unknown',
      'fallback_locale': !_isPreferredLocale(locale),
    });

    // `setVoice` is the pin: `setLanguage` alone leaves the engine free to
    // answer with any voice of that language, network ones included.
    final pinned = await _engine.setVoice(<String, String>{
      'name': chosen['name'] ?? '',
      'locale': locale,
    });
    if (pinned != 1) {
      _problem = SpeechProblem.voiceNotPinned;
      logEvent('tts', {
        'kind': 'voice',
        'result': 'unavailable',
        'reason': 'set_voice_refused',
        'name': chosen['name'] ?? '',
        'locale': locale,
      });
      return;
    }

    await _engine.setLanguage(locale);
    // Both completions are awaited so a synthesis or a playback can be reported
    // as finished instead of racing the next call.
    await _engine.awaitSpeakCompletion(true);
    await _engine.awaitSynthCompletion(true);

    _voice = PinnedSpeechVoice(
      name: chosen['name'] ?? '',
      locale: locale,
      networkRequired: false,
      preferredLocale: _isPreferredLocale(locale),
    );
    _problem = SpeechProblem.none;
    logEvent('tts', {
      'kind': 'voice',
      'result': 'pinned',
      'name': _voice!.name,
      'locale': _voice!.locale,
      'network_required': 0,
    });
  }

  /// Synthesises [text] to a WAV file and reports what came out.
  ///
  /// This is the offline-synthesis evidence that does not require hearing
  /// anything: a non-trivial file means the platform engine produced audio, and
  /// the file doubles as the audio the recognizer decodes in the offline
  /// self-check.
  Future<SpeechSynthesis> synthesizeToFile(
    String text, {
    required Directory directory,
  }) async {
    final voice = _voice;
    if (voice == null || _problem != SpeechProblem.none) {
      logEvent('tts', {
        'kind': 'synthesize',
        'result': 'refused',
        'reason': 'no_offline_voice',
      });
      throw SpeechException('no offline Spanish voice is pinned');
    }
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    final path = p.join(
      directory.path,
      'umlive-tts-${DateTime.now().millisecondsSinceEpoch}.wav',
    );

    try {
      await _engine.synthesizeToFile(text, path, true);
    } on Object catch (error) {
      logEvent('tts', {
        'kind': 'synthesize',
        'result': 'failed',
        'error': error.runtimeType.toString(),
      });
      throw SpeechException('synthesizeToFile failed: ${error.runtimeType}');
    }

    final file = File(path);
    final bytes = file.existsSync() ? file.lengthSync() : 0;
    logEvent('tts', {
      'kind': 'synthesize',
      'file': path,
      'bytes': bytes,
      'result': bytes > 4096 ? 'ready' : 'empty',
      'name': voice.name,
      'locale': voice.locale,
      'network_required': voice.networkRequired ? 1 : 0,
      'chars': text.length,
    });
    return SpeechSynthesis(path: path, bytes: bytes, voice: voice);
  }

  /// Speaks [text] out loud through the pinned voice.
  Future<void> speak(String text) async {
    final voice = _voice;
    if (voice == null || _problem != SpeechProblem.none) {
      logEvent('tts', {
        'kind': 'speak',
        'result': 'refused',
        'reason': 'no_offline_voice',
      });
      throw SpeechException('no offline Spanish voice is pinned');
    }
    final answer = await _engine.speak(text);
    logEvent('tts', {
      'kind': 'speak',
      'result': answer == 0 ? 'failed' : 'started',
      'name': voice.name,
      'locale': voice.locale,
      'network_required': voice.networkRequired ? 1 : 0,
    });
  }

  Future<void> stop() async {
    await _engine.stop();
  }

  static bool _isSpanish(Map<String, String> voice) =>
      (voice['locale'] ?? '').toLowerCase().startsWith('es');

  static bool _isOfflineSpanish(Map<String, String> voice) =>
      _isSpanish(voice) && voice['network_required'] == '0';

  static bool _isPreferredLocale(String locale) =>
      locale.toLowerCase() == 'es-us';

  /// `es-US` first, then any other Spanish locale, and the rest last.
  static int _rank(Map<String, String> voice) {
    final locale = (voice['locale'] ?? '').toLowerCase();
    if (locale == 'es-us') return 0;
    if (locale == 'es-es') return 1;
    return 2;
  }

  static List<Map<String, String>> _readVoices(Object? raw) {
    if (raw is! List) return const <Map<String, String>>[];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(
          (voice) => voice.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ),
        )
        .where((voice) => (voice['name'] ?? '').isNotEmpty)
        .toList();
  }

  static List<String> _readLanguages(Object? raw) {
    if (raw is! List) return const <String>[];
    return raw.map((value) => value.toString()).toList();
  }
}

/// Synthesis could not run, and the reason is already logged.
class SpeechException implements Exception {
  SpeechException(this.detail);

  final String detail;

  @override
  String toString() => 'SpeechException($detail)';
}
