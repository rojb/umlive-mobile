import 'package:flutter/material.dart';

import 'screens/assistant_screen.dart';
import 'screens/connect_screen.dart';
import 'screens/queue_screen.dart';
import 'screens/settings_screen.dart';

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

  /// The app opens into the conversation, not into configuration (`FR-MG01`).
  static const String initial = assistant;

  /// Named-route table handed to `MaterialApp.routes`.
  static final Map<String, WidgetBuilder> table = <String, WidgetBuilder>{
    connect: (context) => const ConnectScreen(),
    assistant: (context) => const AssistantScreen(),
    queue: (context) => const QueueScreen(),
    settings: (context) => const SettingsScreen(),
  };
}
