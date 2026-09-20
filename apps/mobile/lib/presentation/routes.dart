import 'package:flutter/material.dart';

import '../voice/voice_self_check.dart';
import 'screens/assistant_screen.dart';
import 'screens/connect_screen.dart';
import 'screens/queue_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/voice_debug_screen.dart';

/// Every destination of the app, defined in one place.
///
/// `FR-MG01` fixes the set at four screens: Connect, Assistant, Queue and
/// Settings. Keeping the paths here means adding a fifth destination is one
/// visible edit instead of a string search across the widget tree.
abstract final class AppRoutes {
  static const String connect = '/connect';
  static const String assistant = '/assistant';
  static const String queue = '/queue';
  static const String settings = '/settings';

  /// Voice diagnostics. It is **not** part of the ordinary route table: it is
  /// registered only in a build made with
  /// `--dart-define=UMLIVE_VOICE_SELFCHECK=true`, which is the verification
  /// build, and opens as that build's initial route. No tap in a normal build
  /// can reach it — which is the point: the product must not ship a debug
  /// screen in the user's path (`FR-MG01` keeps the product at four screens).
  static const String voiceDiagnostics = '/voice-diagnostics';

  /// The app opens into the conversation, not into configuration (`FR-MG01`).
  ///
  /// Unless there is nothing stored: a cold start with no backend lands on
  /// Connect, because the conversation screen has nothing to talk to. The
  /// decision reads the restored profile, never the network (`FR-MD01`).
  ///
  /// A verification build is the one other case, and it opens straight into the
  /// diagnostics screen, which is where the offline self-check reports itself.
  static String initialFor({required bool hasStoredProfile}) =>
      voiceSelfCheckOnLaunch
          ? voiceDiagnostics
          : hasStoredProfile
              ? assistant
              : connect;

  /// Named-route table handed to `MaterialApp.routes`.
  static final Map<String, WidgetBuilder> table = <String, WidgetBuilder>{
    connect: (context) => const ConnectScreen(),
    assistant: (context) => const AssistantScreen(),
    queue: (context) => const QueueScreen(),
    settings: (context) => const SettingsScreen(),
    if (voiceSelfCheckOnLaunch)
      voiceDiagnostics: (context) => const VoiceDebugScreen(),
  };
}
