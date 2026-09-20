import 'package:flutter/services.dart';

import '../core/log.dart';

/// The drain window's foreground service, as seen from Dart (`T19`).
///
/// This class is the whole Dart side of channel `com.umlive.voice/service`: it
/// asks the Android service to hold the app's process scheduled while the app
/// is not in the foreground, so the drain of the durable queue (`FR-MD04`) gets
/// to finish instead of being killed by this OEM. It owns no queue, no
/// notification and no policy — [ConversationController] decides when a window
/// is owed.
///
/// **It owns no copy either.** The strings it carries are produced by the
/// conversation from `app_es.arb` and travel to the platform untouched, because
/// user-facing text has exactly one source in this app.
///
/// **Nothing here ever throws.** A platform that refuses the intent, a build
/// where the service is absent, a channel that no longer exists: each one is a
/// `[umlive][service]` log line and nothing else. The drain's own behaviour does
/// not depend on the window — the service is what keeps it scheduled, not what
/// performs it — so a refused window must never turn into a failed
/// conversation.
class DrainService {
  DrainService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.umlive.voice/service';

  final MethodChannel _channel;

  /// Asks the platform to open the drain window: one ongoing notification,
  /// [title] and [body] as the app wrote them, [count] as the queue last saw it.
  Future<void> start({
    required String title,
    required String body,
    required int count,
  }) =>
      _invoke('start', title: title, body: body, count: count);

  /// Replaces the notification of a window that is already open, without
  /// restarting the service: the count changed while the drain was working.
  Future<void> update({
    required String title,
    required String body,
    required int count,
  }) =>
      _invoke('update', title: title, body: body, count: count);

  /// Closes the window, so no notification outlives the work it described.
  ///
  /// No text is sent or needed: a stop says nothing, it only takes a claim back.
  Future<void> stop() => _invoke('stop');

  /// One call, one log line, and never an exception.
  ///
  /// `count` is part of the line because it is the only fact this boundary can
  /// report that is not app copy: how much work the window was opened for. A
  /// stop carries none, which is logged as `count=none` rather than as a zero
  /// the app did not measure.
  Future<void> _invoke(
    String action, {
    String? title,
    String? body,
    int? count,
  }) async {
    try {
      final answer = await _channel.invokeMethod<Map<Object?, Object?>>(
        action,
        // A stop carries no text and no count, so those entries are absent
        // rather than empty: the platform sees exactly what was asked for.
        <String, Object?>{
          'title': ?title,
          'body': ?body,
          'count': ?count,
        },
      );
      // The platform answers in-band rather than by throwing: `ok` is what the
      // service side reported about its own attempt.
      logEvent('service', {
        'action': action,
        'count': count,
        'result': answer?['ok'] == true ? 'ok' : 'failed',
        'error': answer?['error'],
      });
    } on MissingPluginException {
      logEvent('service', {
        'action': action,
        'count': count,
        'result': 'failed',
        'reason': 'channel_missing',
      });
    } on PlatformException catch (error) {
      logEvent('service', {
        'action': action,
        'count': count,
        'result': 'failed',
        'reason': error.code,
      });
    } on Object catch (error) {
      logEvent('service', {
        'action': action,
        'count': count,
        'result': 'failed',
        'reason': error.runtimeType.toString(),
      });
    }
  }
}
