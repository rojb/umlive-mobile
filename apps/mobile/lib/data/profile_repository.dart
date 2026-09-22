import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';

import '../core/log.dart';
import '../net/backend_address.dart';
import 'connection_profile.dart';

/// The only owner of the connection's local state.
///
/// Split deliberately, and this split is the security decision of `FR-MA01`:
///
/// * the **base URL and the bearer token** live in `flutter_secure_storage`,
///   encrypted at rest;
/// * the **identifier, label and timestamps** live in the `profile` table.
///
/// No screen and no controller touches either store directly.
class ProfileRepository {
  ProfileRepository({required this.database, required this.secureStorage});

  final Database database;
  final FlutterSecureStorage secureStorage;

  /// Points at the profile the app is currently using. A pointer rather than a
  /// flag, because `FR-MA09` (several saved backends) is a could-have.
  static const String _activeIdKey = 'profile.active_id';

  static String _baseUrlKey(String id) => 'profile.$id.base_url';
  static String _tokenKey(String id) => 'profile.$id.bearer_token';

  /// Loads the stored connection, or null when there is nothing to restore.
  ///
  /// A stored address that no longer parses is treated as nothing stored: the
  /// app then asks for an address instead of probing a broken one.
  Future<StoredConnection?> loadActive() async {
    final id = await secureStorage.read(key: _activeIdKey);
    if (id == null || id.isEmpty) return null;

    final rawUrl = await secureStorage.read(key: _baseUrlKey(id));
    if (rawUrl == null || rawUrl.isEmpty) {
      logEvent('profile', {'action': 'load', 'id': id, 'result': 'no-url'});
      return null;
    }

    final outcome = BackendAddressParser.parse(rawUrl);
    if (outcome is! AddressAccepted) {
      logEvent('profile', {'action': 'load', 'id': id, 'result': 'bad-url'});
      return null;
    }

    final rows = await database.query(
      'profile',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) {
      logEvent('profile', {'action': 'load', 'id': id, 'result': 'no-row'});
      return null;
    }

    final token = await secureStorage.read(key: _tokenKey(id));
    final profile = ConnectionProfile.fromRow(rows.first);
    logEvent('profile', {
      'action': 'load',
      'id': id,
      'url': outcome.address.display,
      'token': _presence(token),
    });
    return StoredConnection(
      profile: profile,
      address: outcome.address,
      token: token,
    );
  }

  /// Persists the address and token, and returns the stored connection.
  ///
  /// Called as soon as an address normalizes — not after a successful probe.
  /// `FR-MA01` says the address is reused on the next launch, and a backend
  /// that is down today is exactly the case the stored address has to survive.
  Future<StoredConnection> save({
    required BackendAddress address,
    String? token,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await _activeRow();
    final id = (existing?['id'] as String?) ?? _newId(now);
    final createdAt = (existing?['created_at'] as num?)?.toInt() ?? now;
    final label = existing?['label'] as String?;
    final lastConnectedAt = (existing?['last_connected_at'] as num?)?.toInt();

    await secureStorage.write(key: _baseUrlKey(id), value: address.display);
    final cleanToken = token?.trim() ?? '';
    if (cleanToken.isEmpty) {
      await secureStorage.delete(key: _tokenKey(id));
    } else {
      await secureStorage.write(key: _tokenKey(id), value: cleanToken);
    }
    await secureStorage.write(key: _activeIdKey, value: id);

    // `profile.base_url` is NOT NULL in the fixed schema but stays empty on
    // purpose: the address lives in secure storage, never in SQLite
    // (docs/architecture.md §5). The column is kept so the DDL needs no
    // migration later.
    await database.insert('profile', <String, Object?>{
      'id': id,
      'base_url': '',
      'label': label,
      'created_at': createdAt,
      'last_connected_at': lastConnectedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    logEvent('profile', {
      'action': 'save',
      'id': id,
      'url': address.display,
      'transport': address.transport.name,
      'token': _presence(cleanToken),
    });

    return StoredConnection(
      profile: ConnectionProfile(
        id: id,
        label: label,
        createdAt: createdAt,
        lastConnectedAt: lastConnectedAt,
      ),
      address: address,
      token: cleanToken.isEmpty ? null : cleanToken,
    );
  }

  /// Records that the backend answered, which is what the timestamp means.
  Future<void> touchConnectedAt(String id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await database.update(
      'profile',
      <String, Object?>{'last_connected_at': now},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
    logEvent('profile', {'action': 'touch', 'id': id, 'at': now});
  }

  /// Forgets the active connection entirely (`FR-MG01`): the three secure-
  /// storage keys and the `profile` row itself.
  ///
  /// There is deliberately no soft variant. `save` is the only other writer of
  /// these rows and it always leaves something behind — an address, a token or
  /// both; this is the one method that leaves nothing, which is what makes the
  /// app reach the state it had before its first connection. Tolerates a
  /// missing active id: forgetting an app that never connected, or forgetting
  /// twice, does nothing rather than throwing.
  Future<void> forgetActive() async {
    final id = await secureStorage.read(key: _activeIdKey);
    if (id == null || id.isEmpty) {
      logEvent('profile', {'action': 'forget', 'result': 'nothing_stored'});
      return;
    }

    await secureStorage.delete(key: _activeIdKey);
    await secureStorage.delete(key: _baseUrlKey(id));
    await secureStorage.delete(key: _tokenKey(id));
    await database.delete('profile', where: 'id = ?', whereArgs: <Object?>[id]);

    logEvent('profile', {'action': 'forget', 'id': id, 'result': 'cleared'});
  }

  Future<Map<String, Object?>?> _activeRow() async {
    final id = await secureStorage.read(key: _activeIdKey);
    if (id == null || id.isEmpty) return null;
    final rows = await database.query(
      'profile',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// A local identifier. Monotonic enough for one device with one backend, and
  /// it avoids a dependency: `FR-MA09` needs uniqueness, not a UUID.
  static String _newId(int now) => 'p$now';

  static String _presence(String? secret) =>
      (secret == null || secret.isEmpty) ? 'absent' : 'present';
}
