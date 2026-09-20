import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../conversation/conversation_controller.dart';
import '../conversation/deterministic_resolver.dart';
import '../core/log.dart';
import '../data/app_database.dart';
import '../data/outbox_repository.dart';
import '../data/profile_repository.dart';
import '../data/read_cache_repository.dart';
import '../data/registry_repository.dart';
import '../presentation/connection_controller.dart';
import '../presentation/technical_mode.dart';
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
    required this.outbox,
    required this.readCache,
    required this.connection,
    required this.voice,
    required this.conversation,
    required this.technicalMode,
  });

  final AppDatabase database;
  final ProfileRepository profiles;
  final RegistryRepository registry;

  /// The durable queue for writes the backend never received (`T14`). Kept
  /// here so a later queue screen (`T18`) has the same single owner every other
  /// repository has.
  final OutboxRepository outbox;

  /// The read cache a read the backend did not answer is answered from (`T17`,
  /// `FR-MD05`). Kept here as the same single owner every other repository has;
  /// the executor stack the connection controller builds is what writes it.
  final ReadCacheRepository readCache;

  final ConnectionController connection;

  /// The voice engine: one per app, built here like every other shared object.
  /// Its model is provisioned by `main()` after the first frame, because
  /// copying 126 MB out of the APK must not hold up startup.
  final VoiceController voice;

  /// Owns the conversation's turn list and the resolution seam (`T11`). Built
  /// against [connection] rather than a second connection state, with the
  /// deterministic resolver (`T12`'s read path, extended by `T13`) as the one
  /// that turns an utterance into an operation call.
  final ConversationController conversation;

  /// The operator's request to see the machinery (`T23`, `FR-ME06`). Built here
  /// like every other shared object, so the Settings switch that flips it and
  /// the conversation surface that reads it are talking about the same one
  /// mode — toggling it on Settings re-renders the turns already on screen.
  final TechnicalMode technicalMode;

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
    final outbox = OutboxRepository(database: database.database);
    // Opened on the same shared [Database] as every other repository: the
    // `read_cache` table already exists at schema version 1, so this adds a
    // consumer and no migration.
    final readCache = ReadCacheRepository(database: database.database);
    final connection = ConnectionController(
      profiles,
      outbox,
      registry,
      readCache,
    );
    await connection.loadStoredProfile();
    logEvent('app', {
      'action': 'bootstrap',
      'stored': connection.hasStoredProfile,
      'reachability': connection.reachability.name,
    });
    final voice = VoiceController();
    // Off by default and in memory only; the class documents why that is a
    // decision and not an omission (`T23`).
    final technicalMode = TechnicalMode();
    return AppServices(
      database: database,
      profiles: profiles,
      registry: registry,
      outbox: outbox,
      readCache: readCache,
      connection: connection,
      voice: voice,
      technicalMode: technicalMode,
      conversation: ConversationController(
        connection,
        // The drain (`T16`) sends from the same queue the outbox decorator
        // writes to; `T18`'s queue screen reads it too.
        outbox: outbox,
        resolver: const DeterministicOperationResolver(),
        // The conversation speaks through the app's **one** [VoiceController],
        // not through a second object and not through the TTS engine directly:
        // there is one engine, one pinned offline `es-US` voice and one place
        // that knows synthesis is unavailable, and this is it. The
        // conversation only sees the `SpeechSink` port, so it can say a
        // sentence without knowing any of that.
        speech: voice,
      ),
    );
  }
}
