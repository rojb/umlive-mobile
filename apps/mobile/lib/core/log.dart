import 'package:flutter/foundation.dart';

/// Structured diagnostics for device verification.
///
/// On the handset a screenshot cannot be read as text, so state transitions are
/// proven from `adb logcat`. Every line is exactly
/// `[umlive][<area>] key=value key=value`, which makes
/// `adb logcat -d | grep umlive` a complete trace of what the app did.
///
/// Areas in use: `app`, `profile`, `address`, `probe`, `registry`, `voice`,
/// `stt`, `tts`.
///
/// Never pass a secret here: the bearer token is logged as `present`/`absent`,
/// never by value.
void logEvent(String area, Map<String, Object?> fields) {
  final buffer = StringBuffer('[umlive][')..write(area)..write(']');
  for (final entry in fields.entries) {
    buffer.write(' ${entry.key}=${_format(entry.value)}');
  }
  debugPrint(buffer.toString());
}

String _format(Object? value) {
  if (value == null) return 'none';
  if (value is bool) return value ? 'true' : 'false';
  final text = value.toString();
  if (text.isEmpty) return 'empty';
  // One line per event: a value carrying whitespace would break `key=value`.
  return text.replaceAll(RegExp(r'\s+'), '_');
}
