import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/log.dart';

/// One remembered read body, as it was stored.
///
/// Both halves of the row are kept: [body] is the response the backend last
/// answered with, and [fetchedAt] is when it did. The age is the whole point —
/// a cache-answered read is a real answer to the operator and it must be able
/// to say how old it is (`FR-MD05`), which is what the UX spec's *Stale /
/// cached* row asks for.
class CachedRead {
  const CachedRead({required this.body, required this.fetchedAt});

  /// The JSON-decoded response body the backend returned for this operation.
  /// A `List` for a collection, a `Map` for a single record.
  final Object? body;

  /// When the backend answered with [body].
  final DateTime fetchedAt;

  /// How old this answer is at [now].
  Duration age(DateTime now) => now.difference(fetchedAt);
}

/// Owner of the `read_cache` table (`FR-MD05`).
///
/// The table exists since schema version 1 (`app_database.dart`) and is keyed
/// `(profile_id, operation_key, path)` since version 2. It follows the house
/// pattern of `RegistryRepository`: it takes the open [Database], every
/// operation is a method, and no SQL escapes this file.
///
/// **The key is (profile, operation, resolved path)** — a profile, a discovered
/// operation, and the path the request actually went to. The second component
/// alone is not enough: one operation can address many records
/// (`GET /api/cliente/{id}`), so a key that stopped at the operation would let
/// an offline read of `cliente 2` be answered with `cliente 1`'s body. Adding
/// the resolved path means `cliente 1` and `cliente 2` can never share a slot,
/// and a row still can never be read back for a different backend or for a
/// different operation than the one it was stored from.
///
/// The resolved path is a *protocol* fact — the executor already logs it on
/// every call — and never operator data, which is why it may appear in a log
/// line while body and field values never do.
///
/// **A read is the only thing that reaches this table.** A write is never
/// stored here and never answered from here: writes queue (`T14`), reads cache,
/// and neither borrows the other's mechanism. That split is the *never
/// conflated* half of `FR-MD05`.
///
/// The body is the backend's data, so the log gets at most its size: no line
/// below carries a body and none carries a field value.
class ReadCacheRepository {
  ReadCacheRepository({required this.database});

  final Database database;

  /// The `action` values the `[umlive][cache]` lines carry, in the same shape
  /// `OutboxRepository` uses.
  static const String _actionStore = 'store';
  static const String _actionHit = 'hit';
  static const String _actionMiss = 'miss';

  /// Stores [body] for one resolved path of one operation of one profile,
  /// overwriting whatever the row held.
  ///
  /// The upsert replaces both the body and [CachedRead.fetchedAt]: the age an
  /// operator is shown is the age of *this* answer, never of the one it
  /// replaced.
  Future<void> store({
    required String profileId,
    required String operationKey,
    required String path,
    required Object? body,
  }) async {
    final fetchedAt = DateTime.now();
    // `jsonEncode(null)` is the string `null`, which decodes back to null: an
    // operation the backend answered with no body is still an answer that was
    // received, and the caller decides what it can do with it.
    final responseJson = jsonEncode(body);

    await database.insert('read_cache', <String, Object?>{
      'profile_id': profileId,
      'operation_key': operationKey,
      'path': path,
      'fetched_at': fetchedAt.millisecondsSinceEpoch,
      'response_json': responseJson,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    logEvent('cache', <String, Object?>{
      'action': _actionStore,
      'operation': operationKey,
      // The resolved path is the rest of the key, and it is a protocol fact the
      // executor logs anyway: without it this line cannot say which record was
      // remembered.
      'path': path,
      // The size of the encoded response, never the body: this is the
      // backend's data, and the log gets at most how big it was. `bytes`
      // counts the characters of the encoded JSON, the same measure
      // `OutboxRepository.enqueue` reports as `bodyBytes`.
      'bytes': responseJson.length,
    });
  }

  /// The stored answer for one resolved path of one operation of one profile,
  /// or null.
  ///
  /// The resolved path is what makes the lookup address a *record* rather than
  /// an operation: `GET /api/cliente/{id}` reads `cliente 1` and `cliente 2`
  /// through the same operation key, and only their distinct resolved paths keep
  /// the two answers apart.
  ///
  /// Null when nothing is stored **and** when the stored JSON does not decode.
  /// Both are the same fact to a caller — there is no usable remembered answer
  /// — so both are logged as a miss; the decode failure adds a `reason` so a
  /// damaged row is visible instead of looking like an empty cache.
  Future<CachedRead?> read({
    required String profileId,
    required String operationKey,
    required String path,
  }) async {
    final rows = await database.query(
      'read_cache',
      where: 'profile_id = ? AND operation_key = ? AND path = ?',
      whereArgs: <Object?>[profileId, operationKey, path],
      limit: 1,
    );
    if (rows.isEmpty) {
      logEvent('cache', <String, Object?>{
        'action': _actionMiss,
        'operation': operationKey,
        'path': path,
      });
      return null;
    }

    final row = rows.first;
    final responseJson = row['response_json'];
    if (responseJson is! String) {
      logEvent('cache', <String, Object?>{
        'action': _actionMiss,
        'operation': operationKey,
        'path': path,
        'reason': 'column_not_text',
      });
      return null;
    }

    final Object? body;
    try {
      body = jsonDecode(responseJson);
    } on Object catch (error) {
      logEvent('cache', <String, Object?>{
        'action': _actionMiss,
        'operation': operationKey,
        'path': path,
        'reason': error.runtimeType.toString(),
      });
      return null;
    }

    final cached = CachedRead(
      body: body,
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(
        (row['fetched_at'] as num?)?.toInt() ?? 0,
      ),
    );
    logEvent('cache', <String, Object?>{
      'action': _actionHit,
      'operation': operationKey,
      // Which record this remembered answer belongs to.
      'path': path,
      // The one thing this table exists to be able to say (`FR-MD05`).
      'age_ms': cached.age(DateTime.now()).inMilliseconds,
    });
    return cached;
  }

  /// When the most recent row of [profileId] was fetched, or null when the
  /// profile has nothing cached.
  ///
  /// Used only for logging: it answers "how stale is everything this profile
  /// remembers" in one query, so the age of the whole cache is one line
  /// instead of one line per row.
  Future<DateTime?> newestFetchedAt(String profileId) async {
    final rows = await database.rawQuery(
      'SELECT MAX(fetched_at) AS newest FROM read_cache WHERE profile_id = ?',
      <Object?>[profileId],
    );
    final newest = (rows.first['newest'] as num?)?.toInt();
    if (newest == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(newest);
  }

  /// Drops every cached read of [profileId].
  ///
  /// The same shape as `RegistryRepository.clear`, and used for the same
  /// reason: a different backend is a different cache, and an answer
  /// remembered from another backend's data would be reported as this one's.
  Future<void> clear(String profileId) async {
    await database.delete(
      'read_cache',
      where: 'profile_id = ?',
      whereArgs: <Object?>[profileId],
    );
  }
}
