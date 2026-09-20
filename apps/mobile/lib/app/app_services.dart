import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/log.dart';
import '../data/app_database.dart';
import '../data/profile_repository.dart';
import '../data/registry_repository.dart';
import '../presentation/connection_controller.dart';
import '../voice/voice_controller.dart';

/// Composition root: every long-lived object the app shares, built once.
///
/// Created in `main()` before the first frame and handed down through
/// [AppScope]. Screens never construct a repository or a controller, which is
/// what keeps one connection state and one database per app.
class AppServices {
  AppServices({
    required this.database,
    required this.profiles,
    required this.registry,
    required this.connection,
    required this.voice,
  });

  final AppDatabase database;
  final ProfileRepository profiles;
  final RegistryRepository registry;
  final ConnectionController connection;

  /// The voice engine: one per app, built here like every other shared object.
  /// Its model is provisioned by `main()` after the first frame, because
  /// copying 126 MB out of the APK must not hold up startup.
  final VoiceController voice;

  /// Opens storage, wires the repositories and restores the stored profile.
  ///
  /// Only local work happens here — opening SQLite, reading secure storage — so
  /// startup stays inside one frame budget. The reachability probe is started
  /// by `main()` after `runApp`, because a network round trip must not hold the
  /// first frame.
  static Future<AppServices> bootstrap() async {
    final database = await AppDatabase.open();
    final profiles = ProfileRepository(
      database: database.database,
      secureStorage: const FlutterSecureStorage(),
    );
    final registry = RegistryRepository(database: database.database);
    final connection = ConnectionController(profiles, registry);
    await connection.loadStoredProfile();
    logEvent('app', {
      'action': 'bootstrap',
      'stored': connection.hasStoredProfile,
      'reachability': connection.reachability.name,
    });
    return AppServices(
      database: database,
      profiles: profiles,
      registry: registry,
      connection: connection,
      voice: VoiceController(),
    );
  }
}
