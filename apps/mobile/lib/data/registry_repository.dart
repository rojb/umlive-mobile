import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/log.dart';
import '../openapi/registry.dart';
import '../openapi/registry_parser.dart';

/// The cached registry of one profile, as it was stored.
///
/// Both halves of the row are kept: [registry] is what the app works with, and
/// [documentJson] is the raw document the registry was derived from, so a later
/// task can re-derive without asking the backend again.
class CachedRegistry {
  const CachedRegistry({
    required this.registry,
    required this.documentJson,
    required this.fetchedAt,
  });

  final ApiRegistry registry;
  final String documentJson;

  /// When the backend last answered with this document.
  final int fetchedAt;
}

/// Owner of the `registry` table (`FR-MA04`).
///
/// One row per profile, which is the primary key of the fixed schema: the row
/// holds the derived registry, the raw document it came from, that document's
/// hash and when it was fetched. The cached registry is the **authority when
/// offline** — that is what `offlineWithCache` means — so this repository never
/// degrades a stored row on a failed or unreadable fetch; it only ever replaces
/// one with a document it was told is usable.
class RegistryRepository {
  RegistryRepository({required this.database});

  final Database database;

  /// True when a registry row exists for [profileId].
  Future<bool> hasRegistry(String profileId) async {
    final rows = await database.query(
      'registry',
      columns: <String>['profile_id'],
      where: 'profile_id = ?',
      whereArgs: <Object?>[profileId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// The hash of the stored document, or null when nothing is stored.
  ///
  /// Read on its own so change detection (`FR-MA07`) costs one small query
  /// instead of decoding the whole cached registry on every connect.
  Future<String?> storedHash(String profileId) async {
    final rows = await database.query(
      'registry',
      columns: <String>['document_hash'],
      where: 'profile_id = ?',
      whereArgs: <Object?>[profileId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['document_hash'] as String?;
  }

  /// Loads the stored registry for [profileId], or null when there is none.
  ///
  /// A row that cannot be decoded is treated as nothing stored and reported:
  /// the app then behaves exactly as it does with no cache at all, instead of
  /// crashing on the first frame of an offline cold start.
  Future<CachedRegistry?> load(String profileId) async {
    final rows = await database.query(
      'registry',
      where: 'profile_id = ?',
      whereArgs: <Object?>[profileId],
      limit: 1,
    );
    if (rows.isEmpty) return null;

    final row = rows.first;
    final derivedJson = row['derived_json'];
    final documentJson = row['document_json'];
    if (derivedJson is! String || documentJson is! String) {
      logEvent('registry', {
        'kind': 'cache',
        'result': 'unreadable',
        'reason': 'columns_not_text',
      });
      return null;
    }

    try {
      final decoded = jsonDecode(derivedJson);
      if (decoded is! Map) {
        logEvent('registry', {
          'kind': 'cache',
          'result': 'unreadable',
          'reason': 'derived_not_object',
        });
        return null;
      }
      return CachedRegistry(
        registry: ApiRegistry.fromJson(decoded.cast<String, Object?>()),
        documentJson: documentJson,
        fetchedAt: (row['fetched_at'] as num?)?.toInt() ?? 0,
      );
    } on Object catch (error) {
      logEvent('registry', {
        'kind': 'cache',
        'result': 'unreadable',
        'reason': error.runtimeType.toString(),
      });
      return null;
    }
  }

  /// Persists one successful discovery, replacing whatever the profile had.
  ///
  /// Called only with a document the parser accepted as an OpenAPI description
  /// (the rule the connection controller states where it decides to persist): a
  /// body that failed to parse never reaches this method, so it can never
  /// overwrite a good row.
  Future<void> save({
    required String profileId,
    required RegistryParseResult parsed,
    required int fetchedAt,
  }) async {
    final registry = parsed.registry;
    await database.insert('registry', <String, Object?>{
      'profile_id': profileId,
      'document_hash': registry.documentHash,
      'document_json': parsed.documentJson,
      'derived_json': jsonEncode(registry.toJson()),
      'openapi_version': registry.openapiVersion,
      'fetched_at': fetchedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Drops the cached registry of [profileId].
  ///
  /// Used only when the app is pointed at a **different** backend: the row is
  /// keyed by profile, the profile survives an address change, and a cache
  /// belonging to another backend would otherwise be reported as this one's
  /// remembered knowledge — a state the app must never claim falsely.
  Future<void> clear(String profileId) async {
    await database.delete(
      'registry',
      where: 'profile_id = ?',
      whereArgs: <Object?>[profileId],
    );
  }
}
